import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/cover_qr.dart';

void main() {
  group('CoverQr', () {
    test('const unpacks to 106 bytes (29x29 modules, MSB-first)', () {
      expect(CoverQr.bytes.length, 106);
      // The packed bytes are pinned: a transcription slip in the base64
      // const changes this hash.
      expect(
        sha256.convert(CoverQr.bytes).toString(),
        '53b098d476f08e12a9875be29d734a3a6700e99a20c6a2220ddf5000f2467a1a',
      );
    });

    test('modules unpack to a 29x29 matrix', () {
      final modules = CoverQr.modules;
      expect(modules.length, CoverQr.size);
      for (final row in modules) {
        expect(row.length, CoverQr.size);
        for (final module in row) {
          expect(module, anyOf(0, 1));
        }
      }
    });

    test('all three finder patterns are present', () {
      final modules = CoverQr.modules;
      // A finder is 7x7: outer ring black, middle ring white, 3x3 core.
      void checkFinder(int r0, int c0) {
        for (var dr = 0; dr < 7; dr++) {
          for (var dc = 0; dc < 7; dc++) {
            final onRing = dr == 0 || dr == 6 || dc == 0 || dc == 6;
            final inCore = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
            expect(
              modules[r0 + dr][c0 + dc],
              (onRing || inCore) ? 1 : 0,
              reason: 'finder at ($r0, $c0), cell ($dr, $dc)',
            );
          }
        }
      }

      checkFinder(0, 0); // top-left
      checkFinder(0, CoverQr.size - 7); // top-right
      checkFinder(CoverQr.size - 7, 0); // bottom-left
    });

    test('timing row and column alternate', () {
      final modules = CoverQr.modules;
      // Timing row 6 and column 6 alternate 1, 0, 1, 0… between the
      // finders — a second structural check on the unpacking.
      for (var i = 8; i < CoverQr.size - 8; i++) {
        expect(modules[6][i], i % 2 == 0 ? 1 : 0);
        expect(modules[i][6], i % 2 == 0 ? 1 : 0);
      }
    });

    test('url is the Middle Out site', () {
      expect(CoverQr.url, 'https://mr-vishwet.github.io/middle-out/');
    });
  });
}
