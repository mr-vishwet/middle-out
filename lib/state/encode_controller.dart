
import 'dart:async' show unawaited;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../codec/code_grid.dart';
import '../codec/decoder.dart';
import '../codec/encoder.dart';
import '../codec/erasure.dart';
import '../codec/frame.dart';
import '../codec/pdf_document.dart';
import '../codec/streaming_encoder.dart';
import '../core/constants.dart';
import '../core/format.dart';
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
///
/// The PDF size is modelled from MEASURED real builds (see
/// [EncodeController.pdfSizeModel]), not from a per-frame guess: every
/// code page is a 1-bit image whose deflated bytes track the frame bytes
/// it carries, plus a fixed per-page PDF-object cost and a fixed
/// cover/document cost.
class EncodeEstimate {
  /// Creates an estimate.
  const EncodeEstimate({
    required this.ratio,
    required this.estimatedFrames,
    required this.dataFrames,
    required this.parityFrames,
    required this.estimatedPdfBytes,
    required this.estimatedSeconds,
    required this.sampleBytes,
    required this.memoryGuard,
    this.incompressible = false,
    this.overCap = false,
  });

  /// Estimated compression ratio from the sample.
  final double ratio;

  /// Estimated frame count (data + parity).
  final int estimatedFrames;

  /// Estimated DATA frames (code pages carrying file bytes).
  final int dataFrames;

  /// Estimated PARITY frames (XOR recovery pages).
  final int parityFrames;

  /// Estimated PDF size in bytes.
  final int estimatedPdfBytes;

  /// Estimated encode time in seconds (rough local throughput).
  final int estimatedSeconds;

  /// Bytes sampled for the estimate.
  final int sampleBytes;

  /// Memory guard verdict for this encode (peak estimate + level).
  final MemoryGuard memoryGuard;

  /// True when the measured ratio says the file barely compresses
  /// (ratio below [EncodeController.incompressibleRatioThreshold]):
  /// the PDF will be about the same size as the file, or bigger.
  final bool incompressible;

  /// True when the estimated frame count exceeds [kMaxFrames] — the
  /// estimate screen warns before the user encodes.
  final bool overCap;
}

/// How much memory an encode is expected to need.
enum MemoryGuardLevel {
  /// Expected peak is comfortably inside the platform budget.
  ok,

  /// Expected peak is high: the user must confirm before encoding.
  warn,

  /// Expected peak exceeds what the platform can safely hold:
  /// the encode is blocked until the file is split smaller.
  refuse,
}

/// The memory guard's verdict for one estimate.
class MemoryGuard {
  /// Creates a memory guard verdict.
  const MemoryGuard({
    required this.estimatedPeakBytes,
    required this.level,
    required this.reason,
  });

  /// Estimated peak memory in bytes (see
  /// [EncodeController.estimateMemoryPeak] for the model).
  final int estimatedPeakBytes;

  /// The guard level: proceed, confirm, or block.
  final MemoryGuardLevel level;

  /// Human-readable reason, shown on the estimate screen when the
  /// level is not [MemoryGuardLevel.ok].
  final String reason;
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

