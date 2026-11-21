import 'dart:typed_data';

import '../core/constants.dart';

/// Errors thrown by the Middle Out codec.
class CodecException implements Exception {
  const CodecException(this.message);
  final String message;
  @override
  String toString() => 'CodecException: $message';
}

/// A frame failed its header or payload CRC.
class CorruptFrameException extends CodecException {
  const CorruptFrameException(super.message);
}

/// Too many frames lost in one parity trio to rebuild the file.
class UnrecoverableException extends CodecException {
  const UnrecoverableException(super.message);
}

/// Reassembled bytes failed the SHA-256 / size check (wrong passphrase,
/// tampered payload, or a decompression failure).
class VerificationException extends CodecException {
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

/// One Middle Out frame: a 97-byte header + payload + 4-byte payload CRC.
///
/// Wire format is defined in `lib/core/constants.dart` and mirrored
/// byte-for-byte by `reference/codec_reference.py`.
class Frame {
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

  final int frameIndex;
  final int kind;
  final int groupIndex;
  final int slot;
  final int flags;
  final int totalGroups;
  final int totalDataFrames;
  final int originalSize;
  final int compressedSize;
  final Uint8List originalSha256;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List payload;

  /// True when the payload CRC failed. The header is still trustworthy, so
  /// the decoder treats the frame as lost and rebuilds it from parity.
  final bool payloadCorrupt;

  bool get isData => kind == kFrameKindData;
  bool get isParity => kind == kFrameKindParity;
  bool get isEncrypted => flags & kFlagEncrypted != 0;
  bool get isBarcode => flags & kFlagBarcode != 0;
  bool get isLastGroup => flags & kFlagLastGroup != 0;

  /// Serialises the frame: header + payload + payload CRC.
  Uint8List toBytes() {
    final header = ByteData(kHeaderSize);
    header.setUint8(0, kFrameMagic[0]);
    header.setUint8(1, kFrameMagic[1]);
    header.setUint8(2, kFrameMagic[2]);
    header.setUint8(3, kFrameMagic[3]);
    header.setUint8(4, kFrameVersion);
    header.setUint8(5, frameIndex);
    header.setUint8(6, kind);
    header.setUint8(7, groupIndex);
    header.setUint8(8, slot);
    header.setUint8(9, flags);
    header.setUint8(10, totalGroups);
    header.setUint16(11, totalDataFrames);
    header.setUint32(13, payload.length);
    header.setUint64(17, originalSize);
    header.setUint64(25, compressedSize);
    for (var i = 0; i < 32; i++) {
      header.setUint8(33 + i, originalSha256[i]);
    }
    for (var i = 0; i < 16; i++) {
      header.setUint8(65 + i, salt[i]);
    }
    for (var i = 0; i < 12; i++) {
      header.setUint8(81 + i, nonce[i]);
    }
    final headerBytes = header.buffer.asUint8List(0, kHeaderSize - 4);
    header.setUint32(93, Crc32.checksum(headerBytes));

    final out = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(payload);
    final payloadCrc = ByteData(4)..setUint32(0, Crc32.checksum(payload));
    out.add(payloadCrc.buffer.asUint8List());
    return out.toBytes();
  }

  /// Parses a serialised frame. Throws [CorruptFrameException] when the
  /// header is unreadable (bad magic, version, length or header CRC). A
  /// payload CRC failure does NOT throw — it sets [payloadCorrupt] so the
  /// decoder can rebuild the frame from parity.
  factory Frame.fromBytes(Uint8List raw) {
    if (raw.length < kHeaderSize + 4) {
      throw const CorruptFrameException('frame shorter than header + CRC');
    }
    for (var i = 0; i < 4; i++) {
      if (raw[i] != kFrameMagic[i]) {
        throw const CorruptFrameException('bad magic');
      }
    }
    final header = ByteData.sublistView(raw, 0, kHeaderSize);
    final version = header.getUint8(4);
    if (version != kFrameVersion) {
      throw CorruptFrameException('unsupported frame version $version');
    }
    final storedCrc = header.getUint32(93);
    final computedCrc =
        Crc32.checksum(raw.sublist(0, kHeaderSize - 4));
    if (storedCrc != computedCrc) {
      throw const CorruptFrameException('header CRC mismatch');
    }
    final payloadLength = header.getUint32(13);
    if (raw.length != kHeaderSize + payloadLength + 4) {
      throw CorruptFrameException(
        'frame length ${raw.length} != header + $payloadLength + CRC',
      );
    }
    final payload = Uint8List.sublistView(raw, kHeaderSize, payloadLength);
    final payloadCrc =
        ByteData.sublistView(raw, kHeaderSize + payloadLength).getUint32(0);
    final corrupt = Crc32.checksum(payload) != payloadCrc;
    return Frame(
      frameIndex: header.getUint8(5),
      kind: header.getUint8(6),
      groupIndex: header.getUint8(7),
      slot: header.getUint8(8),
      flags: header.getUint8(9),
      totalGroups: header.getUint8(10),
      totalDataFrames: header.getUint16(11),
      originalSize: header.getUint64(17),
      compressedSize: header.getUint64(25),
      originalSha256: Uint8List.sublistView(raw, 33, 32),
      salt: Uint8List.sublistView(raw, 65, 16),
      nonce: Uint8List.sublistView(raw, 81, 12),
      payload: Uint8List.fromList(payload),
      payloadCorrupt: corrupt,
    );
  }
}
