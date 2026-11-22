import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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

  group('arithmetic grid layout (regression)', () {
    String gridSha256(List<Uint8List> grid) {
      final blob = BytesBuilder()
        ..add((ByteData(4)..setUint32(0, grid.length)).buffer.asUint8List());
      for (final row in grid) {
        blob.add(row);
      }
      return sha256.convert(blob.toBytes()).toString();
    }

    Uint8List fixedBytes(int length, int seed) {
      final rng = Random(seed);
      return Uint8List.fromList(
        List<int>.generate(length, (_) => rng.nextInt(256)),
      );
    }

    test('buildGrid bytes match the set-based golden hashes', () {
      // Goldens captured from the original set-based implementation
      // before the arithmetic rewrite — the grid bytes must be
      // identical, so the format is unchanged.
      final cases = <(Uint8List, String)>[
        (
          Uint8List(0),
          '4346a5218bce26ccd1e7ba20d3b6c54e9b839f0db0aa3902c5131b5ab8b26f4c'
        ),
        (
          Uint8List.fromList([0xA5]),
          '9b128be6899015cd653d0c40f9d98b09563ae41dd935ec31d3823def73441b00'
        ),
        (
          fixedBytes(1024, 7),
          '5846bcdd88c75a4b34e052368117f478df95d616dfdfe54a83891f059b7f9eea'
        ),
        (
          fixedBytes(16 * 1024, 8),
          '0c724716018365e0d55b3489322357b692494feef3904dd7b19a785cd1956e02'
        ),
        (
          fixedBytes(64 * 1024, 9),
          '3c9f645e27c028f1befe4f8ed5307fce0247562c9829d51e14ce86a2058114f2'
        ),
      ];
      for (final (payload, golden) in cases) {
        final grid = CodeGrid.buildGrid(payload);
        expect(gridSha256(grid), golden);
        expect(CodeGrid.parseGrid(grid), payload);
      }
    });

    test('barcode rows match the golden hash', () {
      final rows = CodeGrid.buildBarcodeRows(fixedBytes(64 * 1024, 9));
      final blob = BytesBuilder()
        ..add((ByteData(4)..setUint32(0, rows.length)).buffer.asUint8List());
      for (final row in rows) {
        blob.add(row);
      }
      expect(
        sha256.convert(blob.toBytes()).toString(),
        '880d916fdf2b8686b07990fa1166a12dcdee0082644a751914cc99aeb22892f3',
      );
    });

    test('gridCapacityBits matches an independent set count', () {
      int setCapacity(int n) {
        final cells = <(int, int)>{};
        for (final (r0, c0) in [(0, 0), (0, n - 8), (n - 8, 0)]) {
          for (var r = r0; r < r0 + 8; r++) {
            for (var c = c0; c < c0 + 8; c++) {
              cells.add((r, c));
            }
          }
        }
        for (var i = 8; i < n - 8; i++) {
          cells.add((6, i));
          cells.add((i, 6));
        }
        final (r0, c0, side) = CodeGrid.centreTile(n);
        for (var r = r0; r < r0 + side; r++) {
          for (var c = c0; c < c0 + side; c++) {
            cells.add((r, c));
          }
        }
        return n * n - cells.length;
      }

      for (final n in [32, 36, 64, 100, 256, 752]) {
        expect(CodeGrid.gridCapacityBits(n), setCapacity(n));
      }
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
