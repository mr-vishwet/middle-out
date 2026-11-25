library;

import '../core/constants.dart';
import 'code_grid.dart';
import 'encoder.dart';
import 'erasure.dart';
import 'frame.dart';
import 'reencode.dart';

/// The 10:1 ratio engine: decides, for one picked file, whether the
/// finished PDF can reach a tenth of the original size losslessly,
/// needs a lossy re-encode of the media, or cannot reach 10:1 at all.
///
/// Pure (no I/O, no platform calls): every function here is a function
/// of its arguments, so the whole decision is unit-testable on the VM.
///
/// The budget math is computed from the REAL overhead model — the same
/// model [EncodeController.estimateFor] uses — not from a flat factor:
///
/// * the finished PDF is the fixed document cost (header, Catalog,
///   Pages, fonts, logo XObject, cover page) plus, per frame, the
///   per-page PDF objects plus the deflated 1-bit image of that frame
///   ([modelledPdfBytes] replicates
///   `EncodeController._estimatePdfBytes` exactly, including the exact
///   grid geometry from [CodeGrid.chooseGridSize]);
/// * the data-page count comes from the adaptive rule
///   ([Encoder.dataPageCount] — sub-linear in the compressed size, so
///   the page count is an output, never an input);
/// * the parity count comes from [Erasure.parityFrameCount] (one per
///   non-empty trio).
///
/// The parity factor is therefore NOT flat, and the flat `input / 13.3`
/// from the original brief is WRONG as a budget — it only counts the
/// parity frames (2 per 6 data = 1.333x) and ignores that every frame
/// is rendered as a ~1.05x 1-bit image:
///
/// * 1 data page: 1 data + 1 parity = 2 frames carrying the whole
///   stream each, so the PDF is ~2.08x the media size. A 3.1 MB clip
///   budgets to ~150 KB of media, not ~233 KB.
/// * 2 data pages: 2 data + 1 parity = 3 frames carrying half the
///   stream each, so the PDF is ~1.56x the media size.
/// * full 6-data groups: 6 data + 2 parity = 8 frames carrying a
///   sixth each, so the PDF is ~1.39x the media size.
/// * the fixed ~4,390 bytes of document/logo/cover matter for small
///   files: below ~64 KB no file can reach 10:1 at all, because the
///   fixed cost alone exceeds a tenth of the file.
///
/// [reencodeTargetMediaBytes] therefore solves for the largest media
/// size M whose MODELED PDF lands at or below the target with a 2%
/// safety margin, by scaling down from `S / 13.3` until the model
/// agrees. The 2% margin covers the one thing the model cannot see:
/// the re-encoded media is zlib-9 compressed again inside the encoder,
/// which ADDS a few bytes to already-compressed media (stored blocks),
/// and the estimate model itself over-states by ~3% for incompressible
/// files — so a modeled PDF inside the margin is a real PDF inside
/// the target. The exact numbers are pinned in `ratio_engine_test.dart`.

/// Which path a file takes to (or away from) the 10:1 target.
enum RatioDecision {
  /// The projected lossless PDF is already at or below a tenth of
  /// the original: encode losslessly, offer no re-encode.
  lossless,

  /// The file is re-encodable media (video / still image) and a
  /// re-encode to [RatioPlan.reencodeTargetMediaBytes] fits the
  /// target: propose it and encode only on the user's confirmation.
  reencode,

  /// The file cannot reach 10:1: not re-encodable media, lossless-only
  /// mode is on, or even the lowest-quality re-encode cannot fit.
  deadEnd,
}

/// The ratio engine's verdict for one file, with the numbers the
/// pre-encode screen shows.
class RatioPlan {
  /// Creates a ratio verdict.
  const RatioPlan({
    required this.decision,
    required this.fileSize,
    required this.losslessPdfBytes,
    this.reencodeTargetMediaBytes,
    this.reencodeTargetPdfBytes,
    this.deadEndReason,
  });

  /// The decision.
  final RatioDecision decision;

  /// Bytes of the original file.
  final int fileSize;

  /// Modeled PDF size for the LOSSLESS encode, in bytes (from the
  /// sampled ratio via the estimate model).
  final int losslessPdfBytes;

  /// Largest re-encoded media size that fits the 10:1 target, in
  /// bytes — null unless [decision] is [RatioDecision.reencode].
  final int? reencodeTargetMediaBytes;

