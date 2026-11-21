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

  /// 8-frame groups in the encode.
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

  /// True when the frames render as stacked barcodes.
  final bool barcode;
}

/// Encodes a file into Middle Out frames.
///
/// Pipeline: SHA-256 -> zlib-9 compress -> (optional ChaCha20 encrypt) ->
/// split into <= [maxPayload] chunks -> group into 6 DATA + 2 XOR-parity.
///
/// [encode] works on bytes already in memory. [StreamingEncoder] runs the
/// same pipeline chunk-by-chunk off disk for large native files; both
/// share [buildFrames], so a streamed encode is byte-identical in framing
/// to an in-memory one (compression output may differ by chunking, which
/// is fine — zlib streams are self-describing).
class Encoder {
  /// Encodes [data]. Pass [passphrase] to encrypt (default ON in the UI);
  /// pass null for a plain encode whose payload is human-readable.
  static EncodeResult encode(
    Uint8List data, {
    String? passphrase,
    int maxPayload = kDefaultMaxPayload,
    bool barcode = false,
  }) {
    final sha = Uint8List.fromList(sha256.convert(data).bytes);
    final compressed =
        Uint8List.fromList(ZLibEncoder(level: 9).encode(data));

    final encrypted = passphrase != null;
    final Uint8List salt;
    final Uint8List nonce;
    final Uint8List stream;
    if (encrypted) {
      final random = Random.secure();
      salt = Uint8List.fromList(
        List<int>.generate(kSaltLength, (_) => random.nextInt(256)),
      );
      nonce = Uint8List.fromList(
        List<int>.generate(kNonceLength, (_) => random.nextInt(256)),
      );
      final key = deriveKey(passphrase, salt);
      stream = ChaCha20.xor(key, nonce, compressed);
    } else {
      salt = Uint8List(kSaltLength);
      nonce = Uint8List(kNonceLength);
      stream = compressed;
    }

    final chunks = <Uint8List>[];
    for (var i = 0; i < stream.length; i += maxPayload) {
      final end = math.min(i + maxPayload, stream.length);
      chunks.add(Uint8List.sublistView(stream, i, end - i));
    }
    if (chunks.isEmpty) chunks.add(Uint8List(0));

    final frames = buildFrames(
      chunks: chunks,
      sha256Bytes: sha,
      originalSize: data.length,
      compressedSize: stream.length,
      salt: salt,
      nonce: nonce,
      encrypted: encrypted,
      barcode: barcode,
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
  static List<Frame> buildFrames({
    required List<Uint8List> chunks,
    required Uint8List sha256Bytes,
    required int originalSize,
    required int compressedSize,
    required Uint8List salt,
    required Uint8List nonce,
    required bool encrypted,
    required bool barcode,
  }) {
    final dataChunks = chunks.isEmpty ? [Uint8List(0)] : chunks;
    final totalData = dataChunks.length;
    final totalGroups = (totalData + kGroupDataFrames - 1) ~/ kGroupDataFrames;
    final totalFrames = totalData + totalGroups * kGroupParityFrames;
    if (totalFrames > kMaxFrames) {
      throw CodecException(
        'encode needs $totalFrames frames, max is $kMaxFrames; '
        'raise maxPayload or split the file',
      );
    }

    var baseFlags = 0;
    if (encrypted) baseFlags |= kFlagEncrypted;
    if (barcode) baseFlags |= kFlagBarcode;

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
        frames.add(
          buildFrame(
            frameIndex: totalData +
                group * kGroupParityFrames +
                (entry.key - kParityASlot),
            kind: kFrameKindParity,
            group: group,
            slot: entry.key,
            flags: groupFlags,
            payload: Erasure.buildParity(trioPayloads),
          ),
        );
      }
    }
    return frames;
  }
}