  // --- Honest PDF-size model (measured, not guessed) -------------------
  //
  // Measured from real builds (VM, light + dark samples + builds of a
  // 1 MiB highly-compressible demo, a 2 MiB random file and a 20 MiB
  // random file, QR and barcode, encrypted and plain; see the
  // measurement notes in the repo history for this change):
  //
  // * A code page is a 1-bit image XObject. Its deflated bytes track the
  //   frame bytes it carries: the packed 1-bit pixels are exactly
  //   `packedRaw` bytes (stride x height, from [CodeGrid.chooseGridSize]
  //   — computed, never guessed), and deflate recovers most of the
  //   reserved-cell overhead, leaving ~0.99x packed bytes for random
  //   frame bytes plus ~96 bytes of per-stream zlib overhead.
  // * When the payload is NOT encrypted, the frame bytes are the zlib-9
  //   stream itself, which deflate-6 can squeeze again: [secondPassFactor]
  //   (measured on the samples: deflate-6(zlib-9(sample)) / len) scales
  //   the deflate down. When encrypted, ChaCha20 output is uniformly
  //   random, so the factor is 1.0 no matter how compressible the input
  //   was — encryption is why the default path is accurate even for
  //   text files.
  // * Fixed costs: 478 bytes of document scaffolding (header, Catalog,
  //   Pages, two standard-14 fonts, xref/trailer base), 2,814 for the
  //   shared logo XObject, 1,098 for the cover page (objects + QR
  //   image), 790 per code page (Page + Contents + Image objects +
  //   xref entries).
  //
  // Verified against real builds (encrypted, the default): demo
  // 21,137 actual vs ~21,350 model (+1.0%); 2 MiB random (1 data page)
  // 4,216,281 vs ~4,358,000 (+3.4%); 20 MiB random (2 data pages)
  // 31,526,784 vs ~32,608,000 (+3.4%). The model is deliberately
  // conservative — it over-states by a few percent, never under-states
  // an incompressible file.
  //
  // KNOWN MISS (documented, not hidden): an UNENCRYPTED highly
  // compressible file over-states by ~45% (demo: model ~13,400 vs
  // 9,089 actual). The 256 KiB samples cannot see long-range
  // repetition: the second-pass output of README x461 is ~1.3 KB
  // whether it describes 256 KiB or the whole 1 MiB, so the sample
  // factor (0.47) is far above the whole-file factor (0.18). The error
  // is in the safe direction (over, never under) and vanishes the
  // moment encryption is on, which is the default.
  /// Fixed document scaffolding (header, Catalog, Pages, two
  /// standard-14 fonts, xref/trailer base), in bytes.
  static const int kPdfFixedBytes = 478;

  /// Shared logo XObject (deflated logo + dict/wrapper/xref), bytes.
  static const int kPdfLogoBytes = 2814;

  /// Cover page (page objects + QR image + xref), in bytes.
  static const int kPdfCoverBytes = 1098;

  /// Per code page (Page + Contents + Image objects + xref), bytes.
  static const int kPdfPerFrameBytes = 790;

  /// Fraction of the packed 1-bit image that survives deflate-6 for
  /// random frame bytes (measured 0.955–0.987; 0.99 is the
  /// conservative end).
  static const double kDeflateRecovery = 0.99;

  /// Fixed per-frame zlib stream overhead, in bytes (measured: tiny
  /// frames deflate to ~96 bytes over the recovered packed size).
  static const int kDeflatePerFrameSlopBytes = 96;

  /// Frame wire overhead: 100-byte header + 4-byte payload CRC.
  static const int kFrameWireBytes = kHeaderSize + 4;

  /// Ratio below which a file counts as incompressible: zlib saved
  /// less than ~9%, so the PDF cannot come out meaningfully smaller
  /// than the file.
  static const double incompressibleRatioThreshold = 1.1;

  // --- Memory guard (new renderer model) -------------------------------
  //
  // The renderer streams grid rows into packed 1-bit bytes, so a code
  // page costs O(image bytes), not O(cells). Per-page peak is the
  // largest page's packed image times [kImageBuildFactor]. MEASURED
  // on the new renderer (VM, 10.5 MB page): packed 11.0 MB, deflate
  // 10.5 MB, peak-RSS delta +58.4 MB = 5.45x packed — the live packed
  // + deflate buffers (~21.5 MB) plus per-call garbage (BytesBuilder
  // growth, the DeviceGray inversion copy, zlib working set, GC
  // retention). 6.0 is the rounded-up guard value.
  //
  // On top of the transient page, the build holds: the input file and
  // the compressed stream (in-memory path only — streaming reads off
  // disk), the parity frames (fresh allocations; data frames are views
  // into the stream), and the PDF output-so-far. The writer is eager
  // (each page is serialised as it is built and its image buffers are
  // dropped), but the output bytes themselves still accumulate — the
  // PDF is returned as bytes, so one full copy is unavoidable. Only a
  // future file sink would drop that last copy ([streamingBinding]).
  //
  // Thresholds: desktop native warns above 1 GiB and refuses above
  // 2 GiB (a desktop app targets machines with >= 8 GB; 2 GiB
  // approaches practical Dart-heap limits). Web and mobile warn above
  // 512 MiB and refuse above 1 GiB (browser tabs and mobile apps are
  // killed far earlier — iOS jetsam, Android low-memory killer — and
  // web never streams: the whole file is held in memory).
  /// Transient per-page build factor over the largest page's packed
  /// image bytes — measured 5.45x peak RSS on a 10.5 MB page, rounded
  /// up to 6.0 (see the memory guard comment above).
  static const double kImageBuildFactor = 6.0;