  /// Modeled PDF size for that re-encode, in bytes — null unless
  /// [decision] is [RatioDecision.reencode]. Always at or below
  /// [targetPdfBytes].
  final int? reencodeTargetPdfBytes;

  /// Plain-language reason the file cannot reach 10:1 — null unless
  /// [decision] is [RatioDecision.deadEnd]. Shown verbatim on the
  /// pre-encode screen.
  final String? deadEndReason;

  /// The 10:1 target: the finished PDF must land at or below this.
  int get targetPdfBytes => fileSize ~/ 10;

  /// True when the file reaches 10:1 losslessly.
  bool get isLossless => decision == RatioDecision.lossless;

  /// True when a re-encode is proposed.
  bool get needsReencode => decision == RatioDecision.reencode;

  /// True when the file cannot reach 10:1.
  bool get isDeadEnd => decision == RatioDecision.deadEnd;
}

/// The ratio engine: pure functions over the real overhead model.
class RatioEngine {
  /// Fixed document + logo + cover cost, in bytes. MUST match
  /// `EncodeController.kPdfFixedBytes + kPdfLogoBytes + kPdfCoverBytes`
  /// (478 + 2814 + 1098 = 4390); `ratio_engine_test.dart` cross-checks
  /// [modelledPdfBytes] against `EncodeController.estimateFor` across
  /// a spread of sizes so the two can never drift silently.
  static const int kRatioFixedBytes = 478 + 2814 + 1098;

  /// Per code page (Page + Contents + Image objects + xref), in bytes.
  /// MUST match `EncodeController.kPdfPerFrameBytes` (790).
  static const int kRatioPerFrameBytes = 790;

  /// Fraction of the packed 1-bit image that survives deflate-6 for
  /// random frame bytes. MUST match
  /// `EncodeController.kDeflateRecovery` (0.99).
  static const double kRatioDeflateRecovery = 0.99;

  /// Fixed per-frame zlib stream overhead, in bytes. MUST match
  /// `EncodeController.kDeflatePerFrameSlopBytes` (96).
  static const int kRatioDeflateSlopBytes = 96;

  /// Frame wire overhead: 100-byte header + 4-byte payload CRC. MUST
  /// match `EncodeController.kFrameWireBytes`.
  static const int kRatioFrameWireBytes = kHeaderSize + 4;

  /// Safety margin on the 10:1 target for the re-encode budget: the
  /// modeled PDF must land at or below 98% of the target, so the real
  /// PDF — whose zlib pass over already-compressed media adds a few
  /// bytes the model cannot see — still lands inside 10:1.
  static const double kBudgetMargin = 0.98;

  /// Smallest re-encoded media worth producing, in bytes. Below this
  /// the output is mush even at the quality floor, and the budget
  /// solver treats the file as a dead end instead of returning a
  /// token-sized target.
  ///
  /// The quality floor itself lives in [ReencodeQualityFloor]
  /// (`lib/codec/reencode.dart`, currently video 426x240 @ 75 kbps):
  /// it bounds how low the encoder can go for a given duration, while
  /// this budget is duration-agnostic — so the engine never pre-judges
  /// floor feasibility. If the encoder's floor output still exceeds
  /// the budget, it fails honestly ([ReencodeException]) instead of
  /// shipping a PDF over 10:1.
  static const int kMinReencodeMediaBytes = 4096;

