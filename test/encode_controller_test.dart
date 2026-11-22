import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  group('EncodeController.estimateFor', () {
    test('hero case (1.04 GB at 73x) is 27 frames, under cap', () {
      // Equal split caps the in-memory path at 20 data + 7 parity.
      final estimate = EncodeController.estimateFor(
        fileSize: 1040000000,
        ratio: 73,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.estimatedFrames, 27);
      expect(estimate.overCap, isFalse);
    });

    test('300 MB incompressible is 27 frames in memory, over cap streamed',
        () {
      final estimate = EncodeController.estimateFor(
        fileSize: 300 * 1024 * 1024,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.estimatedFrames, 27);
      expect(estimate.overCap, isFalse);
      // Streaming uses fixed 64 KiB chunks, so it CAN exceed the cap.
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
      // to 27 frames; streamed it frames to ~1,127.
      final estimate = EncodeController.estimateFor(
        fileSize: 67 * 1024 * 1024,
        ratio: 1.27,
        sampleBytes: 768 * 1024,
      );
      expect(estimate.estimatedFrames, 27);
      expect(estimate.overCap, isFalse);
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
      // prices the whole file as incompressible (16 data + 6 parity).
      expect(estimate.ratio, 1.0);
      expect(estimate.estimatedFrames, 22);
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
