import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../codec/decoder.dart';
import '../codec/encoder.dart';
import '../codec/frame.dart';
import '../codec/pdf_document.dart';
import '../services/file_picker_service.dart';
import '../services/pdf_saver.dart' show savePdf;
import '../services/platform_limits.dart';

/// Where the encode flow is.
enum EncodePhase {
  idle,
  picking,
  ready,
  encoding,
  done,
  error,
}

/// State for the encode flow: picked file, toggles, progress, result.
///
/// Owns the whole pipeline: pick (limit-gated) -> encode -> PDF. The heavy
/// work currently runs on the UI thread in stages with progress updates;
/// moving it to an isolate (compute) is the v0.2 item for large files.
class EncodeController extends ChangeNotifier {
  EncodeController({FilePickerService? picker})
      : _picker = picker ?? FilePickerService(),
        mode = PlatformLimitsService.defaultMode();

  final FilePickerService _picker;

  EncodePhase phase = EncodePhase.idle;
  EncodeMode mode;
  PickedFile? file;

  /// QR-style grid (false) or stacked-row barcode (true). Default: grid.
  bool barcode = false;

  /// Encrypted (default ON): payload is not human-readable when scanned.
  bool encrypted = true;
  String passphrase = '';

  double progress = 0;
  String progressLabel = '';

  EncodeResult? result;
  Uint8List? pdfBytes;
  PdfStats? pdfStats;
  String? savedPath;
  String? error;

  /// Warning when the PDF lands outside the 5–20 MB-per-GB band.
  String? get pdfBandWarning => result == null || pdfStats == null
      ? null
      : PlatformLimitsService.pdfBandWarning(
          result!.stats.originalSize,
          pdfStats!.sizeBytes,
        );

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

  void setBarcode(bool value) {
    barcode = value;
    notifyListeners();
  }

  void setEncrypted(bool value) {
    encrypted = value;
    notifyListeners();
  }

  void setPassphrase(String value) {
    passphrase = value;
    notifyListeners();
  }

  Future<void> pickFile() async {
    phase = EncodePhase.picking;
    error = null;
    notifyListeners();
    try {
      final picked = await _picker.pickFile(mode);
      if (picked == null) {
        phase = file == null ? EncodePhase.idle : EncodePhase.ready;
      } else {
        file = picked;
        result = null;
        pdfBytes = null;
        pdfStats = null;
        savedPath = null;
        phase = EncodePhase.ready;
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

  Future<void> encode() async {
    final current = file;
    if (current == null) return;
    if (encrypted && passphrase.isEmpty) {
      error = 'Encryption is on — set a passphrase, or turn it off.';
      phase = EncodePhase.error;
      notifyListeners();
      return;
    }
    phase = EncodePhase.encoding;
    error = null;
    progress = 0;
    progressLabel = 'Reading file…';
    notifyListeners();
    try {
      // Yield to the UI between stages so progress actually paints.
      await Future<void>.delayed(Duration.zero);
      progress = 0.15;
      progressLabel = 'Compressing…';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);

      final encoded = Encoder.encode(
        current.bytes,
        passphrase: encrypted ? passphrase : null,
        barcode: barcode,
      );
      progress = 0.6;
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
    } on CodecException catch (e) {
      error = e.message;
      phase = EncodePhase.error;
    } catch (e) {
      error = 'Encode failed: $e';
      phase = EncodePhase.error;
    }
    notifyListeners();
  }

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

  void reset() {
    phase = EncodePhase.idle;
    file = null;
    progress = 0;
    progressLabel = '';
    result = null;
    pdfBytes = null;
    pdfStats = null;
    savedPath = null;
    error = null;
    notifyListeners();
  }
}

/// State for the decode flow.
///
/// v0.1 decodes from frame files (`.bin` frames exported alongside a PDF,
/// or frames shared from another device). Decoding straight from a
/// scanned/printed PDF — camera capture, perspective correction, module
/// sampling — is the v0.2 milestone; the frame-level decoder it feeds on
/// is already complete and tested.
class DecodeController extends ChangeNotifier {
  DecodePhase phase = DecodePhase.idle;
  String passphrase = '';
  Uint8List? decoded;
  String? decodedName;
  String? error;

  void setPassphrase(String value) {
    passphrase = value;
    notifyListeners();
  }

  /// Decodes already-parsed frame blobs (one blob per frame, in any order).
  Future<void> decodeFrames(List<Uint8List> blobs, {String? name}) async {
    phase = DecodePhase.decoding;
    error = null;
    notifyListeners();
    try {
      await Future<void>.delayed(Duration.zero);
      decoded = Decoder.decode(
        blobs,
        passphrase: passphrase.isEmpty ? null : passphrase,
      );
      decodedName = name ?? 'decoded-file';
      phase = DecodePhase.done;
    } on CodecException catch (e) {
      error = e.message;
      phase = DecodePhase.error;
    } catch (e) {
      error = 'Decode failed: $e';
      phase = DecodePhase.error;
    }
    notifyListeners();
  }

  void reset() {
    phase = DecodePhase.idle;
    decoded = null;
    decodedName = null;
    error = null;
    notifyListeners();
  }
}

/// Where the decode flow is.
enum DecodePhase {
  idle,
  decoding,
  done,
  error,
}