  /// Memory-guard warn threshold on desktop native, in bytes.
  static const int kMemoryWarnDesktopBytes = 1024 * 1024 * 1024;

  /// Memory-guard refuse threshold on desktop native, in bytes.
  static const int kMemoryRefuseDesktopBytes = 2 * 1024 * 1024 * 1024;

  /// Memory-guard warn threshold on web and mobile, in bytes.
  static const int kMemoryWarnSmallBytes = 512 * 1024 * 1024;

  /// Memory-guard refuse threshold on web and mobile, in bytes.
  static const int kMemoryRefuseSmallBytes = 1024 * 1024 * 1024;

  /// Builds an estimate from a measured compression [ratio] and file
  /// size. Pure (no I/O) so the frame-count and cap math is unit-testable.
  ///
  /// In-memory encodes use the adaptive page rule
  /// ([Encoder.dataPageCount]): the compressed stream is equal-split
  /// across that many data pages, so the frame count follows the rule,
  /// not a fixed target. [streaming] encodes use fixed
  /// [kDefaultMaxPayload] chunks instead and CAN exceed the cap.
  /// Parity counts one per non-empty trio in both paths.
  ///
  /// [barcode] selects the bar-grid aspect for the packed-image size;
  /// [encrypted] selects the deflate factor (encrypted payloads are
  /// random, so they never re-compress); [secondPassFactor] is the
  /// measured deflate-6(zlib-9(sample)) ratio for plain payloads.
  /// [web]/[mobile] select the memory-guard thresholds;
  /// [streamingBinding] says the PDF output goes to a file sink
  /// instead of accumulating in memory (false: the writer is eager
  /// but still returns the whole PDF as bytes, so one full copy is
  /// held; the sink does not exist yet).
  static EncodeEstimate estimateFor({
    required int fileSize,
    required double ratio,
    required int sampleBytes,
    bool streaming = false,
    bool barcode = false,
    bool encrypted = true,
    double secondPassFactor = 1.0,
    bool web = false,
    bool mobile = false,
    bool streamingBinding = false,
  }) {
    final clampedRatio = ratio.clamp(1.0, 1000.0);
    final estCompressed = (fileSize / clampedRatio).ceil();
    final int dataFrames;
    final int chunkSize;
    if (streaming) {
      dataFrames = (estCompressed + kDefaultMaxPayload - 1) ~/
          kDefaultMaxPayload;
      chunkSize = kDefaultMaxPayload;
    } else {
      dataFrames = Encoder.dataPageCount(estCompressed);
      chunkSize = (estCompressed + dataFrames - 1) ~/ dataFrames;
    }
    final dataFramesClamped = dataFrames < 1 ? 1 : dataFrames;
    final parityFrames = Erasure.parityFrameCount(dataFramesClamped);
    final frames = dataFramesClamped + parityFrames;
    final estimatedPdfBytes = _estimatePdfBytes(
      dataFrames: dataFramesClamped,
      parityFrames: parityFrames,
      chunkSize: chunkSize,
      barcode: barcode,
      encrypted: encrypted,
      secondPassFactor: secondPassFactor,
    );
    final memoryGuard = estimateMemoryPeak(
      fileSize: fileSize,
      estCompressed: estCompressed,
      dataFrames: dataFramesClamped,
      parityFrames: parityFrames,
      chunkSize: chunkSize,
      estimatedPdfBytes: estimatedPdfBytes,
      streaming: streaming,
      barcode: barcode,
      web: web,
      mobile: mobile,
      streamingBinding: streamingBinding,
    );
    return EncodeEstimate(
      ratio: clampedRatio,
      estimatedFrames: frames,
      dataFrames: dataFramesClamped,
      parityFrames: parityFrames,
      estimatedPdfBytes: estimatedPdfBytes,
      estimatedSeconds:
          (fileSize / (25 * 1024 * 1024)).ceil().clamp(1, 3600 * 24),
      sampleBytes: sampleBytes,
      memoryGuard: memoryGuard,
      incompressible: clampedRatio < incompressibleRatioThreshold,
      overCap: frames > kMaxFrames,
    );
  }