  /// The modeled PDF size for an encode whose compressed (+encrypted)
  /// stream is [compressedSize] bytes, at the current [barcode] /
  /// [encrypted] toggles. Replicates
  /// `EncodeController._estimatePdfBytes` exactly (same page rule,
  /// same parity rule, same grid geometry, same fixed costs) so the
  /// ratio decision and the estimate screen can never disagree.
  ///
  /// [streaming] prices the streaming path instead: fixed
  /// [kDefaultMaxPayload] chunks, which is how a large native file
  /// frames. The re-encode budget NEVER uses streaming — re-encoded
  /// media is small and always takes the in-memory path (a streaming
  /// file cannot be re-encoded at all).
  ///
  /// [secondPassFactor] is the measured deflate-6(zlib-9(sample))
  /// ratio for plain payloads (1.0 when encrypted — ChaCha20 output
  /// is uniformly random, so it never re-compresses).
  static int modelledPdfBytes({
    required int compressedSize,
    bool barcode = false,
    bool encrypted = true,
    double secondPassFactor = 1.0,
    bool streaming = false,
  }) {
    final int dataFrames;
    final int chunkSize;
    if (streaming) {
      dataFrames = (compressedSize + kDefaultMaxPayload - 1) ~/
          kDefaultMaxPayload;
      chunkSize = kDefaultMaxPayload;
    } else {
      dataFrames = Encoder.dataPageCount(compressedSize);
      chunkSize =
          (compressedSize + dataFrames - 1) ~/ dataFrames;
    }
    final dataFramesClamped = dataFrames < 1 ? 1 : dataFrames;
    final parityFrames = Erasure.parityFrameCount(dataFramesClamped);
    final frames = dataFramesClamped + parityFrames;
    final frameBytes = chunkSize + kRatioFrameWireBytes;
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
    final secondPass =
        encrypted ? 1.0 : secondPassFactor.clamp(0.0, 1.05);
    final deflatePerFrame =
        (packedRaw * kRatioDeflateRecovery * secondPass).ceil() +
            kRatioDeflateSlopBytes;
    return kRatioFixedBytes +
        frames * (kRatioPerFrameBytes + deflatePerFrame);
  }

  /// The largest re-encoded media size, in bytes, whose modeled PDF
  /// lands at or below [kBudgetMargin] of `fileSize / 10` — or null
  /// when no media size can fit (the fixed document cost alone
  /// exceeds the target, or the solver would have to go below
  /// [kMinReencodeMediaBytes]).
  ///
  /// Iterates from `fileSize / 13.3` (the old flat guess — a starting
  /// point only, never the answer): each step computes the modeled PDF
  /// for the current size and scales down proportionally to the
  /// shortfall. The PDF is NOT linear in the media size — it drops
  /// at page-count boundaries (more pages split the stream into
  /// smaller chunks, so the per-frame images shrink faster than the
  /// frame count grows) — so the loop re-checks the model every step
  /// and only returns a size the model itself approves.
  static int? reencodeTargetMediaBytes({
    required int fileSize,
    bool barcode = false,
    bool encrypted = true,
    double secondPassFactor = 1.0,
  }) {
    if (fileSize <= 0) return null;
    final target = fileSize ~/ 10;
    // Even an (almost) empty re-encode carries the fixed document
    // cost plus two code pages: if THAT exceeds the target, no media
    // size can ever fit.
    if (modelledPdfBytes(
          compressedSize: 1,
          barcode: barcode,
          encrypted: encrypted,
          secondPassFactor: secondPassFactor,
        ) >
        target) {
      return null;
    }
    final marginTarget = (target * kBudgetMargin).floor();
    var media = (fileSize / 13.3).floor();
    if (media < kMinReencodeMediaBytes) return null;
    for (var i = 0; i < 24; i++) {
      final pdf = modelledPdfBytes(
        compressedSize: media,
        barcode: barcode,
        encrypted: encrypted,
        secondPassFactor: secondPassFactor,
      );
      if (pdf <= marginTarget) return media;
      // Scale down proportionally to the shortfall; the model is
      // re-checked next iteration, so boundary drops are honoured.
      // The modeled PDF is a STEP function of the media size (the grid
      // height moves in steps of 2 modules, so the PDF holds its value
      // across a plateau of media sizes): a purely proportional step
      // can shrink by 31 bytes an iteration forever without ever
      // leaving the plateau (seen live: 2,055,272 vs a 2,055,208
      // margin, 31-byte steps, 24 iterations, no convergence). Force
      // at least a 1% step so every iteration crosses plateaus.
      final proportional = (media * marginTarget / pdf).floor();
      final minStep = (media ~/ 100).clamp(1, media);
      var next = proportional;
      if (media - next < minStep) next = media - minStep;
      if (next >= media) return null;
      if (next < kMinReencodeMediaBytes) return null;
      media = next;
    }
    return null;
  }

