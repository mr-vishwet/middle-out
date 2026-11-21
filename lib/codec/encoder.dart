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
  const EncodeStats({
    required this.originalSize,
    required this.compressedSize,
    required this.frameCount,
    required this.groupCount,
    required this.sha256Hex,
  });

  final int originalSize;
  final int compressedSize;
  final int frameCount;
  final int groupCount;
  final String sha256Hex;

  double get ratio => originalSize / compressedSize.clamp(1, compressedSize);
}

/// The result of an encode: frames ready to render, plus stats.
class EncodeResult {
  const EncodeResult({
    required this.frames,
    required this.stats,
    required this.barcode,
  });

  final List<Frame> frames;
  final EncodeStats stats;
  final bool barcode;
}

/// Encodes a file into Middle Out frames.
///
/// Pipeline: SHA-256 -> zlib-9 compress -> (optional ChaCha20 encrypt) ->
/// split into <= [maxPayload] chunks -> group into 6 DATA + 2 XOR-parity.
///
/// The encoder works on bytes already in memory. Streaming a 100 GB file
/// through this pipeline chunk-by-chunk (without ever holding it whole) is
/// the v0.2 milestone; v0.1 enforces the platform limit BEFORE reading so
/// a file larger than the mode allows is routed, never loaded.
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

    final totalData = chunks.length;
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
          originalSize: data.length,
          compressedSize: stream.length,
          originalSha256: sha,
          salt: salt,
          nonce: nonce,
          payload: payload,
        );

    final frames = <Frame>[];
    for (var group = 0; group < totalGroups; group++) {
      final groupChunks = chunks.sublist(
        group * kGroupDataFrames,
        math.min((group + 1) * kGroupDataFrames, chunks.length),
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
}
