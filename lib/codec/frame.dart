import 'dart:typed_data';

import '../core/constants.dart';

/// Errors thrown by the Middle Out codec.
class CodecException implements Exception {
  /// Creates an exception with a human-readable [message].
  const CodecException(this.message);

  /// Human-readable description of what went wrong.
  final String message;
  @override
  String toString() => 'CodecException: $message';
}

/// A frame failed its header or payload CRC.
class CorruptFrameException extends CodecException {
  /// Creates a corrupt-frame exception with [message].
  const CorruptFrameException(super.message);
}

/// Too many frames lost in one parity trio to rebuild the file.
class UnrecoverableException extends CodecException {
  /// Creates an unrecoverable exception with [message].
  const UnrecoverableException(super.message);
}

/// Reassembled bytes failed the SHA-256 / size check (wrong passphrase,
/// tampered payload, or a decompression failure).
class VerificationException extends CodecException {
  /// Creates a verification exception with [message].
  const VerificationException(super.message);
}

/// CRC32 (IEEE, polynomial 0xEDB88320) — the same checksum zlib uses.
/// Implemented here because package:crypto does not ship CRC32.
class Crc32 {
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
      table[i] = crc;
    }
    return table;
  }

  /// CRC32 of [data], as an unsigned 32-bit integer.
  static int checksum(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// Writes [value] as 8 big-endian bytes at [offset] in [data], using
/// only [ByteData.setUint8].
///
/// ByteData.setUint64/getUint64 (and the Int64 pair) throw
/// UnsupportedError under dart2js — JS numbers cannot hold 64-bit ints
/// — so the codec must never call them: every web encode/decode goes
/// through this helper and [readUint64BE] instead. The arithmetic is
/// exact for all values below 2^53 (~9 PB), far above any file this app
/// handles (100 GB native cap); dart2js cannot represent larger ints
/// exactly anyway.
void writeUint64BE(ByteData data, int offset, int value) {
  var remaining = value;
  for (var i = 7; i >= 0; i--) {
    data.setUint8(offset + i, remaining % 256);
    remaining ~/= 256;
  }
}

/// Reads 8 big-endian bytes at [offset] in [data] as an unsigned
/// 64-bit integer, using only [ByteData.getUint8]. See [writeUint64BE]
/// for why the ByteData 64-bit accessors are banned from this codec.
int readUint64BE(ByteData data, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = value * 256 + data.getUint8(offset + i);
  }
  return value;
}

/// One Middle Out frame: a 100-byte v2 header + payload + 4-byte payload
/// CRC.
///
/// Wire format is defined in `lib/core/constants.dart` and mirrored
/// byte-for-byte by `reference/codec_reference.py`. [toBytes] always
/// writes v2; [Frame.fromBytes] also parses v1 frames (97-byte header)
/// so PDFs encoded before the v2 widening still decode.
class Frame {
  /// Creates a frame from its header fields and [payload].
  const Frame({
    required this.frameIndex,
    required this.kind,
    required this.groupIndex,
    required this.slot,
    required this.flags,
    required this.totalGroups,
    required this.totalDataFrames,
    required this.originalSize,
    required this.compressedSize,
    required this.originalSha256,
    required this.salt,
    required this.nonce,
    required this.payload,
    this.payloadCorrupt = false,
  });

  /// Global sequence number of this frame in the encoded file.
  final int frameIndex;

  /// Frame kind: data ([kFrameKindData]) or parity ([kFrameKindParity]).
  final int kind;

  /// Index of the parity group this frame belongs to.
  final int groupIndex;

  /// Slot within the group (0..2 for data, 3 for parity).
  final int slot;

  /// Bit flags ([kFlagEncrypted], [kFlagBarcode], [kFlagLastGroup]).
  final int flags;

  /// Total number of parity groups in the encoded file.
  final int totalGroups;

  /// Total number of data frames across all groups.
  final int totalDataFrames;

  /// Size of the original file in bytes.
  final int originalSize;

  /// Size of the compressed stream in bytes.
  final int compressedSize;

  /// SHA-256 of the original file (32 bytes).
  final Uint8List originalSha256;

  /// PBKDF2 salt for the passphrase key (16 bytes, zeroed when plain).
  final Uint8List salt;

  /// ChaCha20 nonce for the payload encryption (12 bytes).
  final Uint8List nonce;

  /// Frame payload bytes (compressed stream chunk or parity data).
  final Uint8List payload;

  /// True when the payload CRC failed. The header is still trustworthy, so
  /// the decoder treats the frame as lost and rebuilds it from parity.
  final bool payloadCorrupt;

  /// True when [kind] is a data frame.
  bool get isData => kind == kFrameKindData;

  /// True when [kind] is a parity frame.
  bool get isParity => kind == kFrameKindParity;

  /// True when the payload is encrypted ([kFlagEncrypted]).
  bool get isEncrypted => flags & kFlagEncrypted != 0;

  /// True when the frame is rendered as a barcode ([kFlagBarcode]).
  bool get isBarcode => flags & kFlagBarcode != 0;

  /// True when this frame is in the last group ([kFlagLastGroup]).
  bool get isLastGroup => flags & kFlagLastGroup != 0;

