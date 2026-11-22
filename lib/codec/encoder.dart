import 'dart:math' as math;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../core/constants.dart';
import 'chacha20.dart';
import 'erasure.dart';
import 'frame.dart';

/// Statistics for a completed encode.
class EncodeStats {
  /// Creates encode statistics.
  const EncodeStats({
    required this.originalSize,
    required this.compressedSize,
    required this.frameCount,
    required this.groupCount,
    required this.sha256Hex,
  });

  /// Bytes of the original file.
  final int originalSize;

  /// Bytes of the compressed (+encrypted) stream.
  final int compressedSize;

  /// Frames in the encode (data + parity).
  final int frameCount;

  /// Parity groups in the encode (up to 8 frames each).
  final int groupCount;

  /// SHA-256 hex of the original file.
  final String sha256Hex;

  /// Compression ratio (original / compressed).
  double get ratio => originalSize / compressedSize.clamp(1, compressedSize);
}

/// The result of an encode: frames ready to render, plus stats.
class EncodeResult {
  /// Creates an encode result.
  const EncodeResult({
    required this.frames,
    required this.stats,
    required this.barcode,
  });

  /// Frames ready to render (data + parity, group order).
  final List<Frame> frames;

  /// Encode statistics.
  final EncodeStats stats;

  /// True when the frames render as bar-grid barcodes.
  final bool barcode;
}

/// Progress callback for staged encodes: [fraction] 0..1 of the encode
/// step and a human-readable stage label.
typedef EncodeProgress = void Function(double fraction, String label);

/// Encodes a file into Middle Out frames.
///
/// Pipeline: SHA-256 -> zlib-9 compress -> (optional ChaCha20 encrypt) ->
/// split into at most [kMaxDataPages] EQUAL chunks (the last zero-padded
/// to the chunk size) -> group into 6 DATA + up to 2 XOR-parity.
///
/// [encode] works on bytes already in memory, synchronously.
/// [encodeAsync] runs the same pipeline in stages, yielding to the event
/// loop between them so the UI can repaint the progress bar — the
/// synchronous [encode] blocks the UI thread for the whole run, so the
/// bar cannot move during it. [StreamingEncoder] runs the same pipeline
/// chunk-by-chunk off disk for large native files, but with FIXED
/// [kDefaultMaxPayload] chunks (it does not know the total upfront, so
/// it cannot equal-split); all three share [buildFrames], so a streamed
/// encode uses the same framing, headers and parity layout as an
/// in-memory one — only the chunking and the equal-split flag differ.
class Encoder {
  /// Encodes [data]. Pass [passphrase] to encrypt (default ON in the UI);
  /// pass null for a plain encode whose payload is human-readable.
  ///
  /// [maxPayload] is the sizing unit for the equal split: the stream is
  /// divided into `min(kMaxDataPages, ceil(stream / maxPayload))` equal
  /// chunks, so a chunk can be larger than [maxPayload] when the stream
  /// needs more than [kMaxDataPages] chunks at that unit. Streaming
  /// encodes keep [maxPayload] as a hard chunk size.
  static EncodeResult encode(
    Uint8List data, {
    String? passphrase,
    int maxPayload = kDefaultMaxPayload,
    bool barcode = false,
  }) {
    final sha = _hash(data);
    final compressed = _compress(data);
    final encrypted = _maybeEncrypt(compressed, passphrase);
    final chunks = _chunk(encrypted.stream, maxPayload);
    return _finish(
      data: data,
      sha: sha,
      stream: encrypted.stream,
      chunks: chunks,
      salt: encrypted.salt,
      nonce: encrypted.nonce,
      encrypted: passphrase != null,
      barcode: barcode,
    );
  }

  /// Staged async encode: same pipeline and output as [encode], but each
  /// stage reports through [onProgress] and yields first, so the UI
  /// paints the new stage before the next blocking chunk of work starts.
  /// The heavy stages (zlib, ChaCha20) still run synchronously — the
  /// yields only let the frame paint between stages.
  static Future<EncodeResult> encodeAsync(
    Uint8List data, {
    String? passphrase,
    int maxPayload = kDefaultMaxPayload,
    bool barcode = false,
    EncodeProgress? onProgress,
  }) async {
    onProgress?.call(0.05, 'Hashing…');
    await Future<void>.delayed(Duration.zero);
    final sha = _hash(data);
    onProgress?.call(0.15, 'Compressing…');
    await Future<void>.delayed(Duration.zero);
    final compressed = _compress(data);
    final isEncrypted = passphrase != null;
    if (isEncrypted) {
      onProgress?.call(0.6, 'Encrypting…');
      await Future<void>.delayed(Duration.zero);
    }
    final encrypted = _maybeEncrypt(compressed, passphrase);
    onProgress?.call(0.7, 'Framing…');
    await Future<void>.delayed(Duration.zero);
    final chunks = _chunk(encrypted.stream, maxPayload);
    final result = _finish(
      data: data,
      sha: sha,
      stream: encrypted.stream,
      chunks: chunks,
      salt: encrypted.salt,
      nonce: encrypted.nonce,
      encrypted: isEncrypted,
      barcode: barcode,
    );
    onProgress?.call(0.95, 'Framing…');
    return result;
  }

