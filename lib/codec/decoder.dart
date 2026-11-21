import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../core/constants.dart';
import 'chacha20.dart';
import 'erasure.dart';
import 'frame.dart';

/// Rebuilds the original file from raw frame blobs.
///
/// Corrupt (CRC-failing) frames are treated as lost and rebuilt from parity
/// where possible. Throws [UnrecoverableException] when a parity trio lost
/// two or more frames, [VerificationException] when the rebuilt bytes fail
/// the SHA-256 / size check (wrong passphrase, tampered payload).
class Decoder {
  static int _expectedDataLength(
    int frameIndex,
    int totalDataFrames,
    int compressedSize,
    int maxPayload,
  ) {
    if (frameIndex < totalDataFrames - 1) return maxPayload;
    return compressedSize - maxPayload * (totalDataFrames - 1);
  }

  static Uint8List decode(
    List<Uint8List> frameBlobs, {
    String? passphrase,
  }) {
    final frames = <Frame>[];
    for (final blob in frameBlobs) {
      try {
        frames.add(Frame.fromBytes(blob));
      } on CorruptFrameException {
        // A frame whose header is unreadable is simply lost.
        continue;
      }
    }
    if (frames.isEmpty) {
      throw const UnrecoverableException('no readable frames');
    }

    final meta = frames.first;
    final totalData = meta.totalDataFrames;
    final totalGroups = meta.totalGroups;
    final compressedSize = meta.compressedSize;

    // Derive maxPayload from any present non-last data frame.
    var maxPayload = kDefaultMaxPayload;
    var found = false;
    for (final frame in frames) {
      if (frame.isData &&
          !frame.payloadCorrupt &&
          frame.frameIndex < totalData - 1) {
        maxPayload = frame.payload.length;
        found = true;
        break;
      }
    }
    if (!found && totalData == 1) maxPayload = compressedSize;

    // Valid frames by (group, slot); corrupt payloads are treated as lost.
    final valid = <(int, int), Frame>{};
    for (final frame in frames) {
      if (!frame.payloadCorrupt) {
        valid[(frame.groupIndex, frame.slot)] = frame;
      }
    }

    final recovered = <int, Uint8List>{};
    for (var group = 0; group < totalGroups; group++) {
      final groupDataCount =
          (totalData - group * kGroupDataFrames).clamp(0, kGroupDataFrames);
      for (final entry in {
        kParityASlot: kParityATrio,
        kParityBSlot: kParityBTrio,
      }.entries) {
        final paritySlot = entry.key;
        final slots = [
          for (final slot in entry.value)
            if (slot < groupDataCount) slot,
        ];
        final missing = [
          for (final slot in slots)
            if (!valid.containsKey((group, slot))) slot,
        ];
        if (missing.isEmpty) continue;
        if (missing.length > 1) {
          throw UnrecoverableException(
            'group $group trio ${entry.value}: ${missing.length} frames '
            'lost, parity can only rebuild one',
          );
        }
        final parity = valid[(group, paritySlot)];
        if (parity == null) {
          throw UnrecoverableException(
            'group $group trio ${entry.value}: data slot ${missing.first} '
            'lost and its parity frame is missing too',
          );
        }
        final survivors = [
          for (final slot in slots)
            if (slot != missing.first) valid[(group, slot)]!.payload,
        ];
        final frameIndex = group * kGroupDataFrames + missing.first;
        final wantLength = _expectedDataLength(
          frameIndex,
          totalData,
          compressedSize,
          maxPayload,
        );
        recovered[frameIndex] = Erasure.recover(
          parity.payload,
          survivors,
          wantLength,
        );
      }
    }

    final stream = BytesBuilder();
    for (var index = 0; index < totalData; index++) {
      if (recovered.containsKey(index)) {
        stream.add(recovered[index]!);
        continue;
      }
      final group = index ~/ kGroupDataFrames;
      final slot = index % kGroupDataFrames;
      final frame = valid[(group, slot)];
      if (frame == null) {
        throw UnrecoverableException(
          'data frame $index missing, unrecoverable',
        );
      }
      stream.add(frame.payload);
    }

    final Uint8List data;
    try {
      if (meta.isEncrypted) {
        if (passphrase == null) {
          throw const VerificationException(
            'frames are encrypted; a passphrase is required',
          );
        }
        final key = deriveKey(passphrase, meta.salt);
        final plain = ChaCha20.xor(key, meta.nonce, stream.toBytes());
        data = Uint8List.fromList(ZLibDecoder().decodeBytes(plain));
      } else {
        data = Uint8List.fromList(ZLibDecoder().decodeBytes(stream.toBytes()));
      }
    } on VerificationException {
      rethrow;
    } catch (e) {
      throw VerificationException(
        'decrypt/decompress failed — wrong passphrase or tampered frames ($e)',
      );
    }

    if (data.length != meta.originalSize) {
      throw VerificationException(
        'size mismatch: got ${data.length}, expected ${meta.originalSize}',
      );
    }
    final digest = sha256.convert(data).bytes;
    for (var i = 0; i < 32; i++) {
      if (digest[i] != meta.originalSha256[i]) {
        throw const VerificationException(
          'SHA-256 mismatch — rebuilt bytes are not the original',
        );
      }
    }
    return data;
  }
}