  /// The PDF-size model, factored out so tests can check it directly:
  /// fixed document + logo + cover costs, per-frame page objects, and
  /// per-frame deflated 1-bit images sized from the real grid geometry.
  static int _estimatePdfBytes({
    required int dataFrames,
    required int parityFrames,
    required int chunkSize,
    required bool barcode,
    required bool encrypted,
    required double secondPassFactor,
  }) {
    final frames = dataFrames + parityFrames;
    final frameBytes = chunkSize + kFrameWireBytes;
    // Packed 1-bit image bytes for one frame: exact grid geometry.
    // A chunk too large for one grid (over CodeGrid.maxHeight) cannot
    // be rendered at all — fall back to the large-grid packing ratio
    // (~1.05x: the centre tile dominates) so the estimate stays finite;
    // the memory guard refuses such an encode outright.
    int packedRaw;
    try {
      final (w, h) = CodeGrid.chooseGridSize(
        frameBytes,
        aspect: barcode ? CodeGrid.barcodeAspect : CodeGrid.qrAspect,
      );
      packedRaw = ((w + 7) ~/ 8) * h;
    } on CodecException {
      packedRaw = (frameBytes * 105) ~/ 100;
    }
    // Encrypted payloads are random: no second-pass squeeze. Plain
    // payloads re-compress by the measured sample factor (clamped —
    // a factor above ~1.05 would mean the sample misled us).
    final secondPass =
        encrypted ? 1.0 : secondPassFactor.clamp(0.0, 1.05);
    final deflatePerFrame =
        (packedRaw * kDeflateRecovery * secondPass).ceil() +
            kDeflatePerFrameSlopBytes;
    return kPdfFixedBytes +
        kPdfLogoBytes +
        kPdfCoverBytes +
        frames * (kPdfPerFrameBytes + deflatePerFrame);
  }