  /// Serialises the frame: v2 header + payload + payload CRC.
  Uint8List toBytes() {
    final header = ByteData(kHeaderSize);
    header.setUint8(0, kFrameMagic[0]);
    header.setUint8(1, kFrameMagic[1]);
    header.setUint8(2, kFrameMagic[2]);
    header.setUint8(3, kFrameMagic[3]);
    header.setUint8(4, kFrameVersion);
    header.setUint16(5, frameIndex);
    header.setUint8(7, kind);
    header.setUint16(8, groupIndex);
    header.setUint8(10, slot);
    header.setUint8(11, flags);
    header.setUint16(12, totalGroups);
    header.setUint16(14, totalDataFrames);
    header.setUint32(16, payload.length);
    writeUint64BE(header, 20, originalSize);
    writeUint64BE(header, 28, compressedSize);
    for (var i = 0; i < 32; i++) {
      header.setUint8(36 + i, originalSha256[i]);
    }
    for (var i = 0; i < 16; i++) {
      header.setUint8(68 + i, salt[i]);
    }
    for (var i = 0; i < 12; i++) {
      header.setUint8(84 + i, nonce[i]);
    }
    final headerBytes = header.buffer.asUint8List(0, kHeaderSize - 4);
    header.setUint32(96, Crc32.checksum(headerBytes));

    final out = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(payload);
    final payloadCrc = ByteData(4)..setUint32(0, Crc32.checksum(payload));
    out.add(payloadCrc.buffer.asUint8List());
    return out.toBytes();
  }

  /// Parses a serialised frame, v2 or v1. The version byte (offset 4)
  /// picks the layout: v2 has a 100-byte header with uint16 indices,
  /// v1 a 97-byte header with uint8 indices. Throws
  /// [CorruptFrameException] when the header is unreadable (bad magic,
  /// version, length or header CRC). A payload CRC failure does NOT
  /// throw — it sets [payloadCorrupt] so the decoder can rebuild the
  /// frame from parity.
  factory Frame.fromBytes(Uint8List raw) {
    // Smallest possible frame is a v1 frame with an empty payload.
    if (raw.length < kHeaderSizeV1 + 4) {
      throw const CorruptFrameException('frame shorter than header + CRC');
    }
    for (var i = 0; i < 4; i++) {
      if (raw[i] != kFrameMagic[i]) {
        throw const CorruptFrameException('bad magic');
      }
    }
    final version = raw[4];
    final bool v2;
    if (version == kFrameVersion) {
      v2 = true;
    } else if (version == 1) {
      v2 = false;
    } else {
      throw CorruptFrameException('unsupported frame version $version');
    }
    final headerSize = v2 ? kHeaderSize : kHeaderSizeV1;
    if (raw.length < headerSize + 4) {
      throw const CorruptFrameException('frame shorter than header + CRC');
    }
    final header = ByteData.sublistView(raw, 0, headerSize);
    final storedCrc = header.getUint32(headerSize - 4);
    final computedCrc =
        Crc32.checksum(raw.sublist(0, headerSize - 4));
    if (storedCrc != computedCrc) {
      throw const CorruptFrameException('header CRC mismatch');
    }
    // v1 offsets: frameIndex @5, kind @6, groupIndex @7, slot @8,
    // flags @9, totalGroups @10 (all uint8), totalDataFrames @11..12,
    // payloadLength @13..16, originalSize @17..24, compressedSize @25..32,
    // SHA-256 @33, salt @65, nonce @81. v2 widens the three indices to
    // uint16, shifting everything after them by 3 bytes.
    final int frameIndex;
    final int kind;
    final int groupIndex;
    final int slot;
    final int flags;
    final int totalGroups;
    final int totalDataFrames;
    final int payloadLength;
    final int originalSize;
    final int compressedSize;
    final int shaOffset;
    final int saltOffset;
    final int nonceOffset;
    if (v2) {
      frameIndex = header.getUint16(5);
      kind = header.getUint8(7);
      groupIndex = header.getUint16(8);
      slot = header.getUint8(10);
      flags = header.getUint8(11);
      totalGroups = header.getUint16(12);
      totalDataFrames = header.getUint16(14);
      payloadLength = header.getUint32(16);
      originalSize = readUint64BE(header, 20);
      compressedSize = readUint64BE(header, 28);
      shaOffset = 36;
      saltOffset = 68;
      nonceOffset = 84;
    } else {
      frameIndex = header.getUint8(5);
      kind = header.getUint8(6);
      groupIndex = header.getUint8(7);
      slot = header.getUint8(8);
      flags = header.getUint8(9);
      totalGroups = header.getUint8(10);
      totalDataFrames = header.getUint16(11);
      payloadLength = header.getUint32(13);
      originalSize = readUint64BE(header, 17);
      compressedSize = readUint64BE(header, 25);
      shaOffset = 33;
      saltOffset = 65;
      nonceOffset = 81;
    }
    if (raw.length != headerSize + payloadLength + 4) {
      throw CorruptFrameException(
        'frame length ${raw.length} != header + $payloadLength + CRC',
      );
    }
    final payload = Uint8List.sublistView(
      raw,
      headerSize,
      headerSize + payloadLength,
    );
    final payloadCrc =
        ByteData.sublistView(raw, headerSize + payloadLength).getUint32(0);
    final corrupt = Crc32.checksum(payload) != payloadCrc;
    return Frame(
      frameIndex: frameIndex,
      kind: kind,
      groupIndex: groupIndex,
      slot: slot,
      flags: flags,
      totalGroups: totalGroups,
      totalDataFrames: totalDataFrames,
      originalSize: originalSize,
      compressedSize: compressedSize,
      originalSha256: Uint8List.sublistView(raw, shaOffset, shaOffset + 32),
      salt: Uint8List.sublistView(raw, saltOffset, saltOffset + 16),
      nonce: Uint8List.sublistView(raw, nonceOffset, nonceOffset + 12),
      payload: Uint8List.fromList(payload),
      payloadCorrupt: corrupt,
    );
  }
}
