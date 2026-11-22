
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../codec/decoder.dart';
import '../codec/encoder.dart';
import '../codec/frame.dart';
import '../codec/pdf_document.dart';
import '../codec/streaming_encoder.dart';
import '../core/constants.dart';
import '../services/file_picker_service.dart';
import '../services/file_reader.dart';
import '../services/file_saver.dart' show saveFileBytes;
import '../services/frame_inspector.dart';
import '../services/pdf_frame_extractor.dart';
import '../services/pdf_saver.dart' show savePdf;
import '../services/platform_limits.dart';
import '../services/share_service.dart';
import 'history_store.dart';
import 'settings_controller.dart';

/// Where the encode flow is.
enum EncodePhase {
  /// Nothing picked yet.
  idle,

  /// The system picker is open.
  picking,

  /// A file is picked and ready to encode.
  ready,

  /// Encoding is running.
  encoding,

  /// Encoded; the result is ready.
  done,

  /// Something failed — see [EncodeController.error].
  error,
}

/// A pre-encode estimate, sampled from the head, middle and tail of the
/// file (or the whole file, when it is small).
///
/// The ratio is the worst (lowest) across the samples, extrapolated; the
/// UI labels it an estimate. Real ratios depend entirely on the input.
class EncodeEstimate {
  /// Creates an estimate.
  const EncodeEstimate({
    required this.ratio,
    required this.estimatedFrames,
    required this.estimatedPdfBytes,
    required this.estimatedSeconds,
    required this.sampleBytes,
    this.overCap = false,
  });

  /// Estimated compression ratio from the sample.
  final double ratio;

  /// Estimated frame count (data + parity).
  final int estimatedFrames;

  /// Estimated PDF size in bytes.
  final int estimatedPdfBytes;

  /// Estimated encode time in seconds (rough local throughput).
  final int estimatedSeconds;

  /// Bytes sampled for the estimate.
  final int sampleBytes;

  /// True when the estimated frame count exceeds [kMaxFrames] — the
  /// estimate screen warns before the user encodes.
  final bool overCap;
}

/// State for the encode flow: picked file, toggles, progress, result.
///
/// Owns the whole pipeline: pick (limit-gated, by reference — bytes are
/// only read when encoding starts) -> estimate -> encode -> PDF.
/// Large native files (at or above [streamingThresholdBytes]) encode
/// through [StreamingEncoder] so the file is never loaded whole; smaller
/// files and web files use the in-memory path.
class EncodeController extends ChangeNotifier {
  /// Creates an encode controller with the platform-default mode.
  EncodeController({FilePickerService? picker})
      : _picker = picker ?? FilePickerService(),
        mode = PlatformLimitsService.defaultMode();

  final FilePickerService _picker;

  /// Files at or above this size use the streaming encoder on native.
  static const int streamingThresholdBytes = 32 * 1024 * 1024;

  /// Size of each estimate sample (256 KiB). Three are taken — head,
  /// middle and tail — for 768 KiB total.
  static const int estimateSampleChunkBytes = 256 * 1024;

  /// Builds an estimate from a measured compression [ratio] and file
  /// size. Pure (no I/O) so the frame-count and cap math is unit-testable.
  static EncodeEstimate estimateFor({
    required int fileSize,
    required double ratio,
    required int sampleBytes,
  }) {
    final clampedRatio = ratio.clamp(1.0, 1000.0);
    final estCompressed = (fileSize / clampedRatio).ceil();
    final dataFrames =
        (estCompressed + kDefaultMaxPayload - 1) ~/ kDefaultMaxPayload;
    final groups =
        (dataFrames + kGroupDataFrames - 1) ~/ kGroupDataFrames;
    final frames = dataFrames + groups * kGroupParityFrames;
    return EncodeEstimate(
      ratio: clampedRatio,
      estimatedFrames: frames,
      // ~60 KB per full-page code image + cover overhead.
      estimatedPdfBytes: frames * 60000 + 20000,
      estimatedSeconds:
          (fileSize / (25 * 1024 * 1024)).ceil().clamp(1, 3600 * 24),
      sampleBytes: sampleBytes,
      overCap: frames > kMaxFrames,
    );
  }

