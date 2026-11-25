import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/code_grid.dart';
import 'package:middle_out/codec/png_encode.dart';

Uint8List fixedBytes(int length, int seed) {
  final rng = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

void main() {
  group('Middle Out Code grid (rectangular)', () {
    test('build -> parse round-trip', () {
      final raw = fixedBytes(5000, 3);
      final grid = CodeGrid.buildGrid(raw);
      // Rectangular, QR page aspect, height steps of 2 from 32.
      expect(grid[0].length / grid.length, closeTo(CodeGrid.qrAspect, 0.02));
      expect(grid.length % 2, 0);
      expect(CodeGrid.parseGrid(grid), raw);
    });

    test('centre tile stays clear for the logo', () {
      final grid = CodeGrid.buildGrid(Uint8List(100));
      final w = grid[0].length;
      final h = grid.length;
      final (r0, c0, tileW, tileH) = CodeGrid.centreTile(w, h);
      for (var r = r0; r < r0 + tileH; r++) {
        for (var c = c0; c < c0 + tileW; c++) {
          expect(grid[r][c], 0, reason: 'centre tile must stay white');
        }
      }
    });

    test('centre tile rule: square as drawn, old rule for square grids', () {
      // QR full frame: 156x156, unchanged from the old rule.
      expect(CodeGrid.centreTile(883, 624), (234, 363, 156, 156));
      // Bar full frame (old size): 308x77 modules = 148.8x148.8 pt.
      expect(CodeGrid.centreTile(1742, 308), (115, 717, 308, 77));
      // Bar full frame (new size, after the capacity change).
      expect(CodeGrid.centreTile(1776, 314), (117, 731, 314, 79));
      // Minimum grids.
      expect(CodeGrid.centreTile(45, 32), (12, 18, 8, 8));
      expect(CodeGrid.centreTile(181, 32), (12, 74, 32, 8));
      // Square grids keep the old rule: side = max(8, n ~/ 4).
      expect(CodeGrid.centreTile(750, 750), (281, 281, 187, 187));
      expect(CodeGrid.centreTile(32, 32), (12, 12, 8, 8));
    });

    test('centre tile is square as drawn on the page', () {
      // The tile's drawn width and height (in points on the 841.89 x
      // 595.28 landscape page) agree to within one module — the tile
      // rounds to whole modules, so exact equality is impossible, but
      // the old rule's 4:1 bar-grid pillar (37pt wide, 149pt tall) is
      // gone: both formats now draw a ~149pt square.
      for (final (w, h) in [
        (883, 624),
        (444, 314),
        (113, 80),
        (45, 32),
        (1776, 314),
        (1742, 308),
        (871, 154),
        (181, 32),
      ]) {
        final (_, _, tileW, tileH) = CodeGrid.centreTile(w, h);
        final drawnW = tileW / w * 841.89;
        final drawnH = tileH / h * 595.28;
        expect(
          (drawnW - drawnH).abs(),
          lessThan(2.0),
          reason: '$w x $h tile draws ${drawnW}pt x ${drawnH}pt',
        );
        expect(drawnW, closeTo(148.82, 1.0));
      }
    });

    test('bar-grid centre tile never overlaps finders or timing', () {
      // The tile must sit strictly inside the finder-free interior:
      // below the top finders / timing row, above the bottom finder,
      // right of the left finders / timing column, left of the top-right
      // finder. Checked for the full bar frames and every bar-aspect
      // size from h = 32 to 314.
      bool clear(int w, int h) {
        final (r0, c0, tileW, tileH) = CodeGrid.centreTile(w, h);
        return r0 >= 8 &&
            r0 + tileH <= h - 8 &&
            c0 >= 8 &&
            c0 + tileW <= w - 8;
      }

      expect(clear(1776, 314), isTrue);
      expect(clear(1742, 308), isTrue);
      // Full-frame tile rects, spelled out: far from corners/row 6/col 6.
      expect(CodeGrid.centreTile(1776, 314), (117, 731, 314, 79));
      for (var h = 32; h <= 314; h += 2) {
        final w = (h * CodeGrid.barcodeAspect).round();
        expect(clear(w, h), isTrue, reason: 'overlap at $w x $h');
      }
      for (var h = 32; h <= 624; h += 2) {
        final w = (h * CodeGrid.qrAspect).round();
        expect(clear(w, h), isTrue, reason: 'overlap at $w x $h');
      }
    });

    test('grid grows with payload', () {
      final small = CodeGrid.buildGrid(Uint8List(10));
      final large = CodeGrid.buildGrid(Uint8List(5000));
      expect(large.length, greaterThan(small.length));
      expect(large[0].length, greaterThan(small[0].length));
      expect(small.length % 2, 0);
      expect(large.length % 2, 0);
    });

    test('bar-grid round-trip, full 64 KiB frame', () {
      final raw = fixedBytes(64 * 1024, 9);
      final grid = CodeGrid.buildGrid(raw, aspect: CodeGrid.barcodeAspect);
      expect(
        grid[0].length / grid.length,
        closeTo(CodeGrid.barcodeAspect, 0.02),
      );
      expect(CodeGrid.parseGrid(grid), raw);
    });

    test('bar-grid is the same layout as the QR grid, stretched', () {
      // Same payload, same bit order: the bar-grid's placeable cells
      // read back the same bytes, and its reserved cells are the same
      // patterns (finders/timing/centre) at the stretched positions.
      final raw = fixedBytes(1000, 11);
      final qr = CodeGrid.buildGrid(raw);
      final bar = CodeGrid.buildGrid(raw, aspect: CodeGrid.barcodeAspect);
      expect(CodeGrid.parseGrid(qr), raw);
      expect(CodeGrid.parseGrid(bar), raw);
      // Both have black top-left finder corners.
      expect(qr[0][0], 1);
      expect(bar[0][0], 1);
      // Both have a white centre tile.
      final (qrR0, qrC0, qrTileW, qrTileH) =
          CodeGrid.centreTile(qr[0].length, qr.length);
      final (barR0, barC0, barTileW, barTileH) =
          CodeGrid.centreTile(bar[0].length, bar.length);
      expect(qr[qrR0][qrC0], 0);
      expect(bar[barR0][barC0], 0);
      expect(qr[qrR0 + qrTileH - 1][qrC0 + qrTileW - 1], 0);
      expect(bar[barR0 + barTileH - 1][barC0 + barTileW - 1], 0);
    });

    test('old square grids still parse', () {
      // Square grids (aspect 1.0, the old format) parse through the
      // same rectangular code path.
      for (final size in [0, 1, 1024, 16 * 1024, 64 * 1024]) {
        final raw = fixedBytes(size, 13);
        final grid = CodeGrid.buildGrid(raw, aspect: 1.0);
        expect(grid[0].length, grid.length, reason: 'must be square');
        expect(CodeGrid.parseGrid(grid), raw);
      }
    });

    test('chooseGridSize honours the aspect and the minimum size', () {
      final (w, h) = CodeGrid.chooseGridSize(0);
      expect(w, greaterThanOrEqualTo(CodeGrid.minSize));
      expect(h, CodeGrid.minSize);
      final (bw, bh) = CodeGrid.chooseGridSize(
        0,
        aspect: CodeGrid.barcodeAspect,
      );
      expect(bw / bh, closeTo(CodeGrid.barcodeAspect, 0.02));
      // A full frame needs the big grid in both aspects. The bar-grid
      // grew (1742x308 -> 1776x314) because the square-as-drawn centre
      // tile reserves 17,787 more cells than the old square-in-modules
      // tile; the QR grid is unchanged.
      final (fw, fh) = CodeGrid.chooseGridSize(64 * 1024);
      expect((fw, fh), (883, 624));
      final (fbw, fbh) = CodeGrid.chooseGridSize(
        64 * 1024,
        aspect: CodeGrid.barcodeAspect,
      );
      expect((fbw, fbh), (1776, 314));
    });

    test('chooseGridSize sizes big equal-split frames (cap 131072)', () {
      // A 5 MB frame needs h ~ 5,600; a 50 MB frame h ~ 16,800; a
      // 10.5 MB frame (the densest page of a 20 MB encode) h ~ 7,880
      // and a 77 MB frame (the densest page of a 1 GB encode)
      // h ~ 21,300 — all far below the cap. Sizing is pure arithmetic,
      // so these checks cost nothing.
      final (_, h5) = CodeGrid.chooseGridSize(5 * 1024 * 1024);
      expect(h5, greaterThan(5000));
      expect(h5, lessThan(6000));
      final (_, h50) = CodeGrid.chooseGridSize(50 * 1024 * 1024);
      expect(h50, greaterThan(15000));
      expect(h50, lessThan(19000));
      expect(h50, lessThanOrEqualTo(CodeGrid.maxHeight));
      // Exact dims for the dense pages the adaptive rule produces
      // (frame bytes = chunk + 100-byte header + 4-byte CRC).
      expect(CodeGrid.chooseGridSize(11010048), (11419, 8074));
      expect(CodeGrid.chooseGridSize(10485869), (11144, 7880));
      expect(CodeGrid.chooseGridSize(76695949), (30133, 21306));
      // A 358 MB frame (the densest page of a 10 GB encode) needs
      // h ~ 46,000 — over the old 32,768 cap, under the new one.
      final (w358, h358) = CodeGrid.chooseGridSize(357914046);
      expect((w358, h358), (65093, 46026));
      expect(h358, lessThanOrEqualTo(CodeGrid.maxHeight));
    });

    test('chooseGridSize throws past the cap', () {
      // A 4 GB frame needs more than the 131,072-row cap allows
      // (~2.9 GB at QR aspect).
      expect(
        () => CodeGrid.chooseGridSize(4 * 1024 * 1024 * 1024),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('streaming packGrid', () {
    test('packGrid bits equal buildGrid bits (QR + barcode, light + dark)',
        () {
      // packGrid is the single bit-layout implementation; buildGrid
      // unpacks it. If the two ever disagree, the grid layout has two
      // sources of truth — fail loudly. The deflate bytes must agree
      // too, in both polarities, or the PDF builder (packGrid path)
      // and the previews (buildGrid path) would render different pages.
      final random = Random(99);
      for (final size in [0, 10, 100, 1024, 64 * 1024, 200 * 1024]) {
        final payload = Uint8List.fromList(
          List<int>.generate(size, (_) => random.nextInt(256)),
        );
        for (final aspect in [
          CodeGrid.qrAspect,
          CodeGrid.barcodeAspect,
          1.0,
        ]) {
          final packed = CodeGrid.packGrid(payload, aspect: aspect);
          final grid = CodeGrid.buildGrid(payload, aspect: aspect);
          expect(packed.width, grid[0].length);
          expect(packed.height, grid.length);
          final stride = (packed.width + 7) ~/ 8;
          for (var r = 0; r < packed.height; r++) {
            final row = Uint8List(packed.width);
            for (var c = 0; c < packed.width; c++) {
              row[c] =
                  (packed.bytes[r * stride + c ~/ 8] >> (7 - c % 8)) & 1;
            }
            expect(row, grid[r]);
          }
          for (final dark in [false, true]) {
            expect(
              PngEncode.deflatePacked(
                packed.bytes,
                packed.width,
                packed.height,
                dark: dark,
              ),
              PngEncode.deflate1Bit(
                grid,
                packed.width,
                packed.height,
                dark: dark,
              ),
            );
          }
        }
      }
    });
  });

  group('arithmetic grid layout (regression)', () {
    String gridSha256(List<Uint8List> grid) {
      final blob = BytesBuilder()
        ..add((ByteData(4)..setUint32(0, grid[0].length)).buffer.asUint8List())
        ..add((ByteData(4)..setUint32(0, grid.length)).buffer.asUint8List());
      for (final row in grid) {
        blob.add(row);
      }
      return sha256.convert(blob.toBytes()).toString();
    }

    // The OLD hash function (side length only), for comparing square
    // grids against the pre-rectangle goldens.
    String oldGridSha256(List<Uint8List> grid) {
      final blob = BytesBuilder()
        ..add((ByteData(4)..setUint32(0, grid.length)).buffer.asUint8List());
      for (final row in grid) {
        blob.add(row);
      }
      return sha256.convert(blob.toBytes()).toString();
    }

    test('rectangular grid bytes match the golden hashes', () {
      // Only the 16 KiB case moved under the square-as-drawn tile rule
      // (444x314 tile 78x78 -> 78x79: half-up rounding of h/4 = 78.5);
      // the other four are unchanged from the old rule.
      final cases = <(Uint8List, String)>[
        (
          Uint8List(0),
          '7d967d847091000748fa7e9251ea229a2857719a07b2115c49abfcea1c1f8bf4'
        ),
        (
          Uint8List.fromList([0xA5]),
          'ababfc945b4f9c10fdfcd0a478eac7476ef70e3132b4c7d846e15163c3bed1fa'
        ),
        (
          fixedBytes(1024, 7),
          '703e7d97aa569725e265b66e997474fb13c4b038f27f9444d4dc66d2fc709bc8'
        ),
        (
          fixedBytes(16 * 1024, 8),
          'be0585f018e6faddcd9de148fff517661632af72f063e4d4397ccef8dba7c5c3'
        ),
        (
          fixedBytes(64 * 1024, 9),
          '8fe8a0a235b11d3df1a934e48e4b47b9f31d1c2f60134874a4e2debb64913ceb'
        ),
      ];
      for (final (payload, golden) in cases) {
        final grid = CodeGrid.buildGrid(payload);
        expect(gridSha256(grid), golden);
        expect(CodeGrid.parseGrid(grid), payload);
      }
    });

    test('bar-grid bytes match the golden hashes', () {
      // The empty case is unchanged (its 32 bits never reach the tile);
      // the 64 KiB case moved with the new tile rule and the bigger grid
      // (1776x314).
      final cases = <(Uint8List, String)>[
        (
          Uint8List(0),
          '84031c448d78027f09021adbd871834e1d6daf3cb082629c9c5487812c00da90'
        ),
        (
          fixedBytes(64 * 1024, 9),
          'dc1eaec80e4fb1e69384f9fff47438eaf6983b9ecc2166a69a3d705ff7e34613'
        ),
      ];
      for (final (payload, golden) in cases) {
        final grid =
            CodeGrid.buildGrid(payload, aspect: CodeGrid.barcodeAspect);
        expect(gridSha256(grid), golden);
        expect(CodeGrid.parseGrid(grid), payload);
      }
    });

    test('square grids match the old set-based golden hashes', () {
      // The square layout rules are unchanged by the rectangular
      // generalisation, so square grids built at aspect 1.0 must be
      // byte-identical to the old square builder wherever the old
      // step-4 sizing picked the same size. The 64 KiB case differs
      // only in size: step-2 sizing picks 750x750 where the old step-4
      // sizing picked 752x752 (same layout rules, tighter fit).
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
          '38e4befbb58889734184dde26115ec45408d04eef788cc8694e381f6c4de7b57'
        ),
      ];
      for (final (payload, golden) in cases) {
        final grid = CodeGrid.buildGrid(payload, aspect: 1.0);
        expect(oldGridSha256(grid), golden);
        expect(CodeGrid.parseGrid(grid), payload);
      }
      expect(
        CodeGrid.buildGrid(fixedBytes(64 * 1024, 9), aspect: 1.0).length,
        750,
      );
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
      // The set counts the UNION of the reserved regions; the formula
      // subtracts their SUM. Equality proves the regions never overlap
      // for w, h >= 32 — the fact the arithmetic capacity rests on.
      int setCapacity(int w, int h) {
        final cells = <(int, int)>{};
        for (final (r0, c0) in [(0, 0), (0, w - 8), (h - 8, 0)]) {
          for (var r = r0; r < r0 + 8; r++) {
            for (var c = c0; c < c0 + 8; c++) {
              cells.add((r, c));
            }
          }
        }
        for (var i = 8; i < w - 8; i++) {
          cells.add((6, i));
        }
        for (var i = 8; i < h - 8; i++) {
          cells.add((i, 6));
        }
        final (r0, c0, tileW, tileH) = CodeGrid.centreTile(w, h);
        for (var r = r0; r < r0 + tileH; r++) {
          for (var c = c0; c < c0 + tileW; c++) {
            cells.add((r, c));
          }
        }
        return w * h - cells.length;
      }

      final sizes = <(int, int)>[
        (32, 32), // minimum square
        (45, 32), // minimum QR grid
        (181, 32), // minimum bar-grid
        (65, 46), // small QR grid
        (113, 80),
        (444, 314),
        (883, 624), // full 64 KiB QR grid
        (226, 40), // small bar-grid
        (871, 154),
        (1742, 308), // old full 64 KiB bar-grid size
        (1776, 314), // full 64 KiB bar-grid
        (750, 750), // full 64 KiB square grid
        (100, 100),
        (256, 256),
      ];
      // Plus a sweep of QR-aspect sizes: every h in 32..120 step 2.
      for (var h = 32; h <= 120; h += 2) {
        final w = (h * CodeGrid.qrAspect).round();
        sizes.add((w, h));
      }
      // Plus a sweep of bar-aspect sizes: every h in 32..120 step 2.
      for (var h = 32; h <= 120; h += 2) {
        final w = (h * CodeGrid.barcodeAspect).round();
        sizes.add((w, h));
      }
      for (final (w, h) in sizes) {
        expect(
          CodeGrid.gridCapacityBits(w, h),
          setCapacity(w, h),
          reason: 'capacity mismatch at $w x $h',
        );
      }
    });
  });

  group('stacked-row barcode (legacy)', () {
    test('build -> parse round-trip', () {
      final raw = fixedBytes(300, 5);
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

    test('full 64 KiB frame round-trips (row index wraps past 256)', () {
      // A full frame needs 1,026 barcode rows; the 8-bit row index wraps
      // at 256, so reassembly must fall back to list order.
      final raw = fixedBytes(64 * 1024, 9);
      final rows = CodeGrid.buildBarcodeRows(raw);
      expect(rows.length, greaterThan(256));
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

    test('deflate1Bit dark inverts the pixel polarity', () {
      // All-black 8x8: light packs to 0x00 bytes (DeviceGray 0 = black),
      // dark packs to 0xFF (DeviceGray 1 = white).
      final rows = List<Uint8List>.generate(
        8,
        (_) => Uint8List.fromList(List<int>.filled(8, 1)),
      );
      final light = const ZLibDecoder().decodeBytes(
        PngEncode.deflate1Bit(rows, 8, 8),
      );
      final dark = const ZLibDecoder().decodeBytes(
        PngEncode.deflate1Bit(rows, 8, 8, dark: true),
      );
      expect(light, List<int>.filled(8, 0x00));
      expect(dark, List<int>.filled(8, 0xFF));
    });
  });
}