  /// Estimates the peak memory of an encode and returns the guard
  /// verdict. Pure, so the thresholds are unit-testable.
  ///
  /// Peak = held input (file + compressed stream on the in-memory
  /// path; nothing on the streaming path) + parity frames (fresh
  /// allocations; data frames are views into the stream) + the
  /// transient largest page image x [kImageBuildFactor] + held PDF
  /// output (the whole PDF — the eager writer still accumulates the
  /// returned bytes; only a file sink, [streamingBinding], drops this
  /// to one page). A chunk that cannot fit one code grid refuses
  /// outright — no estimate of the peak can save it.
  static MemoryGuard estimateMemoryPeak({
    required int fileSize,
    required int estCompressed,
    required int dataFrames,
    required int parityFrames,
    required int chunkSize,
    required int estimatedPdfBytes,
    required bool streaming,
    required bool barcode,
    required bool web,
    required bool mobile,
    required bool streamingBinding,
  }) {
    final frameBytes = chunkSize + kFrameWireBytes;
    int largestPageImageBytes;
    try {
      final (w, h) = CodeGrid.chooseGridSize(
        frameBytes,
        aspect: barcode ? CodeGrid.barcodeAspect : CodeGrid.qrAspect,
      );
      largestPageImageBytes = ((w + 7) ~/ 8) * h;
    } on CodecException {
      return MemoryGuard(
        estimatedPeakBytes: -1,
        level: MemoryGuardLevel.refuse,
        reason: 'A single code page cannot hold $chunkSize bytes — '
            'split the file into smaller files and encode each one '
            'separately.',
      );
    }
    final transientPage =
        (largestPageImageBytes * kImageBuildFactor).ceil();
    final heldParity = parityFrames * chunkSize;
    final heldInput = streaming ? 0 : fileSize + estCompressed;
    final heldImages =
        streamingBinding ? largestPageImageBytes : estimatedPdfBytes;
    final peak = heldInput + heldParity + transientPage + heldImages;
    final smallPlatform = web || mobile;
    final warnAt =
        smallPlatform ? kMemoryWarnSmallBytes : kMemoryWarnDesktopBytes;
    final refuseAt = smallPlatform
        ? kMemoryRefuseSmallBytes
        : kMemoryRefuseDesktopBytes;
    if (peak > refuseAt) {
      return MemoryGuard(
        estimatedPeakBytes: peak,
        level: MemoryGuardLevel.refuse,
        reason: 'This encode would need about ${formatBytes(peak)} of '
            'memory — more than this device can safely hold. Split the '
            'file into smaller files and encode each one separately.',
      );
    }
    if (peak > warnAt) {
      return MemoryGuard(
        estimatedPeakBytes: peak,
        level: MemoryGuardLevel.warn,
        reason: 'This encode may peak at about ${formatBytes(peak)} of '
            'memory. Tap Encode again to proceed, or split the file '
            'first if this device is low on memory.',
      );
    }
    return MemoryGuard(
      estimatedPeakBytes: peak,
      level: MemoryGuardLevel.ok,
      reason: '',
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

  /// QR-style grid (false) or bar-grid barcode (true). Default: grid.
  bool barcode = false;

  /// Dark PDF theme (white code on black pages). Default: light.
  bool pdfDark = false;

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

  /// True once the user has acknowledged a memory-guard warning for
  /// the current estimate (two-tap encode: the first tap on Encode
  /// acknowledges, the second starts the encode). Reset whenever the
  /// estimate is recomputed, so a new file or toggle change asks again.
  bool memoryWarningAcknowledged = false;

  /// Records the user's acknowledgement of the memory warning for the
  /// current estimate, so the next Encode tap starts the encode.
  void acknowledgeMemoryWarning() {
    memoryWarningAcknowledged = true;
    notifyListeners();
  }

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

  /// Generation of the in-flight encode. [reset] bumps it, so an encode
  /// abandoned mid-flight (Cancel pops the screen and resets) cannot
  /// finish late and flip the reset controller back to done, or record
  /// history for an encode the user cancelled. [encode] captures its
  /// generation at start and checks it between stages and inside the
  /// PDF build (via its shouldCancel callback).
  int _generation = 0;

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

  /// Sets the code format. The estimate depends on it (bar-grid
  /// geometry), so it is recomputed.
  void setBarcode(bool value) {
    barcode = value;
    _clearStaleError();
    notifyListeners();
    if (file != null) unawaitedRefreshEstimate();
  }

  /// Sets the PDF theme (false = light, true = dark).
  void setPdfDark(bool value) {
    pdfDark = value;
    _clearStaleError();
    notifyListeners();
  }

  /// Sets the encryption toggle. The estimate depends on it (an
  /// encrypted payload is random bytes, so it never re-compresses in
  /// the PDF images), so it is recomputed.
  void setEncrypted(bool value) {
    encrypted = value;
    _clearStaleError();
    notifyListeners();
    if (file != null) unawaitedRefreshEstimate();
  }

  /// Sets the passphrase.
  void setPassphrase(String value) {
    passphrase = value;
    _clearStaleError();
    notifyListeners();
  }

  /// Clears a stale error when the user changes an option on the
  /// pre-encode screen, so the flow is retryable: without this the phase
  /// stays [EncodePhase.error] after a failed encode, the progress screen
  /// never starts a new encode (it only starts from [EncodePhase.ready]),
  /// and every retry shows the first failure's message — including the
  /// red error text lingering on the pre-encode screen itself.
  void _clearStaleError() {
    if (phase != EncodePhase.error) return;
    error = null;
    phase = file != null ? EncodePhase.ready : EncodePhase.idle;
    progress = 0;
    progressLabel = '';
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

  /// Fire-and-forget estimate refresh after a toggle change (the
  /// barcode and encryption toggles change the PDF size and the memory
  /// guard, so the estimate must follow them). [refreshEstimate]
  /// notifies when it lands.
  void unawaitedRefreshEstimate() {
    unawaited(refreshEstimate());
  }

  /// (Re)computes the pre-encode estimate from head, middle and tail
  /// samples, using the worst (lowest) ratio across them. A head-only
  /// sample undershoots badly on media files: an .mp4's metadata head
  /// compresses far better than its video data. Conservative beats
  /// optimistic — an over-estimate only warns early, an under-estimate
  /// fails the encode halfway through.
  ///
  /// Each sample is also deflated a second time (deflate-6 of its
  /// zlib-9 bytes): that is the [EncodeController.estimateFor]
  /// second-pass factor, the most the PDF images can squeeze a plain
  /// (unencrypted) payload again. The worst (largest) factor across
  /// samples is used, so the PDF size is never under-stated by it.
  Future<void> refreshEstimate() async {
    final current = file;
    if (current == null) {
      estimate = null;
      return;
    }
    memoryWarningAcknowledged = false;
    try {
      final samples = await _picker.readRefSamples(
        current,
        estimateSampleChunkBytes,
      );
      var ratio = double.infinity;
      var secondPassFactor = 0.0;
      var sampled = 0;
      for (final sample in samples) {
        if (sample.isEmpty) continue;
        final compressed = const ZLibEncoder().encode(sample, level: 9);
        final sampleRatio = compressed.isEmpty
            ? 1.0
            : sample.length / compressed.length;
        if (sampleRatio < ratio) ratio = sampleRatio;
        // Second pass: how much does the compressed sample squeeze
        // again at the level the PDF builder uses (6)?
        final recompressed = const ZLibEncoder().encode(
          compressed,
          level: 6,
        );
        final factor = compressed.isEmpty
            ? 1.0
            : recompressed.length / compressed.length;
        if (factor > secondPassFactor) secondPassFactor = factor;
        sampled += sample.length;
      }
      if (ratio.isInfinite) ratio = 1.0;
      if (secondPassFactor == 0.0) secondPassFactor = 1.0;
      // Streaming encodes (large native files) frame in fixed 64 KiB
      // chunks, so their frame count follows the streaming rule; the
      // in-memory path equal-splits. Same routing as [encode].
      final willStream = !kIsWeb &&
          current.hasPath &&
          current.size >= streamingThresholdBytes;
      estimate = estimateFor(
        fileSize: current.size,
        ratio: ratio,
        sampleBytes: sampled,
        streaming: willStream,
        barcode: barcode,
        encrypted: encrypted,
        secondPassFactor: secondPassFactor,
        web: kIsWeb,
        mobile: defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android,
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
    final generation = ++_generation;
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
      // Cancelled (or reset) while the encode stages were running.
      if (generation != _generation) return;
      progress = 0.85;
      progressLabel = 'Creating images…';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);

      final (bytes, stats) = await PdfDocument.build(
        encoded,
        current.name,
        dark: pdfDark,
        onProgress: (fraction, label) {
          progress = 0.85 + fraction * 0.15;
          progressLabel = label;
          notifyListeners();
        },
        shouldCancel: () => generation != _generation,
      );
      if (generation != _generation) return;
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
    } on BuildCancelledException {
      // Cancelled mid-build: the controller was already reset by the
      // caller (Cancel / reset) — leave it alone, record nothing.
      return;
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

  /// Resets the flow to idle (keeps the toggles and mode). Also
  /// invalidates any in-flight encode, so a cancelled encode stops
  /// at its next checkpoint instead of completing late.
  void reset() {
    _generation++;
    phase = EncodePhase.idle;
    file = null;
    progress = 0;
    progressLabel = '';
    estimate = null;
    memoryWarningAcknowledged = false;
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
