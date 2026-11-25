import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/pdf_writer.dart';
import 'package:middle_out/codec/png_encode.dart';

/// 8x8 checkerboard deflate (predictor 1), as a stand-in frame image.
Uint8List tinyDeflate() {
  final rows = List<Uint8List>.generate(
    8,
    (r) => Uint8List.fromList(List<int>.generate(8, (c) => (r + c) % 2)),
  );
  return PngEncode.deflate1Bit(rows, 8, 8);
}

/// All-black 64x64 RGB deflate, as a stand-in logo tile.
Uint8List tinyLogoDeflate() =>
    Uint8List.fromList(const ZLibEncoder().encode(Uint8List(64 * 64 * 3)));

bool bytesContain(Uint8List haystack, String needle) {
  final n = Uint8List.fromList(needle.codeUnits);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Extracts object [number]'s stream bytes (between 'stream\n' and
/// '\nendstream') and inflates them (content streams are FlateDecode).
Uint8List inflateObjectStream(Uint8List pdf, int number) {
  final text = latin1.decode(pdf);
  final header = text.indexOf('$number 0 obj');
  expect(header, greaterThanOrEqualTo(0), reason: 'object $number missing');
  final streamAt = text.indexOf('stream\n', header);
  final endAt = text.indexOf('\nendstream', streamAt);
  final stream = Uint8List.sublistView(pdf, streamAt + 7, endAt);
  return Uint8List.fromList(const ZLibDecoder().decodeBytes(stream));
}

void main() {
  group('RawPdfWriter structure', () {
    test('builds a valid minimal PDF: header, catalog, xref, trailer', () {
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addCoverPage(
          detailLines: const ['File: demo.bin', 'Pages: 2'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      expect(writer.pageCount, 2);

      final text = latin1.decode(pdf);
      expect(text.startsWith('%PDF-1.4\n'), isTrue);
      expect(text.contains('/Type /Catalog'), isTrue);
      expect(text.contains('/Type /Pages'), isTrue);
      expect(text.contains('/Count 2'), isTrue);
      // Cover AND code pages are landscape — no portrait page anywhere.
      expect(text.contains('/MediaBox [0 0 595.28 841.89]'), isFalse);
      expect(text.contains('/MediaBox [0 0 841.89 595.28]'), isTrue);
      expect(text.trimRight().endsWith('%%EOF'), isTrue);
      // Both pages reference the shared logo XObject (object 5).
      expect('/Im1 5 0 R'.allMatches(text).length, 2);

      // Xref table: every offset must point at its 'N 0 obj' header,
      // and startxref must point at the xref table itself.
      // Objects: 1 Catalog, 2 Pages, 3-4 fonts, 5 logo, 6-8 cover,
      // 9-11 frame = 11 objects + free entry 0.
      final xrefAt = text.indexOf('\nxref\n');
      expect(xrefAt, greaterThan(0));
      final startxref = int.parse(
        RegExp(r'startxref\s+(\d+)').firstMatch(text)!.group(1)!,
      );
      expect(startxref, xrefAt + 1);
      final lines = text.substring(xrefAt + 1).split('\n');
      expect(lines[0], 'xref');
      expect(lines[1], '0 12');
      for (var i = 1; i <= 11; i++) {
        final offset = int.parse(lines[2 + i].substring(0, 10));
        expect(
          text.substring(offset, offset + '$i 0 obj'.length),
          '$i 0 obj',
          reason: 'xref entry $i must point at object $i',
        );
      }
    });

    test('code image is 1-bit DeviceGray, logo is 8-bit RGB, no nesting', () {
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      // The extractor scans back to the nearest '<<' before 'stream', so
      // a nested DecodeParms dict would hide the image — pin its absence.
      expect(bytesContain(pdf, '/DecodeParms'), isFalse);
      expect(bytesContain(pdf, '/Subtype /Image'), isTrue);
      expect(bytesContain(pdf, '/BitsPerComponent 1'), isTrue);
      expect(bytesContain(pdf, '/ColorSpace /DeviceGray'), isTrue);
      // The logo tile is the only RGB image; no alpha mask anywhere.
      expect(bytesContain(pdf, '/BitsPerComponent 8'), isTrue);
      expect(bytesContain(pdf, '/ColorSpace /DeviceRGB'), isTrue);
      expect(bytesContain(pdf, '/Filter /FlateDecode'), isTrue);
      expect(bytesContain(pdf, '/SMask'), isFalse);
    });

    test('one shared logo XObject serves all frame pages', () {
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final text = latin1.decode(pdf);
      // Exactly one RGB image dict, however many frame pages.
      expect('/ColorSpace /DeviceRGB'.allMatches(text).length, 1);
      // Both frame pages reference the same logo object (5 0 R).
      expect('/Im1 5 0 R'.allMatches(text).length, 3);
    });

    test('frame page draws the code full-bleed, no caption', () {
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      // Page 1's content stream is object 7 (5 logo, 6 page, 7 contents).
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      // q 841.89 0 0 595.28 0 0 cm /Im0 Do Q — the whole landscape page.
      expect(ops.contains('q 841.89 0 0 595.28 0 0 cm /Im0 Do Q'), isTrue);
      // Logo tile drawn, with its rounded-rect clip.
      expect(ops.contains('/Im1 Do'), isTrue);
      expect(ops.contains('W n'), isTrue);
      // No caption text, no 520pt box.
      expect(ops.contains('Tj'), isFalse);
      expect(ops.contains('520'), isFalse);
    });

    test('logo tile sits on the grid centre, square and undistorted', () {
      // 45x32 grid: centre tile side 8 at (row 12, col 18).
      // Tile rect: x 336.76..486.42, y 223.23..372.05; logo square is
      // min(tileW 149.67, tileH 148.82) = 148.82, centred.
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      expect(
        ops.contains('148.82 0 0 148.82 337.18 223.23 cm /Im1 Do'),
        isTrue,
        reason: ops,
      );
    });

    test('bar-grid logo fills the square-as-drawn centre tile', () {
      // 181x32 bar-grid: centre tile 32x8 modules at (row 12, col 74).
      // Tile rect is 148.84pt wide x 148.82pt tall — square as drawn —
      // so the logo is a 148.82pt square filling it, NOT the old 37.21pt
      // square sitting in a tall white pillar.
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 181,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      // x = 74/181*841.89 + (148.84-148.82)/2 = 344.21;
      // tileBottom = 223.23; y = 223.23.
      expect(
        ops.contains('148.82 0 0 148.82 344.21 223.23 cm /Im1 Do'),
        isTrue,
        reason: ops,
      );
    });

    test('dark frame page paints a black background first', () {
      final darkWriter = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
          dark: true,
        );
      final darkOps = latin1.decode(
        inflateObjectStream(darkWriter.build(), 7),
      );
      expect(darkOps.startsWith('0 g 0 0 841.89 595.28 re f'), isTrue);
      expect(darkOps.contains('/Im0 Do'), isTrue);

      final lightWriter = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
      final lightOps = latin1.decode(
        inflateObjectStream(lightWriter.build(), 7),
      );
      expect(lightOps.contains('re f'), isFalse);
    });

    test('cover page carries branding, detail lines, QR and caption', () {
      final writer = RawPdfWriter(logoDeflate: tinyLogoDeflate())
        ..addCoverPage(
          detailLines: const [
            'File: demo.bin',
            'Original size: 1.00 KB',
            'Format: QR-style grid',
            'Theme: Light',
            'Pages: 2',
          ],
          imageWidth: 37,
          imageHeight: 37,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      // Cover content stream is object 7 (5 logo, 6 page, 7 contents).
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      expect(ops.contains('(MIDDLE OUT)'), isTrue);
      expect(ops.contains('(Lossless file, printed as code.)'), isTrue);
      expect(ops.contains('(File: demo.bin)'), isTrue);
      expect(ops.contains('(Original size: 1.00 KB)'), isTrue);
      expect(ops.contains('(Format: QR-style grid)'), isTrue);
      expect(ops.contains('(Theme: Light)'), isTrue);
      expect(ops.contains('(Pages: 2)'), isTrue);
      // No secrets on the cover: no SHA, payload, ratio or frame counts.
      expect(ops.contains('SHA'), isFalse);
      expect(ops.contains('Encoded payload'), isFalse);
      expect(ops.contains('Ratio'), isFalse);
      expect(ops.contains('Frames:'), isFalse);
      expect(ops.contains('(Scan to open the Middle Out app.)'), isTrue);
      // QR image: 180pt square on the right, centred vertically.
      expect(ops.contains('q 180 0 0 180 613.89 207.64 cm /Im0 Do Q'), isTrue);
      // Logo tile top-left, 64pt, with its rounded-rect clip.
      expect(ops.contains('64 0 0 64 48 483.28 cm /Im1 Do'), isTrue);
      expect(ops.contains('W n'), isTrue);
    });

    test('cover without a logo draws no logo tile', () {
      final writer = RawPdfWriter()
        ..addCoverPage(
          detailLines: const ['File: demo.bin'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = latin1.decode(inflateObjectStream(pdf, 6));
      expect(ops.contains('(MIDDLE OUT)'), isTrue);
      expect(ops.contains('/Im1 Do'), isFalse);
    });

    test('detail text escapes parens, backslashes and unicode', () {
      final writer = RawPdfWriter()
        ..addCoverPage(
          detailLines: const [
            'File: (1) test \\ file \u{1F600} caf\u00e9',
          ],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = inflateObjectStream(pdf, 6);
      final text = latin1.decode(ops);
      expect(
        text.contains('File: \\(1\\) test \\\\ file ? café'),
        isTrue,
        reason: text,
      );
    });

    test('em-dash maps to its WinAnsi byte, not a question mark', () {
      final writer = RawPdfWriter()
        ..addCoverPage(
          detailLines: const ['File: report \u2014 final.bin'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = inflateObjectStream(pdf, 6);
      // U+2014 em-dash -> WinAnsi 0x97.
      expect(ops.contains(0x97), isTrue);
      expect(
        latin1.decode(ops).contains('File: report ? final.bin'),
        isFalse,
      );
    });
  });

  group('RawPdfWriter eager mode (streaming binding)', () {
    Uint8List buildDoc({required bool eager}) {
      final writer = eager
          ? RawPdfWriter(
              logoDeflate: tinyLogoDeflate(),
              totalPages: 3,
            )
          : RawPdfWriter(logoDeflate: tinyLogoDeflate());
      writer
        ..addCoverPage(
          detailLines: const ['File: demo.bin', 'Pages: 3'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
          dark: true,
        );
      return writer.build();
    }

    test('eager bytes are identical to lazy bytes', () {
      // The streaming binding must not change a single byte: same
      // front matter, same page objects, same xref.
      expect(buildDoc(eager: true), buildDoc(eager: false));
      expect(buildDoc(eager: true).length, buildDoc(eager: false).length);
    });

    test('eager writer without a logo matches lazy too', () {
      Uint8List buildNoLogo({required bool eager}) {
        final writer = eager
            ? RawPdfWriter(totalPages: 1)
            : RawPdfWriter();
        writer.addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        );
        return writer.build();
      }

      expect(buildNoLogo(eager: true), buildNoLogo(eager: false));
    });

    test('eager writer reports pageCount as pages are added', () {
      final writer = RawPdfWriter(
        logoDeflate: tinyLogoDeflate(),
        totalPages: 2,
      );
      expect(writer.pageCount, 0);
      writer.addCoverPage(
        detailLines: const ['File: demo.bin'],
        imageWidth: 8,
        imageHeight: 8,
        imageDeflate: tinyDeflate(),
      );
      expect(writer.pageCount, 1);
      writer.addFramePage(
        imageWidth: 45,
        imageHeight: 32,
        imageDeflate: tinyDeflate(),
      );
      expect(writer.pageCount, 2);
      expect(writer.build().length, greaterThan(0));
    });

    test('eager writer throws when fewer pages are added than declared',
        () {
      final writer = RawPdfWriter(
        logoDeflate: tinyLogoDeflate(),
        totalPages: 2,
      )..addCoverPage(
          detailLines: const ['File: demo.bin'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      expect(
        () => writer.build(),
        throwsA(isA<StateError>()),
      );
    });

    test('eager writer throws when more pages are added than declared',
        () {
      final writer = RawPdfWriter(
        logoDeflate: tinyLogoDeflate(),
        totalPages: 1,
      )..addCoverPage(
          detailLines: const ['File: demo.bin'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      expect(
        () => writer.addFramePage(
          imageWidth: 45,
          imageHeight: 32,
          imageDeflate: tinyDeflate(),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