  static Uint8List _hash(Uint8List data) =>
      Uint8List.fromList(sha256.convert(data).bytes);

  static Uint8List _compress(Uint8List data) =>
      Uint8List.fromList(const ZLibEncoder().encode(data, level: 9));

  static ({Uint8List salt, Uint8List nonce, Uint8List stream}) _maybeEncrypt(
    Uint8List compressed,
    String? passphrase,
  ) {
    if (passphrase == null) {
      return (
        salt: Uint8List(kSaltLength),
        nonce: Uint8List(kNonceLength),
        stream: compressed,
      );
    }
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(kSaltLength, (_) => random.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(kNonceLength, (_) => random.nextInt(256)),
    );
    final key = deriveKey(passphrase, salt);
    return (
      salt: salt,
      nonce: nonce,
      stream: ChaCha20.xor(key, nonce, compressed),
    );
  }

  /// Equal-split chunking: the stream is divided into at most
  /// [kMaxDataPages] equal chunks of [chunkSize] bytes
  /// (`ceil(stream.length / count)`), so every code page is dense no
  /// matter the file size. The LAST chunk is zero-padded to [chunkSize]
  /// so all data frames (and the parity built from them) share one
  /// width; the decoder trims the reassembled stream to
  /// `compressedSize` before decrypt/decompress, stripping the padding.
  ///
  /// [maxPayload] is the sizing unit: `count =
  /// min(kMaxDataPages, ceil(stream.length / maxPayload))`, clamped to
  /// at least 1. The count is then re-derived from the chunk size
  /// (`ceil(stream.length / chunkSize)`) so the last chunk is the only
  /// short one — without that, a tiny stream with a tiny unit could
  /// yield a short MIDDLE chunk (or an empty one), which the decoder
  /// cannot represent. The decoder re-derives [chunkSize] from the
  /// header alone (`ceil(compressedSize / totalDataFrames)`), so the
  /// two always agree.
  ///
  /// An empty stream yields one empty chunk (one empty data frame, no
  /// parity — [buildFrames] skips empty parities).
  static List<Uint8List> _chunk(Uint8List stream, int maxPayload) {
    final unit = maxPayload < 1 ? 1 : maxPayload;
    var count = ((stream.length + unit - 1) ~/ unit)
        .clamp(1, kMaxDataPages);
    final chunkSize = (stream.length + count - 1) ~/ count;
    if (chunkSize > 0) {
      // Re-derive the count from the chunk size (see the doc above).
      count = (stream.length + chunkSize - 1) ~/ chunkSize;
    }
    final chunks = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * chunkSize;
      final end = math.min(start + chunkSize, stream.length);
      if (end - start == chunkSize) {
        chunks.add(Uint8List.sublistView(stream, start, end));
      } else {
        // Last chunk, short: zero-pad to chunkSize.
        final padded = Uint8List(chunkSize)
          ..setAll(0, stream.sublist(start, end));
        chunks.add(padded);
      }
    }
    if (chunks.isEmpty) chunks.add(Uint8List(0));
    return chunks;
  }

  static EncodeResult _finish({
    required Uint8List data,
    required Uint8List sha,
    required Uint8List stream,
    required List<Uint8List> chunks,
    required Uint8List salt,
    required Uint8List nonce,
    required bool encrypted,
    required bool barcode,
  }) {
    final frames = buildFrames(
      chunks: chunks,
      sha256Bytes: sha,
      originalSize: data.length,
      compressedSize: stream.length,
      salt: salt,
      nonce: nonce,
      encrypted: encrypted,
      barcode: barcode,
      equalSplit: true,
    );
    final totalGroups =
        (chunks.length + kGroupDataFrames - 1) ~/ kGroupDataFrames;
    return EncodeResult(
      frames: frames,
      stats: EncodeStats(
        originalSize: data.length,
        compressedSize: stream.length,
        frameCount: frames.length,
        groupCount: totalGroups,
        sha256Hex: sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      ),
      barcode: barcode,
    );
  }

  /// Frames a compressed (+encrypted) stream given as [chunks].
  ///
  /// Shared by [encode] and [StreamingEncoder]: the frame layout, header
  /// fields, parity construction and frame-index assignment are identical
  /// whichever path produced the stream. Throws [CodecException] when the
  /// encode would need more than [kMaxFrames] frames.
  ///
  /// A parity frame is emitted ONLY when its trio has at least one data
  /// slot present AND the parity payload is non-empty: a trailing group
  /// with <= 3 data frames has no second parity, and an empty encode
  /// (one empty data frame) has no parity at all. An empty parity would
  /// render as a near-blank code page. Parity frame indices keep the
  /// formula `totalData + group*2 + (slot-6)`, so a skipped P2 leaves a
  /// gap at the END of the index range only (P2 is skipped only in the
  /// last group) — nothing assumes contiguous parity indices: the
  /// decoder and the inspector key parity by (group, slot).
  ///
  /// [equalSplit] sets [kFlagEqualSplit] on every frame: the chunks are
  /// equal-sized (last zero-padded) and the decoder derives the chunk
  /// size from the header. Streaming chunks are fixed-size and leave
  /// the flag clear.
  static List<Frame> buildFrames({
    required List<Uint8List> chunks,
    required Uint8List sha256Bytes,
    required int originalSize,
    required int compressedSize,
    required Uint8List salt,
    required Uint8List nonce,
    required bool encrypted,
    required bool barcode,
    bool equalSplit = false,
  }) {
    final dataChunks = chunks.isEmpty ? [Uint8List(0)] : chunks;
    final totalData = dataChunks.length;
    final totalGroups = (totalData + kGroupDataFrames - 1) ~/ kGroupDataFrames;
    // Upper bound — skipped (empty-trio) parities make the real count
    // smaller, which only helps the cap.
    final totalFrames = totalData + totalGroups * kGroupParityFrames;
    if (totalFrames > kMaxFrames) {
      throw CodecException(
        'This file needs $totalFrames frames — over the $kMaxFrames-frame '
        'limit for one PDF. Split it into smaller files and encode each '
        'one separately.',
      );
    }

    var baseFlags = 0;
    if (encrypted) baseFlags |= kFlagEncrypted;
    if (barcode) baseFlags |= kFlagBarcode;
    if (equalSplit) baseFlags |= kFlagEqualSplit;

    Frame buildFrame({
      required int frameIndex,
      required int kind,
      required int group,
      required int slot,
      required int flags,
      required Uint8List payload,
    }) =>
        Frame(
          frameIndex: frameIndex,
          kind: kind,
          groupIndex: group,
          slot: slot,
          flags: flags,
          totalGroups: totalGroups,
          totalDataFrames: totalData,
          originalSize: originalSize,
          compressedSize: compressedSize,
          originalSha256: sha256Bytes,
          salt: salt,
          nonce: nonce,
          payload: payload,
        );

    final frames = <Frame>[];
    for (var group = 0; group < totalGroups; group++) {
      final groupChunks = dataChunks.sublist(
        group * kGroupDataFrames,
        math.min((group + 1) * kGroupDataFrames, dataChunks.length),
      );
      var groupFlags = baseFlags;
      if (group == totalGroups - 1) groupFlags |= kFlagLastGroup;

      for (var slot = 0; slot < groupChunks.length; slot++) {
        frames.add(
          buildFrame(
            frameIndex: group * kGroupDataFrames + slot,
            kind: kFrameKindData,
            group: group,
            slot: slot,
            flags: groupFlags,
            payload: groupChunks[slot],
          ),
        );
      }
      for (final entry in {
        kParityASlot: kParityATrio,
        kParityBSlot: kParityBTrio,
      }.entries) {
        final trioPayloads = [
          for (final slot in entry.value)
            if (slot < groupChunks.length) groupChunks[slot],
        ];
        // Skip empty trios (and all-empty trios, e.g. an empty encode):
        // an empty parity would render as a near-blank code page.
        if (trioPayloads.isEmpty) continue;
        final parity = Erasure.buildParity(trioPayloads);
        if (parity.isEmpty) continue;
        frames.add(
          buildFrame(
            frameIndex: totalData +
                group * kGroupParityFrames +
                (entry.key - kParityASlot),
            kind: kFrameKindParity,
            group: group,
            slot: entry.key,
            flags: groupFlags,
            payload: parity,
          ),
        );
      }
    }
    return frames;
  }
}
