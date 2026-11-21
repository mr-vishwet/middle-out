import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'frame.dart';

/// Minimal PNG encoder for 1-bit grayscale images.
///
/// The encoded PDF embeds each frame as a 1-bit image XObject — far smaller
/// than drawing every module as a vector rectangle (a 100k-module page
/// would be ~3 MB of content-stream operators; the 1-bit image is ~60 KB).
/// This encoder writes only what the PDF needs: IHDR (bit depth 1,
/// colour type 0), a single zlib-compressed IDAT of filter-0 scanlines,
/// and IEND. No dependency on an image package.
class PngEncode {
  /// Encodes a [width] x [height] 1-bit image. [rows] is one byte per
  /// module (0 = white, 1 = black); each row must be [width] long.
  static Uint8List encode1Bit(
    List<Uint8List> rows,
    int width,
    int height,
  ) {
    if (rows.length != height) {
      throw ArgumentError('rows.length (${rows.length}) != height ($height)');
    }
    // Pack modules into bits, MSB first, one filter byte (0) per scanline.
    final stride = (width + 7) ~/ 8;
    final raw = Uint8List(height * (stride + 1));
    for (var y = 0; y < height; y++) {
      final row = rows[y];
      if (row.length != width) {
        throw ArgumentError('row $y has length ${row.length}, expected $width');
      }
      var offset = y * (stride + 1) + 1; // +1 skips the filter byte (0)
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
    // PNG greyscale: 0 = black, 1 = white — invert our 1 = black modules.
    for (var y = 0; y < height; y++) {
      final start = y * (stride + 1) + 1;
      for (var i = 0; i < stride; i++) {
        raw[start + i] = (~raw[start + i]) & 0xFF;
      }
    }
    // Pad bits past the row width must be zero after inversion.
    final padBits = stride * 8 - width;
    if (padBits > 0) {
      final mask = 0xFF << padBits & 0xFF;
      for (var y = 0; y < height; y++) {
        final last = y * (stride + 1) + stride;
        raw[last] &= mask;
      }
    }

    final compressed = const ZLibEncoder().encode(raw, level: 9);
    final out = BytesBuilder()
      ..add(_pngSignature)
      ..add(_chunk('IHDR', _ihdr(width, height)))
      ..add(_chunk('IDAT', Uint8List.fromList(compressed)))
      ..add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }

  static const List<int> _pngSignature = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
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
      (ByteData(4)..setUint32(0, Crc32.checksum(crcInput.toBytes())))
          .buffer
          .asUint8List(),
    );
    return out.toBytes();
  }
}
