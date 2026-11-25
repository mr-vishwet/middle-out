import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/erasure.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/services/file_picker_service.dart';
import 'package:middle_out/state/encode_controller.dart';

/// A picker whose reads always fail, so the encode error path can be
/// exercised without a real file.
class _ThrowingPicker extends FilePickerService {
  @override
  Future<Uint8List> readRef(PickedRef ref) async =>
      throw Exception('disk gone');
}

Uint8List _mixedBytes() {
  // 1 MiB: 768 KiB of zeros (compresses to almost nothing) then 256 KiB
  // of random data (incompressible). A head-only sample would report a
  // huge ratio; the worst-sample estimate must report ~1.0.
  final random = Random(99);
  final bytes = Uint8List(1024 * 1024);
  for (var i = 768 * 1024; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Builds a REAL PDF for [data] with exactly the adaptive page count
/// ([Encoder.dataPageCount] of the zlib-9 stream), returning its byte
/// size — so the estimate model can be checked against a real build
/// for whatever page count the rule says, instead of against a
/// hardcoded page count.
///
/// The pipeline mirrors the encoder (zlib-9, equal-split chunks,
/// parity, PDF build) without reusing the encoder's own chunking, so
/// the model and the build cannot agree by sharing a bug. For the
/// encrypted case the ChaCha20 stream is stood in for by seeded
/// uniform-random bytes of the same length: a stream cipher's output
/// has no structure left to squeeze, and the PDF size depends only on
/// the bytes' statistics (deflate of random bytes is length-preserving
/// to ~0.1%), so the stand-in is exact for size purposes.
Future<int> _actualPdfBytes(
  Uint8List data, {
  required bool encrypted,
}) async {
  final compressed = Uint8List.fromList(
    const ZLibEncoder().encode(data, level: 9),
  );
  // Fresh seeded generator per call, so the stand-in stream is
  // deterministic (a shared generator would make the bytes depend on
  // test order; a generator per byte would emit one repeated value).
  final cipherStandIn = Random(1234);
  final stream = encrypted
      ? Uint8List.fromList(
          List<int>.generate(
            compressed.length,
            (_) => cipherStandIn.nextInt(256),
          ),
        )
      : compressed;
  final nData = Encoder.dataPageCount(compressed.length);
  final chunkSize = (compressed.length + nData - 1) ~/ nData;
  final chunks = <Uint8List>[];
  for (var i = 0; i < nData; i++) {
    final start = i * chunkSize;
    final end = (start + chunkSize).clamp(0, stream.length);
    if (end - start == chunkSize) {
      chunks.add(Uint8List.sublistView(stream, start, end));
    } else {
      final padded = Uint8List(chunkSize)
        ..setAll(0, stream.sublist(start, end));
      chunks.add(padded);
    }
  }
  // Real SHA-256 of the original (the cover prints sizes only, but
  // the frames must carry a well-formed header).
  final sha = Uint8List.fromList(sha256.convert(data).bytes);
  final frames = Encoder.buildFrames(
    chunks: chunks,
    sha256Bytes: sha,
    originalSize: data.length,
    compressedSize: stream.length,
    salt: Uint8List(16),
    nonce: Uint8List(12),
    encrypted: encrypted,
    barcode: false,
    equalSplit: true,
  );
  final result = EncodeResult(
    frames: frames,
    stats: EncodeStats(
      originalSize: data.length,
      compressedSize: stream.length,
      frameCount: frames.length,
      groupCount: (nData + 5) ~/ 6,
      sha256Hex: sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    ),
    barcode: false,
  );
  final (pdfBytes, _) = await PdfDocument.build(result, 'test.bin');
  return pdfBytes.length;
}

void main() {
  group('EncodeController.estimateFor', () {
    test('hero case (1.04 GB at 73x) follows the adaptive page rule', () {
      // The data page count comes from the shared adaptive rule
      // (Encoder.dataPageCount), not from a fixed target: the test
      // pins the relationship, not a page count the rule may change.
      final estCompressed = (1040000000 / 73).ceil();
      final data = Encoder.dataPageCount(estCompressed);
      final estimate = EncodeController.estimateFor(
        fileSize: 1040000000,
        ratio: 73,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.dataFrames, data);
      expect(
        estimate.estimatedFrames,
        data + Erasure.parityFrameCount(data),
      );
      expect(estimate.parityFrames, Erasure.parityFrameCount(data));
      expect(estimate.overCap, isFalse);
      expect(estimate.incompressible, isFalse);
      // ~14.2 MB compressed on 1 data page + 1 parity page: the PDF
      // is ~2x the compressed stream, not hundreds of MB.
      expect(estimate.estimatedPdfBytes, greaterThan(14 * 1024 * 1024));
      expect(estimate.estimatedPdfBytes, lessThan(40 * 1024 * 1024));
    });

    test('300 MB incompressible follows the rule in memory, over cap '
        'streamed', () {
      const estCompressed = 300 * 1024 * 1024;
      final data = Encoder.dataPageCount(estCompressed);
      final estimate = EncodeController.estimateFor(
        fileSize: 300 * 1024 * 1024,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.dataFrames, data);
      expect(
        estimate.estimatedFrames,
        data + Erasure.parityFrameCount(data),
      );
      expect(estimate.overCap, isFalse);
      expect(estimate.incompressible, isTrue);
      // Streaming uses fixed 64 KiB chunks, so it CAN exceed the cap:
      // 4,800 data + 1,600 parity = 6,400 frames.
      final streamed = EncodeController.estimateFor(
        fileSize: 300 * 1024 * 1024,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
        streaming: true,
      );
      expect(streamed.estimatedFrames, 6400);
      expect(streamed.overCap, isTrue);
      expect(
        EncodeController.capAdvice(streamed.estimatedFrames),
        allOf(contains('6400'), contains('Split')),
      );
    });

    test('67 MB mp4 at its real ratio is under the new cap', () {
      // The reported file needed 1,125 frames (~55 MB compressed, so a
      // ratio of ~1.27); the cap is 4,096. In memory it equal-splits
      // to the adaptive page count; streamed it frames to ~1,126.
      final estCompressed = (67 * 1024 * 1024 / 1.27).ceil();
      final data = Encoder.dataPageCount(estCompressed);
      final estimate = EncodeController.estimateFor(
        fileSize: 67 * 1024 * 1024,
        ratio: 1.27,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.dataFrames, data);
      expect(estimate.overCap, isFalse);
      expect(estimate.incompressible, isFalse);
      final streamed = EncodeController.estimateFor(
        fileSize: 67 * 1024 * 1024,
        ratio: 1.27,
        sampleBytes: 768 * 1024,
        streaming: true,
      );
      expect(streamed.estimatedFrames, greaterThan(1000));
      expect(streamed.estimatedFrames, lessThan(4096));
      expect(streamed.overCap, isFalse);
    });

    test('incompressible flag is ratio < 1.1', () {
      expect(
        EncodeController.estimateFor(
          fileSize: 1024,
          ratio: 1.0,
          sampleBytes: 1024,
        ).incompressible,
        isTrue,
      );
      expect(
        EncodeController.estimateFor(
          fileSize: 1024,
          ratio: 1.05,
          sampleBytes: 1024,
        ).incompressible,
        isTrue,
      );
      // Exactly 1.1 is NOT incompressible: zlib saved ~9%.
      expect(
        EncodeController.estimateFor(
          fileSize: 1024,
          ratio: 1.1,
          sampleBytes: 1024,
        ).incompressible,
        isFalse,
      );
      expect(
        EncodeController.estimateFor(
          fileSize: 1024,
          ratio: 73,
          sampleBytes: 1024,
        ).incompressible,
        isFalse,
      );
    });

    test('plain payloads re-compress in the model, encrypted ones do not',
        () {
      // A 1 MiB text file at 142x: encrypted (default) the PDF images
      // carry random bytes, so the PDF is ~2x the compressed stream;
      // plain, the second pass squeezes the images again.
      final encrypted = EncodeController.estimateFor(
        fileSize: 1023420,
        ratio: 142.28,
        sampleBytes: 768 * 1024,
        encrypted: true,
      );
      final plain = EncodeController.estimateFor(
        fileSize: 1023420,
        ratio: 142.28,
        sampleBytes: 768 * 1024,
        encrypted: false,
        secondPassFactor: 0.472,
      );
      expect(
        plain.estimatedPdfBytes,
        lessThan(encrypted.estimatedPdfBytes),
      );
      // The encrypted model is the accurate one (measured 21,137
      // actual for this file at 1 data page); the plain model
      // over-states (measured 9,089) because 256 KiB samples cannot
      // see long-range repetition — documented in estimateFor, safe
      // direction. The precise within-10% check against a real build
      // with the rule's actual page count lives in the model group
      // below; this test only pins the ordering and the magnitude.
      expect(encrypted.estimatedPdfBytes, greaterThan(14 * 1024));
      expect(encrypted.estimatedPdfBytes, lessThan(30 * 1024));
      expect(plain.estimatedPdfBytes, greaterThan(9089));
      expect(plain.estimatedPdfBytes, lessThan(9089 * 1.6));
    });
  });

  group('estimate model vs real builds', () {
    // The model is verified against REAL PdfDocument builds, with the
    // page count the adaptive rule actually says — so a rule change
    // re-verifies itself instead of silently passing against a stale
    // hardcoded page count. Tolerances are 10%: the model is
    // deliberately a few percent conservative (over, never under, for
    // incompressible files).
    test('2 MiB random file, encrypted (default path)', () async {
      final random = Random(7);
      final data = Uint8List(2 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      final compressed = const ZLibEncoder().encode(data, level: 9);
      final ratio = data.length / compressed.length;
      final estimate = EncodeController.estimateFor(
        fileSize: data.length,
        ratio: ratio,
        sampleBytes: data.length,
        encrypted: true,
      );
      final actual = await _actualPdfBytes(data, encrypted: true);
      // Measured standalone: actual 4,216,281 at 1 data page.
      expect(estimate.incompressible, isTrue);
      expect(
        estimate.estimatedPdfBytes,
        closeTo(actual, actual * 0.10),
      );
      expect(estimate.estimatedPdfBytes, greaterThan(actual));
    }, onPlatform: const {
      'chrome': Skip(
        '2 MiB grid build (~35M cells) exceeds the 30s default under '
        'DDC; the VM run covers it, and the 256 KiB Chrome test below '
        'covers the same model in the browser',
      ),
    });

    test('256 KiB random file, encrypted (Chrome model check)', () async {
      // Same model, small enough for DDC: ~4.4M cells, seconds even
      // in the browser. Proves the formula end-to-end under dart2js
      // (deflate behaviour is the platform-sensitive part).
      final random = Random(7);
      final data = Uint8List(256 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      final compressed = const ZLibEncoder().encode(data, level: 9);
      final ratio = data.length / compressed.length;
      final estimate = EncodeController.estimateFor(
        fileSize: data.length,
        ratio: ratio,
        sampleBytes: data.length,
        encrypted: true,
      );
      final actual = await _actualPdfBytes(data, encrypted: true);
      expect(estimate.incompressible, isTrue);
      expect(
        estimate.estimatedPdfBytes,
        closeTo(actual, actual * 0.10),
      );
      expect(estimate.estimatedPdfBytes, greaterThan(actual));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('20 MiB random file, encrypted (2 data pages)', () async {
      final random = Random(7);
      final data = Uint8List(20 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      final compressed = const ZLibEncoder().encode(data, level: 9);
      final ratio = data.length / compressed.length;
      final estimate = EncodeController.estimateFor(
        fileSize: data.length,
        ratio: ratio,
        sampleBytes: data.length,
        encrypted: true,
      );
      final actual = await _actualPdfBytes(data, encrypted: true);
      // Measured standalone: actual 31,526,784 at 2 data pages.
      expect(estimate.dataFrames, 2);
      expect(estimate.incompressible, isTrue);
      expect(
        estimate.estimatedPdfBytes,
        closeTo(actual, actual * 0.10),
      );
      expect(estimate.estimatedPdfBytes, greaterThan(actual));
    }, timeout: const Timeout(Duration(minutes: 2)), onPlatform: const {
      'chrome': Skip(
        '20 MB grid build (~263M cells) is too slow under DDC; the VM '
        'run and the 2 MiB Chrome run cover the model',
      ),
    });

    test('demo file (README x461), encrypted', () async {
      final readme = File('README.md').readAsBytesSync();
      final data = Uint8List.fromList(
        [for (var i = 0; i < 461; i++) ...readme],
      );
      expect(data.length, 1023420);
      final compressed = const ZLibEncoder().encode(data, level: 9);
      final ratio = data.length / compressed.length;
      final estimate = EncodeController.estimateFor(
        fileSize: data.length,
        ratio: ratio,
        sampleBytes: data.length,
        encrypted: true,
      );
      final actual = await _actualPdfBytes(data, encrypted: true);
      // Measured standalone: actual 21,137 at 1 data page.
      expect(estimate.incompressible, isFalse);
      expect(
        estimate.estimatedPdfBytes,
        closeTo(actual, actual * 0.10),
      );
      expect(estimate.estimatedPdfBytes, greaterThan(actual));
    }, onPlatform: const {
      'chrome': Skip(
        'demo fixture is read via dart:io File, which does not exist '
        'on web; the VM run covers it',
      ),
    });

    test('demo file, plain (KNOWN MISS: over-states ~45%)', () async {
      // Unencrypted, the sample second-pass factor (0.47) cannot see
      // the whole file's long-range repetition (whole-file factor
      // 0.18), so the model over-states. This test pins the miss so
      // it stays visible: over, never under, and bounded.
      final readme = File('README.md').readAsBytesSync();
      final data = Uint8List.fromList(
        [for (var i = 0; i < 461; i++) ...readme],
      );
      final sample = Uint8List.sublistView(data, 0, 256 * 1024);
      final sampleCompressed =
          const ZLibEncoder().encode(sample, level: 9);
      final sampleRecompressed = const ZLibEncoder().encode(
        sampleCompressed,
        level: 6,
      );
      final factor = sampleRecompressed.length / sampleCompressed.length;
      final compressed = const ZLibEncoder().encode(data, level: 9);
      final estimate = EncodeController.estimateFor(
        fileSize: data.length,
        ratio: data.length / compressed.length,
        sampleBytes: data.length,
        encrypted: false,
        secondPassFactor: factor,
      );
      final actual = await _actualPdfBytes(data, encrypted: false);
      // Measured standalone: actual 9,089.
      expect(estimate.estimatedPdfBytes, greaterThan(actual));
      expect(estimate.estimatedPdfBytes, lessThan(actual * 1.6));
    }, onPlatform: const {
      'chrome': Skip(
        'demo fixture is read via dart:io File, which does not exist '
        'on web; the VM run covers it',
      ),
    });
  });

  group('refreshEstimate', () {
    test('uses the worst sample ratio, not the head', () async {
      final controller = EncodeController();
      final bytes = _mixedBytes();
      controller.file = PickedRef(
        name: 'clip.mp4',
        size: bytes.length,
        bytes: bytes,
      );
      await controller.refreshEstimate();
      final estimate = controller.estimate!;
      // The tail is random: worst ratio clamps to 1.0, so the estimate
      // prices the whole file as incompressible, at the adaptive page
      // count — not the old 16-data-page shape.
      expect(estimate.ratio, 1.0);
      expect(
        estimate.dataFrames,
        Encoder.dataPageCount(1024 * 1024),
      );
      expect(
        estimate.estimatedFrames,
        estimate.dataFrames +
            Erasure.parityFrameCount(estimate.dataFrames),
      );
      expect(estimate.incompressible, isTrue);
      expect(estimate.memoryGuard.level, MemoryGuardLevel.ok);
      expect(estimate.sampleBytes, 3 * 256 * 1024);
      expect(estimate.overCap, isFalse);
    });

    test('small files are sampled whole', () async {
      final controller = EncodeController();
      final bytes = Uint8List(100 * 1024);
      controller.file = PickedRef(
        name: 'note.bin',
        size: bytes.length,
        bytes: bytes,
      );
      await controller.refreshEstimate();
      expect(controller.estimate!.sampleBytes, bytes.length);
    });
  });

  group('encode error state', () {
    test('a failed encode resets progress (no stuck 15%)', () async {
      final controller = EncodeController(picker: _ThrowingPicker());
      controller.file = PickedRef(
        name: 'x.bin',
        size: 100,
        bytes: Uint8List(100),
      );
      controller.encrypted = false;
      controller.phase = EncodePhase.ready;
      controller.progress = 0.5;
      controller.progressLabel = 'Compressing…';
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.progress, 0);
      expect(controller.progressLabel, 'Failed');
      expect(controller.error, contains('disk gone'));
    });

    test('missing passphrase also resets progress', () async {
      final controller = EncodeController();
      controller.file = PickedRef(
        name: 'x.bin',
        size: 100,
        bytes: Uint8List(100),
      );
      controller.encrypted = true;
      controller.passphrase = '';
      controller.phase = EncodePhase.ready;
      controller.progress = 0.5;
      controller.progressLabel = 'Compressing…';
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.progress, 0);
      expect(controller.progressLabel, 'Failed');
      expect(controller.error, contains('passphrase'));
    });

    test('small encode succeeds end to end (staged path)', () async {
      final controller = EncodeController();
      final unit = 'Middle Out staged encode test. '.codeUnits;
      final bytes = Uint8List.fromList(
        [for (var i = 0; i < 10; i++) ...unit],
      );
      controller.file = PickedRef(
        name: 'note.txt',
        size: bytes.length,
        bytes: bytes,
      );
      controller.encrypted = false;
      controller.phase = EncodePhase.ready;
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.result, isNotNull);
      expect(controller.pdfBytes, isNotNull);
      expect(controller.progress, 1);
      expect(controller.progressLabel, 'Done');
    });
  });

  group('encode retry after failure', () {
    // 2-minute timeout: the retry runs a full encrypted encode, which
    // exceeds the 30s default under DDC (`--platform chrome`). Fast on
    // the VM and proven live on the release site.
    test('setting the passphrase after the missing-passphrase error '
        'retries cleanly', () async {
      final controller = EncodeController();
      final unit = 'Middle Out retry test. '.codeUnits;
      final bytes = Uint8List.fromList(
        [for (var i = 0; i < 10; i++) ...unit],
      );
      controller.file = PickedRef(
        name: 'note.txt',
        size: bytes.length,
        bytes: bytes,
      );
      controller.encrypted = true;
      controller.passphrase = '';
      controller.phase = EncodePhase.ready;
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.error, contains('passphrase'));
      // The live-app bug: the phase stayed at error, so re-entering the
      // progress screen never started a new encode and every retry
      // showed this first failure. Changing an input must clear it.
      controller.setPassphrase('middle-out-test');
      expect(controller.error, isNull);
      expect(controller.phase, EncodePhase.ready);
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.pdfBytes, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('turning encryption off after the error also clears it', () async {
      final controller = EncodeController();
      final unit = 'Middle Out retry test. '.codeUnits;
      final bytes = Uint8List.fromList(
        [for (var i = 0; i < 10; i++) ...unit],
      );
      controller.file = PickedRef(
        name: 'note.txt',
        size: bytes.length,
        bytes: bytes,
      );
      controller.encrypted = true;
      controller.passphrase = '';
      controller.phase = EncodePhase.ready;
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      controller.setEncrypted(false);
      expect(controller.error, isNull);
      expect(controller.phase, EncodePhase.ready);
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.pdfBytes, isNotNull);
    });

    test('encode is re-runnable from the error phase (Try again)', () async {
      final controller = EncodeController(picker: _ThrowingPicker());
      controller.file = PickedRef(
        name: 'x.bin',
        size: 100,
        bytes: Uint8List(100),
      );
      controller.encrypted = false;
      controller.phase = EncodePhase.ready;
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      // Retrying directly (what the Try again button does) re-runs the
      // encode instead of showing the stale error.
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.error, contains('disk gone'));
    });
  });

  group('PDF theme toggle', () {
    test('pdfDark defaults to light and setPdfDark flips it', () {
      final controller = EncodeController();
      expect(controller.pdfDark, isFalse);
      controller.setPdfDark(true);
      expect(controller.pdfDark, isTrue);
      controller.setPdfDark(false);
      expect(controller.pdfDark, isFalse);
    });

    test('reset keeps the theme toggle (like format and encryption)',
        () async {
      final controller = EncodeController();
      controller.setPdfDark(true);
      controller.reset();
      expect(controller.pdfDark, isTrue);
    });

    test('dark encode succeeds end to end', () async {
      final controller = EncodeController();
      final unit = 'Middle Out dark encode test. '.codeUnits;
      final bytes = Uint8List.fromList(
        [for (var i = 0; i < 10; i++) ...unit],
      );
      controller.file = PickedRef(
        name: 'note.txt',
        size: bytes.length,
        bytes: bytes,
      );
      controller.encrypted = false;
      controller.setPdfDark(true);
      controller.phase = EncodePhase.ready;
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.pdfBytes, isNotNull);
      expect(controller.pdfStats!.pages, controller.result!.frames.length + 1);
    });
  });
}