  /// Routing advice when an encode would exceed the frame cap.
  static String capAdvice(int estimatedFrames) =>
      'This file would need about $estimatedFrames frames — over the '
      '$kMaxFrames-frame limit for one PDF. Split it into smaller files '
      'and encode each one separately.';

  /// Current phase.
  EncodePhase phase = EncodePhase.idle;

  /// Encode mode (decides the per-file limit).
  EncodeMode mode;

  /// Picked file reference (bytes loaded lazily).
  PickedRef? file;

  /// QR-style grid (false) or stacked-row barcode (true). Default: grid.
  bool barcode = false;

  /// Encrypted (default ON): payload is not human-readable when scanned.
  bool encrypted = true;

  /// Passphrase for encryption. Never stored, never leaves the device.
  String passphrase = '';

  /// Encode progress 0..1.
  double progress = 0;

  /// Human-readable progress label.
  String progressLabel = '';

  /// Pre-encode estimate, refreshed when a file is picked.
  EncodeEstimate? estimate;

  /// True when the last encode ran through the streaming encoder.
  bool streamed = false;

  /// Encode result.
  EncodeResult? result;

  /// Assembled PDF bytes.
  Uint8List? pdfBytes;

  /// PDF statistics.
  PdfStats? pdfStats;

  /// Where the PDF was saved, if the user saved it.
  String? savedPath;

  /// Last error message, if any.
  String? error;

  /// Called with the history record after a successful encode.
  Future<void> Function(HistoryRecord record)? onEncoded;

  /// Warning when the PDF lands outside the 5–20 MB-per-GB band.
  String? get pdfBandWarning => result == null || pdfStats == null
      ? null
      : PlatformLimitsService.pdfBandWarning(
          result!.stats.originalSize,
          pdfStats!.sizeBytes,
        );

  /// Applies the user's default toggles (called once at app start).
  void applySettings(SettingsController settings) {
    barcode = settings.defaultBarcode;
    encrypted = settings.defaultEncrypted;
    notifyListeners();
  }

  /// Sets the encode mode, re-checking the picked file against it.
  void setMode(EncodeMode next) {
    if (mode == next) return;
    mode = next;
    // A picked file may no longer fit the new mode.
    if (file != null && !PlatformLimitsService.fits(file!.size, mode)) {
      error = PlatformLimitsService.overLimitAdvice(file!.size, mode);
      phase = EncodePhase.error;
    } else {
      error = null;
      if (phase == EncodePhase.error) phase = EncodePhase.ready;
    }
    notifyListeners();
  }

  /// Sets the code format.
  void setBarcode(bool value) {
    barcode = value;
    notifyListeners();
  }

  /// Sets the encryption toggle.
  void setEncrypted(bool value) {
    encrypted = value;
    notifyListeners();
  }

  /// Sets the passphrase.
  void setPassphrase(String value) {
    passphrase = value;
    notifyListeners();
  }

  /// Opens the system picker (limit-gated) and refreshes the estimate.
  Future<void> pickFile() async {
    phase = EncodePhase.picking;
    error = null;
    notifyListeners();
    try {
      final picked = await _picker.pickFileMeta(mode);
      if (picked == null) {
        phase = file == null ? EncodePhase.idle : EncodePhase.ready;
      } else {
        file = picked;
        result = null;
        pdfBytes = null;
        pdfStats = null;
        savedPath = null;
        streamed = false;
        phase = EncodePhase.ready;
        await refreshEstimate();
      }
    } on FileTooLargeException catch (e) {
      error = e.message;
      phase = EncodePhase.error;
    } catch (e) {
      error = 'Could not pick a file: $e';
      phase = EncodePhase.error;
    }
    notifyListeners();
  }

