import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/code_grid.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/codec/pdf_writer.dart';
import 'package:middle_out/codec/png_encode.dart';
import 'package:middle_out/services/pdf_frame_extractor.dart';

/// Incompressible bytes: 200 KiB of seeded random data encodes to 1 dense
/// ~200 KiB data frame + 1 parity under the default adaptive rule
/// (dataPageCount: 200 KiB < 15 MiB), enough to exercise the builder.
/// Tests that need several dense pages pass an explicit small
/// `maxPayload` to `Encoder.encode` instead (see 'every code page is
/// dense' below).
Uint8List randomBytes(int length) {
  final random = Random(42);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

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

/// The golden fixtures' original bytes. MUST match what
/// tool/build_golden_fixture.dart encoded (same sentence, same repeats) —
/// if the two drift, the golden tests fail loudly rather than silently.
Uint8List goldenOriginal() {
  final unit = Uint8List.fromList(
    utf8.encode(
      'Middle Out golden fixture \u2014 '
      'old-format PDF. ',
    ),
  );
  final out = BytesBuilder();
  for (var i = 0; i < 600; i++) {
    out.add(unit);
  }
  return out.toBytes();
}

void main() {
  group('new-format PDF round-trip', () {
    test(
      'grid mode: encode -> build -> extract -> decode, byte-identical',
      () async {
        final data = randomBytes(200 * 1024);
        final encoded = Encoder.encode(data);
        final (pdf, stats) = await PdfDocument.build(encoded, 'roundtrip.bin');
        expect(stats.pages, 1 + encoded.frames.length);

        // New format: 1-bit DeviceGray code XObjects plus ONE shared 8-bit
        // RGB logo XObject; no SMask, no nested DecodeParms dict (the
        // extractor's scan requires that). Cover and code pages are ALL
        // landscape — no portrait page anywhere.
        expect(bytesContain(pdf, '/BitsPerComponent 1'), isTrue);
        expect(bytesContain(pdf, '/ColorSpace /DeviceGray'), isTrue);
        expect(bytesContain(pdf, '/BitsPerComponent 8'), isTrue);
        expect(bytesContain(pdf, '/ColorSpace /DeviceRGB'), isTrue);
        expect(bytesContain(pdf, '/SMask'), isFalse);
        expect(bytesContain(pdf, '/DecodeParms'), isFalse);
        expect(bytesContain(pdf, '/MediaBox [0 0 595.28 841.89]'), isFalse);
        expect(bytesContain(pdf, '/MediaBox [0 0 841.89 595.28]'), isTrue);

        final extraction = PdfFrameExtractor.extract(pdf);
        expect(extraction.frames.length, encoded.frames.length);
        final decoded = Decoder.decode(extraction.frames);
        expect(decoded, data);
        expect(
          sha256.convert(decoded).toString(),
          sha256.convert(data).toString(),
        );
      },
    );

    test(
      'barcode mode: encode -> build -> extract -> decode, byte-identical',
      () async {
        final data = randomBytes(200 * 1024);
        final encoded = Encoder.encode(data, barcode: true);
        final (pdf, stats) = await PdfDocument.build(encoded, 'roundtrip.bin');
        expect(stats.pages, 1 + encoded.frames.length);
        expect(bytesContain(pdf, '/BitsPerComponent 1'), isTrue);
        // The logo tile is the only RGB image.
        expect(bytesContain(pdf, '/ColorSpace /DeviceRGB'), isTrue);
        expect(bytesContain(pdf, '/SMask'), isFalse);
        expect(bytesContain(pdf, '/DecodeParms'), isFalse);
        expect(bytesContain(pdf, '/MediaBox [0 0 841.89 595.28]'), isTrue);

        final extraction = PdfFrameExtractor.extract(pdf);
        expect(extraction.frames.length, encoded.frames.length);
        final decoded = Decoder.decode(extraction.frames);
        expect(decoded, data);
        expect(
          sha256.convert(decoded).toString(),
          sha256.convert(data).toString(),
        );
      },
    );

    test(
      'dark grid mode: inverted pages extract and decode byte-identical',
      () async {
        final data = randomBytes(200 * 1024);
        final encoded = Encoder.encode(data);
        final (pdf, stats) = await PdfDocument.build(
          encoded,
          'roundtrip.bin',
          dark: true,
        );
        expect(stats.pages, 1 + encoded.frames.length);

        final extraction = PdfFrameExtractor.extract(pdf);
        expect(extraction.frames.length, encoded.frames.length);
        final decoded = Decoder.decode(extraction.frames);
        expect(decoded, data);
        expect(
          sha256.convert(decoded).toString(),
          sha256.convert(data).toString(),
        );
      },
    );

    test(
      'dark barcode mode: inverted pages extract and decode byte-identical',
      () async {
        final data = randomBytes(200 * 1024);
        final encoded = Encoder.encode(data, barcode: true);
        final (pdf, stats) = await PdfDocument.build(
          encoded,
          'roundtrip.bin',
          dark: true,
        );
        expect(stats.pages, 1 + encoded.frames.length);

        final extraction = PdfFrameExtractor.extract(pdf);
        expect(extraction.frames.length, encoded.frames.length);
        final decoded = Decoder.decode(extraction.frames);
        expect(decoded, data);
        expect(
          sha256.convert(decoded).toString(),
          sha256.convert(data).toString(),
        );
      },
    );

    test('light and dark PDFs of the same encode carry the same frames',
        () async {
      final data = randomBytes(100 * 1024);
      final encoded = Encoder.encode(data);
      final (lightPdf, _) = await PdfDocument.build(encoded, 'same.bin');
      final (darkPdf, _) = await PdfDocument.build(
        encoded,
        'same.bin',
        dark: true,
      );
      // Same page count, different bytes (inverted pixels + bg rects).
      expect(lightPdf.length, isNot(darkPdf.length));
      final light = PdfFrameExtractor.extract(lightPdf);
      final dark = PdfFrameExtractor.extract(darkPdf);
      expect(dark.frames.length, light.frames.length);
      expect(dark.frames.length, encoded.frames.length);
      for (var i = 0; i < light.frames.length; i++) {
        expect(dark.frames[i], light.frames[i]);
      }
    });

    // 2-minute timeout: the encrypted path (PBKDF2 + ChaCha + PDF build)
    // exceeds the 30s default under DDC, the dev compiler used by
    // `flutter test --platform chrome`. It is fast on the VM and on the
    // release site; this is test-runner slowness, not a product issue.
    test('encrypted encode round-trips through the new PDF', () async {
      final data = randomBytes(100 * 1024);
      final encoded = Encoder.encode(data, passphrase: 'test-passphrase');
      final (pdf, _) = await PdfDocument.build(encoded, 'secret.bin');
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, encoded.frames.length);
      final decoded = Decoder.decode(
        extraction.frames,
        passphrase: 'test-passphrase',
      );
      expect(decoded, data);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('cover-stripped PDF still decodes (decoder never reads the cover)',
        () async {
      // A PDF built with NO cover page at all — frame pages only —
      // decodes identically, proving no decode input comes from the
      // cover (the old manifest text is gone for good).
      final data = randomBytes(100 * 1024);
      final encoded = Encoder.encode(data);
      final writer = RawPdfWriter();
      for (final frame in encoded.frames) {
        final grid = CodeGrid.buildFrameGrid(
          frame.toBytes(),
          barcode: encoded.barcode,
        );
        writer.addFramePage(
          imageWidth: grid[0].length,
          imageHeight: grid.length,
          imageDeflate: PngEncode.deflate1Bit(
            grid,
            grid[0].length,
            grid.length,
          ),
        );
      }
      final pdf = writer.build();
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, encoded.frames.length);
      expect(Decoder.decode(extraction.frames), data);
    });

    test('every code page is dense (equal split, no sparse pages)', () async {
      final data = randomBytes(200 * 1024);
      // Explicit 64 KiB unit forces 4 dense pages: the default adaptive
      // rule gives 1 page for 200 KiB, which cannot prove "no sparse
      // pages" across several pages.
      final encoded = Encoder.encode(data, maxPayload: 64 * 1024);
      // 4 equal data frames + 2 parity: every data frame carries the
      // full chunk size, so no page renders a tiny grid.
      final dataFrames = [
        for (final f in encoded.frames)
          if (f.isData) f,
      ];
      expect(dataFrames.length, 4);
      final chunkSize = (encoded.stats.compressedSize + 3) ~/ 4;
      for (final frame in dataFrames) {
        expect(frame.payload.length, chunkSize);
      }
      final (pdf, stats) = await PdfDocument.build(encoded, 'dense.bin');
      expect(stats.pages, 1 + encoded.frames.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, encoded.frames.length);
      expect(Decoder.decode(extraction.frames), data);
    });
  });

  group('old-format golden PDFs still decode', () {
    // Chrome-only skip: the golden fixture is read via dart:io File,
    // which does not exist on web. The golden still runs on the VM
    // (CI + local), and the decode path itself is covered in Chrome by
    // the extractor tests. (An HTTP fixture loader, the FRAME POLICE
    // pattern, would restore Chrome coverage here.)
    test('grid golden (8-bit RGB XObjects from the old builder)', () {
      final file = File('test/fixtures/old_format_grid.pdf');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'run tool/build_golden_fixture.dart BEFORE applying the '
            'pdf-save port to generate the golden fixtures',
      );
      final pdf = file.readAsBytesSync();
      // Prove this is genuinely old-format: 8-bit RGB + SMask.
      expect(bytesContain(pdf, '/BitsPerComponent 8'), isTrue);
      expect(bytesContain(pdf, '/DeviceRGB'), isTrue);

      final data = goldenOriginal();
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames, isNotEmpty);
      final decoded = Decoder.decode(extraction.frames);
      expect(decoded, data);
      expect(
        sha256.convert(decoded).toString(),
        sha256.convert(data).toString(),
      );
    }, onPlatform: const {
      'chrome': Skip(
        'golden fixture is read via dart:io File, which does not exist '
        'on web; the golden still runs on the VM',
      ),
    });

    // Chrome-only skip: same dart:io fixture read as the grid golden.
    test('barcode golden (8-bit RGB XObjects from the old builder)', () {
      final file = File('test/fixtures/old_format_barcode.pdf');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'run tool/build_golden_fixture.dart BEFORE applying the '
            'pdf-save port to generate the golden fixtures',
      );
      final pdf = file.readAsBytesSync();
      expect(bytesContain(pdf, '/BitsPerComponent 8'), isTrue);
      expect(bytesContain(pdf, '/DeviceRGB'), isTrue);

      final data = goldenOriginal();
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames, isNotEmpty);
      final decoded = Decoder.decode(extraction.frames);
      expect(decoded, data);
      expect(
        sha256.convert(decoded).toString(),
        sha256.convert(data).toString(),
      );
    }, onPlatform: const {
      'chrome': Skip(
        'golden fixture is read via dart:io File, which does not exist '
        'on web; the golden still runs on the VM',
      ),
    });
  });
}