  /// The full verdict for one file.
  ///
  /// [sampledRatio] is the measured zlib ratio from the estimate
  /// samples (1.0 = incompressible). [kind] is the detected media
  /// kind. [losslessOnly] is the user's setting: when on, no
  /// re-encode is ever proposed. [streaming] prices the lossless PDF
  /// on the streaming path (fixed 64 KiB chunks); the re-encode
  /// budget itself always uses the in-memory model, because
  /// re-encoded media is small and a streaming file cannot be
  /// re-encoded at all.
  ///
  /// Rules, in order:
  /// 1. Lossless if the projected lossless PDF is already at or below
  ///    a tenth of the original — including re-encodable media that
  ///    happens to compress well, and plain text that beats 10:1
  ///    losslessly (no re-encode is ever offered for those).
  /// 2. Re-encode if the kind is video or still image, lossless-only
  ///    is off, and a media size exists that fits the target.
  /// 3. Dead end otherwise: other/audio kinds (never re-encoded),
  ///    lossless-only mode, or a file so small the fixed PDF cost
  ///    alone breaks 10:1. Never fake a re-encode for a file no codec
  ///    can shrink.
  static RatioPlan analyse({
    required int fileSize,
    required double sampledRatio,
    required MediaKind kind,
    required bool losslessOnly,
    bool barcode = false,
    bool encrypted = true,
    double secondPassFactor = 1.0,
    bool streaming = false,
  }) {
    final clampedRatio = sampledRatio.clamp(1.0, 1000.0);
    final estCompressed = (fileSize / clampedRatio).ceil();
    final losslessPdf = modelledPdfBytes(
      compressedSize: estCompressed,
      barcode: barcode,
      encrypted: encrypted,
      secondPassFactor: secondPassFactor,
      streaming: streaming,
    );
    final target = fileSize ~/ 10;
    if (losslessPdf <= target) {
      return RatioPlan(
        decision: RatioDecision.lossless,
        fileSize: fileSize,
        losslessPdfBytes: losslessPdf,
      );
    }
    final reencodable =
        kind == MediaKind.video || kind == MediaKind.image;
    if (!reencodable) {
      return RatioPlan(
        decision: RatioDecision.deadEnd,
        fileSize: fileSize,
        losslessPdfBytes: losslessPdf,
        deadEndReason: kind == MediaKind.audio
            ? 'Audio is not re-encoded — only video and still images '
                'can shrink to fit 10:1.'
            : 'Only video and still images can be re-encoded to fit '
                '10:1 — this file cannot shrink further losslessly.',
      );
    }
    if (losslessOnly) {
      return RatioPlan(
        decision: RatioDecision.deadEnd,
        fileSize: fileSize,
        losslessPdfBytes: losslessPdf,
        deadEndReason: 'Lossless-only is on, so this file cannot be '
            're-encoded — and losslessly it cannot reach 10:1.',
      );
    }
    final targetMedia = reencodeTargetMediaBytes(
      fileSize: fileSize,
      barcode: barcode,
      encrypted: encrypted,
      secondPassFactor: secondPassFactor,
    );
    if (targetMedia == null) {
      return RatioPlan(
        decision: RatioDecision.deadEnd,
        fileSize: fileSize,
        losslessPdfBytes: losslessPdf,
        deadEndReason: 'Even the lowest-quality re-encode cannot fit '
            '10:1 — the PDF alone is bigger than a tenth of this file.',
      );
    }
    return RatioPlan(
      decision: RatioDecision.reencode,
      fileSize: fileSize,
      losslessPdfBytes: losslessPdf,
      reencodeTargetMediaBytes: targetMedia,
      reencodeTargetPdfBytes: modelledPdfBytes(
        compressedSize: targetMedia,
        barcode: barcode,
        encrypted: encrypted,
        secondPassFactor: secondPassFactor,
      ),
    );
  }

  /// The decision only — a convenience over [analyse] for callers
  /// that do not need the numbers.
  static RatioDecision decide({
    required int fileSize,
    required double sampledRatio,
    required MediaKind kind,
    required bool losslessOnly,
    bool barcode = false,
    bool encrypted = true,
    double secondPassFactor = 1.0,
    bool streaming = false,
  }) =>
      analyse(
        fileSize: fileSize,
        sampledRatio: sampledRatio,
        kind: kind,
        losslessOnly: losslessOnly,
        barcode: barcode,
        encrypted: encrypted,
        secondPassFactor: secondPassFactor,
        streaming: streaming,
      ).decision;
}