  /// (Re)computes the pre-encode estimate from head, middle and tail
  /// samples, using the worst (lowest) ratio across them. A head-only
  /// sample undershoots badly on media files: an .mp4's metadata head
  /// compresses far better than its video data. Conservative beats
  /// optimistic — an over-estimate only warns early, an under-estimate
  /// fails the encode halfway through.
  Future<void> refreshEstimate() async {
    final current = file;
    if (current == null) {
      estimate = null;
      return;
    }
    try {
      final samples = await _picker.readRefSamples(
        current,
        estimateSampleChunkBytes,
      );
      var ratio = double.infinity;
      var sampled = 0;
      for (final sample in samples) {
        if (sample.isEmpty) continue;
        final compressed = const ZLibEncoder().encode(sample, level: 9);
        final sampleRatio = compressed.isEmpty
            ? 1.0
            : sample.length / compressed.length;
        if (sampleRatio < ratio) ratio = sampleRatio;
        sampled += sample.length;
      }
      if (ratio.isInfinite) ratio = 1.0;
      estimate = estimateFor(
        fileSize: current.size,
        ratio: ratio,
        sampleBytes: sampled,
      );
    } catch (_) {
      estimate = null;
    }
    notifyListeners();
  }

  /// Records a failed encode. The progress bar resets to 0 and the label
  /// reads 'Failed' so an error never sits next to a stale mid-encode
  /// bar and stage (the old code left 15% + 'Compressing…' on screen,
  /// which read as stuck, not failed).
  void _fail(String message) {
    error = message;
    phase = EncodePhase.error;
    progress = 0;
    progressLabel = 'Failed';
  }

  /// Runs the encode, then builds the PDF and records history.
  Future<void> encode() async {
    final current = file;
    if (current == null || phase == EncodePhase.encoding) return;
    if (encrypted && passphrase.isEmpty) {
      _fail('Encryption is on — set a passphrase, or turn it off.');
      notifyListeners();
      return;
    }
    phase = EncodePhase.encoding;
    error = null;
    progress = 0;
    progressLabel = 'Reading file…';
    notifyListeners();
    try {
      await Future<void>.delayed(Duration.zero);
      final useStreaming = !kIsWeb &&
          StreamingEncoder.isSupported &&
          current.hasPath &&
          current.size >= streamingThresholdBytes;
      final EncodeResult encoded;
      if (useStreaming) {
        streamed = true;
        encoded = await StreamingEncoder.encodeFile(
          path: current.path!,
          passphrase: encrypted ? passphrase : null,
          barcode: barcode,
          onProgress: (fraction, label) {
            progress = fraction * 0.8;
            progressLabel = label;
            notifyListeners();
          },
        );
      } else {
        streamed = false;
        final bytes = await _picker.readRef(current);
        encoded = await Encoder.encodeAsync(
          bytes,
          passphrase: encrypted ? passphrase : null,
          barcode: barcode,
          onProgress: (fraction, label) {
            progress = fraction * 0.8;
            progressLabel = label;
            notifyListeners();
          },
        );
      }
      progress = 0.85;
      progressLabel = 'Building ${encoded.frames.length} frames…';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);

      final (bytes, stats) = await PdfDocument.build(encoded, current.name);
      result = encoded;
      pdfBytes = bytes;
      pdfStats = stats;
      progress = 1;
      progressLabel = 'Done';
      phase = EncodePhase.done;
      final record = HistoryRecord(
        id: HistoryRecord.newId(),
        kind: HistoryKind.encode,
        fileName: current.name,
        originalBytes: encoded.stats.originalSize,
        encodedBytes: encoded.stats.compressedSize,
        frameCount: encoded.stats.frameCount,
        groupCount: encoded.stats.groupCount,
        barcode: barcode,
        encrypted: encrypted,
        sha256Hex: encoded.stats.sha256Hex,
        createdAt: DateTime.now(),
      );
      await onEncoded?.call(record);
    } on CodecException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('Encode failed: $e');
    }
    notifyListeners();
  }

  /// Saves the result PDF to the device.
  Future<void> saveResultPdf() async {
    final bytes = pdfBytes;
    final name = file?.name;
    if (bytes == null || name == null) return;
    try {
      savedPath = await savePdf(bytes, '$name.middleout.pdf');
    } catch (e) {
      error = 'Could not save the PDF: $e';
    }
    notifyListeners();
  }

  /// Shares the result PDF through the system share sheet.
  Future<void> shareResultPdf() async {
    final bytes = pdfBytes;
    final name = file?.name;
    if (bytes == null || name == null) return;
    try {
      await ShareService.sharePdf(bytes, '$name.middleout.pdf');
    } catch (e) {
      error = 'Could not share the PDF: $e';
      notifyListeners();
    }
  }

  /// Resets the flow to idle (keeps the toggles and mode).
  void reset() {
    phase = EncodePhase.idle;
    file = null;
    progress = 0;
    progressLabel = '';
    estimate = null;
    streamed = false;
    result = null;
    pdfBytes = null;
    pdfStats = null;
    savedPath = null;
    error = null;
    notifyListeners();
  }
}

