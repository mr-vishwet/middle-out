import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/code_grid.dart';
import 'package:middle_out/codec/png_encode.dart';

void main() {
  group('Middle Out Code grid', () {
    test('build -> parse round-trip', () {
      final random = Random(3);
      final raw = Uint8List.fromList(
        List<int>.generate(5000, (_) => random.nextInt(256)),
      );
      expect(CodeGrid.parseGrid(CodeGrid.buildGrid(raw)), raw);
    });

    test('centre tile stays clear for the logo', () {
      final grid = CodeGrid.buildGrid(Uint8List(100));
      final n = grid.length;
      final (r0, c0, side) = CodeGrid.centreTile(n);
      for (var r = r0; r < r0 + side; r++) {
        for (var c = c0; c < c0 + side; c++) {
          expect(grid[r][c], 0, reason: 'centre tile must stay white');
        }
      }
    });

    test('grid grows with payload', () {
      final small = CodeGrid.buildGrid(Uint8List(10));
      final large = CodeGrid.buildGrid(Uint8List(5000));
      expect(large.length, greaterThan(small.length));
      expect(small.length % 4, 0);
      expect(large.length % 4, 0);
    });
  });

  group('stacked-row barcode', () {
    test('build -> parse round-trip', () {
      final random = Random(5);
      final raw = Uint8List.fromList(
        List<int>.generate(300, (_) => random.nextInt(256)),
      );
      expect(
        CodeGrid.parseBarcodeRows(CodeGrid.buildBarcodeRows(raw)),
        raw,
      );
    });

    test('rows reassemble out of order', () {
      final raw = Uint8List.fromList(List<int>.generate(300, (i) => i % 256));
      final rows = CodeGrid.buildBarcodeRows(raw).reversed.toList();
      expect(CodeGrid.parseBarcodeRows(rows), raw);
    });
  });

  group('1-bit PNG encoder', () {
    test('produces a valid PNG with the right dimensions', () {
      // 8x8 checkerboard.
      final rows = List<Uint8List>.generate(
        8,
        (r) => Uint8List.fromList(
          List<int>.generate(8, (c) => (r + c) % 2),
        ),
      );
      final png = PngEncode.encode1Bit(rows, 8, 8);
      // PNG signature.
      expect(
        png.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      // IHDR: width 8, height 8, bit depth 1, colour type 0.
      final ihdr = ByteData.sublistView(png, 16, 29);
      expect(ihdr.getUint32(0), 8);
      expect(ihdr.getUint32(4), 8);
      expect(ihdr.getUint8(8), 1);
      expect(ihdr.getUint8(9), 0);
      // IDAT decompresses to 8 scanlines of filter 0 + 1 data byte.
      final idatLength = ByteData.sublistView(png, 33, 37).getUint32(0);
      final idat = png.sublist(41, 41 + idatLength);
      final raw = const ZLibDecoder().decodeBytes(idat);
      expect(raw.length, 8 * 2);
      for (var r = 0; r < 8; r++) {
        expect(raw[r * 2], 0, reason: 'filter byte must be 0');
      }
    });
  });
}
