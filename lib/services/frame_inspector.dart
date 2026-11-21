import 'dart:typed_data';

import '../codec/frame.dart';
import '../core/constants.dart';

/// What the decoder can tell about a set of imported frames before
/// decoding starts: which frames are present, corrupt or missing, and
/// whether parity can rebuild the gaps.
///
/// The import screen (m14/w14) and the damaged-frame screen (m18/w18)
/// render this; the decoder itself re-derives the same facts when it runs.
class FrameInspection {
  /// Creates an inspection result.
  const FrameInspection({
    required this.totalFrames,
    required this.totalDataFrames,
    required this.totalGroups,
    required this.presentData,
    required this.presentParity,
    required this.missingDataIndices,
    required this.corruptDataIndices,
    required this.corruptParitySlots,
    required this.unreadableBlobs,
    required this.recoverable,
    required this.unrecoverableReason,
    required this.originalSize,
    required this.compressedSize,
    required this.expectedSha256Hex,
    required this.encrypted,
    required this.barcode,
    required this.recoveredViaParity,
  });

  /// Total frames in the encode (data + parity).
  final int totalFrames;

  /// Total DATA frames in the encode.
  final int totalDataFrames;

  /// Total 8-frame groups in the encode.
  final int totalGroups;

  /// Valid DATA frames present.
  final int presentData;

  /// Valid PARITY frames present.
  final int presentParity;

  /// Global DATA indices with no frame at all.
  final List<int> missingDataIndices;

  /// Global DATA indices whose frame failed its payload CRC.
  final List<int> corruptDataIndices;

  /// (group, slot) pairs whose parity frame failed its payload CRC.
  final List<(int, int)> corruptParitySlots;

  /// Blobs that could not be parsed as frames at all.
  final int unreadableBlobs;

  /// True when every gap can be rebuilt from parity.
  final bool recoverable;

  /// Why recovery is impossible, naming the group and trio — null when
  /// [recoverable] is true.
  final String? unrecoverableReason;

  /// Original file size from the frame headers.
  final int originalSize;

  /// Compressed (+encrypted) stream size from the frame headers.
  final int compressedSize;

  /// Expected SHA-256 hex of the original, from the frame headers.
  final String expectedSha256Hex;

  /// True when the frames are encrypted.
  final bool encrypted;

  /// True when the frames were rendered as barcodes.
  final bool barcode;

  /// Global DATA indices the decoder will rebuild from parity.
  final List<int> recoveredViaParity;

  /// True when every frame is present and clean.
  bool get isComplete =>
      missingDataIndices.isEmpty && corruptDataIndices.isEmpty;

  /// True when anything is damaged but recoverable.
  bool get hasDamage =>
      (missingDataIndices.isNotEmpty || corruptDataIndices.isNotEmpty) &&
      recoverable;

  /// Frames readable out of the total (for the "8 of 8 frames readable"
  /// import line).
  int get readableFrames => presentData + presentParity;

  /// Payload bytes the parity rebuild restores (approximate: missing and
  /// corrupt data frames carry up to [kDefaultMaxPayload] each; the
  /// exact count is known only after decode).
  int get damagedFrameCount =>
      missingDataIndices.length + corruptDataIndices.length;
}

/// Inspects imported frame blobs before decoding.
class FrameInspector {
  /// Inspects [blobs] (one blob per frame, any order).
  ///
  /// Throws [CodecException] when no blob parses as a frame.
  static FrameInspection inspect(List<Uint8List> blobs) {
    final frames = <Frame>[];
    var unreadable = 0;
    for (final blob in blobs) {
      try {
        frames.add(Frame.fromBytes(blob));
      } on CorruptFrameException {
        unreadable++;
      }
    }
    if (frames.isEmpty) {
      throw const CodecException(
        'no readable frames — import a Middle Out PDF or .bin frame files',
      );
    }
    final meta = frames.first;
    final totalData = meta.totalDataFrames;
    final totalGroups = meta.totalGroups;

    final valid = <(int, int), Frame>{};
    final corruptData = <int>[];
    final corruptParity = <(int, int)>[];
    var presentData = 0;
    var presentParity = 0;
    for (final frame in frames) {
      if (frame.payloadCorrupt) {
        if (frame.isData) {
          corruptData.add(frame.frameIndex);
        } else {
          corruptParity.add((frame.groupIndex, frame.slot));
        }
        continue;
      }
      valid[(frame.groupIndex, frame.slot)] = frame;
      if (frame.isData) {
        presentData++;
      } else {
        presentParity++;
      }
    }

    final missing = <int>[];
    for (var index = 0; index < totalData; index++) {
      final group = index ~/ kGroupDataFrames;
      final slot = index % kGroupDataFrames;
      if (!valid.containsKey((group, slot)) &&
          !corruptData.contains(index)) {
        missing.add(index);
      }
    }

    // Recoverability: per trio, at most one lost frame, and its parity
    // frame must be present and clean.
    var recoverable = true;
    String? reason;
    final recovered = <int>[];
    for (var group = 0; group < totalGroups; group++) {
      final groupDataCount =
          (totalData - group * kGroupDataFrames).clamp(0, kGroupDataFrames);
      for (final entry in {
        kParityASlot: kParityATrio,
        kParityBSlot: kParityBTrio,
      }.entries) {
        final slots = [
          for (final slot in entry.value)
            if (slot < groupDataCount) slot,
        ];
        final lost = [
          for (final slot in slots)
            if (!valid.containsKey((group, slot))) slot,
        ];
        if (lost.isEmpty) continue;
        if (lost.length > 1) {
          recoverable = false;
          reason = 'Group ${group + 1}, trio ${entry.value}: '
              '${lost.length} frames lost — parity can only rebuild one';
          continue;
        }
        if (!valid.containsKey((group, entry.key))) {
          recoverable = false;
          reason = 'Group ${group + 1}, trio ${entry.value}: data slot '
              '${lost.first} lost and its parity frame is missing too';
          continue;
        }
        recovered.add(group * kGroupDataFrames + lost.first);
      }
    }

    final shaHex = meta.originalSha256
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return FrameInspection(
      totalFrames: totalData + totalGroups * kGroupParityFrames,
      totalDataFrames: totalData,
      totalGroups: totalGroups,
      presentData: presentData,
      presentParity: presentParity,
      missingDataIndices: missing,
      corruptDataIndices: corruptData..sort(),
      corruptParitySlots: corruptParity,
      unreadableBlobs: unreadable,
      recoverable: recoverable,
      unrecoverableReason: reason,
      originalSize: meta.originalSize,
      compressedSize: meta.compressedSize,
      expectedSha256Hex: shaHex,
      encrypted: meta.isEncrypted,
      barcode: meta.isBarcode,
      recoveredViaParity: recovered..sort(),
    );
  }
}