/// Where the decode flow is.
enum DecodePhase {
  /// Nothing imported yet.
  idle,

  /// Importing a PDF or frame files.
  importing,

  /// Frames imported and inspected, ready to decode.
  ready,

  /// Decoding is running.
  decoding,

  /// Decoded and SHA-256 verified.
  done,

  /// Something failed — see [DecodeController.error].
  error,
}

/// State for the decode flow.
///
/// Decodes from a Middle Out PDF (frames recovered from the code images
/// by [PdfFrameExtractor]) or from exported `.bin` frame files, in any
/// order. Lost or corrupt frames are rebuilt from parity where possible;
/// the result is verified against the SHA-256 in the frame headers before
/// anything is shown as decoded.
class DecodeController extends ChangeNotifier {
  /// Current phase.
  DecodePhase phase = DecodePhase.idle;

  /// Passphrase for encrypted frames. Never stored.
  String passphrase = '';

  /// Imported frame blobs.
  List<Uint8List> blobs = [];

  /// What was imported: 'pdf' or 'frames'.
  String? sourceKind;

  /// Name of the imported PDF or frame set.
  String? sourceName;

  /// Inspection of the imported frames (counts, damage, recoverability).
  FrameInspection? inspection;

  /// Decoded bytes (only set after SHA-256 verification).
  Uint8List? decoded;

  /// Name for the decoded file.
  String? decodedName;

  /// SHA-256 the frames promise (from the frame headers).
  String? expectedSha256;

  /// SHA-256 of the rebuilt bytes.
  String? actualSha256;

  /// Global DATA indices rebuilt from parity during the decode.
  List<int> recoveredIndices = [];

  /// Last error message, if any.
  String? error;

  /// Called with the history record after a verified decode.
  Future<void> Function(HistoryRecord record)? onDecoded;

  /// Sets the passphrase.
  void setPassphrase(String value) {
    passphrase = value;
    notifyListeners();
  }

  /// Imports a Middle Out PDF: recovers the frames from its code images.
  Future<void> importPdf(Uint8List pdfBytes, String name) async {
    phase = DecodePhase.importing;
    error = null;
    notifyListeners();
    try {
      await Future<void>.delayed(Duration.zero);
      final extraction = PdfFrameExtractor.extract(pdfBytes);
      if (extraction.frames.isEmpty) {
        error = 'No Middle Out frames found in this PDF '
            '(${extraction.imagesFound} image(s) scanned). '
            'Import a PDF produced by Middle Out, or its .bin frame files.';
        phase = DecodePhase.error;
        notifyListeners();
        return;
      }
      _acceptBlobs(extraction.frames, name, 'pdf');
    } catch (e) {
      error = 'Could not read this PDF: $e';
      phase = DecodePhase.error;
      notifyListeners();
    }
  }

