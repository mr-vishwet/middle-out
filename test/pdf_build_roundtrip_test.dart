import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/services/pdf_frame_extractor.dart';

/// Incompressible bytes: 200 KiB of seeded random data encodes to 4 data
/// frames (64 KiB payload each) + parity, enough to exercise the builder.
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
        // extractor's scan requires that). Cover portrait, code pages
        // landscape.
        expect(bytesContain(pdf, '/BitsPerComponent 1'), isTrue);
        expect(bytesContain(pdf, '/ColorSpace /DeviceGray'), isTrue);
        expect(bytesContain(pdf, '/BitsPerComponent 8'), isTrue);
        expect(bytesContain(pdf, '/ColorSpace /DeviceRGB'), isTrue);
        expect(bytesContain(pdf, '/SMask'), isFalse);
        expect(bytesContain(pdf, '/DecodeParms'), isFalse);
        expect(bytesContain(pdf, '/MediaBox [0 0 595.28 841.89]'), isTrue);
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
    });
  });

  group('old-format golden PDFs still decode', () {
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
    });

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
    });
  });
}
