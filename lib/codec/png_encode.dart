import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'frame.dart';

/// Minimal 1-bit image encoding for the encoded PDF.
///
/// The encoded PDF embeds each frame as a 1-bit image XObject — far smaller
/// than drawing every module as a vector rectangle (a 100k-module page
/// would be ~3 MB of content-stream operators; the 1-bit image is ~60 KB).
///
/// Two forms are offered, sharing the same packer:
/// * [encode1Bit] — a complete PNG (IHDR, one zlib-compressed IDAT of
///   filter-0 scanlines, IEND). Kept for tests and tooling; the PDF
///   builder no longer uses it.
/// * [deflate1Bit] — just the zlib-compressed packed pixels (predictor
///   1: no filter bytes, no PNG wrapper), which [RawPdfWriter] embeds
///   verbatim as a DeviceGray image XObject. No PNG decode/re-encode
///   step ever runs on them, which is what makes the PDF build fast
///   (see [RawPdfWriter]).
class PngEncode {
  /// Encodes a [width] x [height] 1-bit image. [rows] is one byte per
  /// module (0 = white, 1 = black); each row must be [width] long.
  static Uint8List encode1Bit(List<Uint8List> rows, int width, int height) {
    final packed = _packAndInvert(rows, width, height);
    // PNG scanlines carry one filter byte (0) per row.
    final stride = (width + 7) ~/ 8;
    final raw = Uint8List(height * (stride + 1));
    for (var y = 0; y < height; y++) {
      raw.setRange(
        y * (stride + 1) + 1,
        (y + 1) * (stride + 1),
        packed,
        y * stride,
      );
    }
    final compressed = const ZLibEncoder().encode(raw, level: 9);
    final out = BytesBuilder()
      ..add(_pngSignature)
      ..add(_chunk('IHDR', _ihdr(width, height)))
      ..add(_chunk('IDAT', Uint8List.fromList(compressed)))
      ..add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }

  /// Packs a [width] x [height] 1-bit image into zlib-compressed bytes
  /// for a PDF image XObject (predictor 1: packed bits, no filter bytes).
  /// [rows] is one byte per module (0 = white, 1 = black); each row must
  /// be [width] long.
  ///
  /// Level 6, not 9: on random grid data the two are the same speed and
  /// size (no matches to find), and on repetitive data level 6 is far
  /// faster (barcode raw: 16 ms vs 56 ms at level 9, +1% size).
  ///
  /// [dark] inverts the polarity for dark code pages: black modules
  /// become white pixels (DeviceGray bit 1) and white modules become
  /// black, so the code reads white-on-black over the page's black
  /// background. The packer just skips its usual inversion.
  static Uint8List deflate1Bit(
    List<Uint8List> rows,
    int width,
    int height, {
    bool dark = false,
  }) {
    final packed = _packAndInvert(rows, width, height, dark: dark);
    return Uint8List.fromList(const ZLibEncoder().encode(packed, level: 6));
  }

  /// Packs [rows] of 0/1 modules into bytes, MSB first, then inverts to
  /// DeviceGray polarity (0 = black, 1 = white). Pad bits past the row
  /// width are zero. No filter bytes — callers add them if needed.
  /// With [dark] the inversion is skipped, so the packed bits are the
  /// module bits themselves: black modules render white, white black.
  static Uint8List _packAndInvert(
    List<Uint8List> rows,
    int width,
    int height, {
    bool dark = false,
  }) {
    if (rows.length != height) {
      throw ArgumentError('rows.length (${rows.length}) != height ($height)');
    }
    final stride = (width + 7) ~/ 8;
    final raw = Uint8List(height * stride);
    for (var y = 0; y < height; y++) {
      final row = rows[y];
      if (row.length != width) {
        throw ArgumentError('row $y has length ${row.length}, expected $width');
      }
      var offset = y * stride;
      var current = 0;
      var bits = 0;
      for (var x = 0; x < width; x++) {
        current = (current << 1) | (row[x] & 1);
        bits++;
        if (bits == 8) {
          raw[offset++] = current;
          current = 0;
          bits = 0;
        }
      }
      if (bits > 0) raw[offset] = current << (8 - bits);
    }
    // PNG greyscale / DeviceGray: 0 = black, 1 = white — invert our
    // 1 = black modules. Skipped for dark pages (see [deflate1Bit]).
    if (!dark) {
      for (var i = 0; i < raw.length; i++) {
        raw[i] = (~raw[i]) & 0xFF;
      }
    }
    // Pad bits past the row width must be zero after inversion.
    final padBits = stride * 8 - width;
    if (padBits > 0) {
      final mask = 0xFF << padBits & 0xFF;
      for (var y = 0; y < height; y++) {
        raw[y * stride + stride - 1] &= mask;
      }
    }
    return raw;
  }

  static const List<int> _pngSignature = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  static Uint8List _ihdr(int width, int height) {
    final data = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 1) // bit depth 1
      ..setUint8(9, 0) // colour type 0: greyscale
      ..setUint8(10, 0) // compression: deflate
      ..setUint8(11, 0) // filter: adaptive (we use 0 per row)
      ..setUint8(12, 0); // interlace: none
    return data.buffer.asUint8List();
  }

  static Uint8List _chunk(String type, Uint8List data) {
    final typeBytes = Uint8List.fromList(type.codeUnits);
    final out = BytesBuilder()
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(typeBytes)
      ..add(data);
    final crcInput = BytesBuilder()
      ..add(typeBytes)
      ..add(data);
    out.add(
      (ByteData(
        4,
      )..setUint32(0, Crc32.checksum(crcInput.toBytes()))).buffer.asUint8List(),
    );
    return out.toBytes();
  }
}