  /// Opens the picker for `.bin` frame files and imports them.
  Future<void> importFrameFiles() async {
    phase = DecodePhase.importing;
    error = null;
    notifyListeners();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['bin'],
        allowMultiple: true,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) {
        phase = blobs.isEmpty ? DecodePhase.idle : DecodePhase.ready;
        notifyListeners();
        return;
      }
      final picked = <Uint8List>[];
      for (final file in result.files) {
        if (file.bytes != null) {
          picked.add(file.bytes!);
        } else if (!kIsWeb && file.path != null) {
          // On web `PlatformFile.path` THROWS when read — never touch it
          // there (bytes are loaded via `withData: kIsWeb` above).
          picked.add(await readPickedFile(file.path!));
        }
      }
      _acceptBlobs(picked, '${picked.length} frame file(s)', 'frames');
    } catch (e) {
      error = 'Could not import frame files: $e';
      phase = DecodePhase.error;
      notifyListeners();
    }
  }

  /// Imports already-read frame blobs (used by the scan screen fallback
  /// and by tests).
  void importBlobs(List<Uint8List> frameBlobs, String name) {
    _acceptBlobs(frameBlobs, name, 'frames');
  }

  void _acceptBlobs(List<Uint8List> frameBlobs, String name, String kind) {
    try {
      final inspected = FrameInspector.inspect(frameBlobs);
      blobs = frameBlobs;
      sourceKind = kind;
      sourceName = name;
      inspection = inspected;
      expectedSha256 = inspected.expectedSha256Hex;
      if (!inspected.recoverable) {
        error = 'Too much damage to rebuild: '
            '${inspected.unrecoverableReason}.';
        phase = DecodePhase.error;
        notifyListeners();
        return;
      }
      phase = DecodePhase.ready;
    } on CodecException catch (e) {
      error = e.message;
      phase = DecodePhase.error;
    }
    notifyListeners();
  }

  /// Decodes the imported frames: parity recovery, decrypt, decompress,
  /// SHA-256 verify. On success the verify screen shows both hashes.
  Future<void> decodeFrames() async {
    if (blobs.isEmpty || phase == DecodePhase.decoding) return;
    phase = DecodePhase.decoding;
    error = null;
    notifyListeners();
    try {
      await Future<void>.delayed(Duration.zero);
      final rebuilt = Decoder.decode(
        blobs,
        passphrase: passphrase.isEmpty ? null : passphrase,
      );
      decoded = rebuilt;
      decodedName = _decodedName();
      actualSha256 =
          sha256.convert(rebuilt).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      recoveredIndices =
          List<int>.from(inspection?.recoveredViaParity ?? const []);
      phase = DecodePhase.done;
      final inspected = inspection;
      if (inspected != null) {
        final record = HistoryRecord(
          id: HistoryRecord.newId(),
          kind: HistoryKind.decode,
          fileName: decodedName!,
          originalBytes: rebuilt.length,
          encodedBytes:
              blobs.fold(0, (sum, blob) => sum + blob.length),
          frameCount: inspected.totalFrames,
          groupCount: inspected.totalGroups,
          barcode: inspected.barcode,
          encrypted: inspected.encrypted,
          sha256Hex: actualSha256!,
          createdAt: DateTime.now(),
        );
        await onDecoded?.call(record);
      }
    } on CodecException catch (e) {
      error = e.message;
      phase = DecodePhase.error;
    } catch (e) {
      error = 'Decode failed: $e';
      phase = DecodePhase.error;
    }
    notifyListeners();
  }

  /// Saves the decoded file to the device.
  Future<void> saveDecoded() async {
    final bytes = decoded;
    final name = decodedName;
    if (bytes == null || name == null) return;
    try {
      await saveFileBytes(bytes, name);
    } catch (e) {
      error = 'Could not save the file: $e';
      notifyListeners();
    }
  }

  /// Shares the decoded file through the system share sheet.
  Future<void> shareDecoded() async {
    final bytes = decoded;
    final name = decodedName;
    if (bytes == null || name == null) return;
    try {
      await ShareService.shareBytes(
        bytes,
        name,
        'application/octet-stream',
      );
    } catch (e) {
      error = 'Could not share the file: $e';
      notifyListeners();
    }
  }

  /// Resets the flow to idle.
  void reset() {
    phase = DecodePhase.idle;
    blobs = [];
    sourceKind = null;
    sourceName = null;
    inspection = null;
    decoded = null;
    decodedName = null;
    expectedSha256 = null;
    actualSha256 = null;
    recoveredIndices = [];
    error = null;
    notifyListeners();
  }

  String _decodedName() {
    final source = sourceName ?? 'decoded-file';
    if (sourceKind == 'pdf') {
      // "Film.mp4.middleout.pdf" -> "Film.mp4".
      final stripped = source.replaceAll('.middleout.pdf', '');
      return stripped.endsWith('.pdf')
          ? stripped.substring(0, stripped.length - 4)
          : stripped;
    }
    return 'decoded-file';
  }
}
