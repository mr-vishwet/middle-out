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
      final writer = RawPdfWriter()
        ..addCoverPage(
          manifestLines: const ['File: demo.bin', 'Frames: 1'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        )
        ..addFramePage(
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
          caption: 'Frame 1 of 1',
        );
      final pdf = writer.build();
      expect(writer.pageCount, 2);

      final text = latin1.decode(pdf);
      expect(text.startsWith('%PDF-1.4\n'), isTrue);
      expect(text.contains('/Type /Catalog'), isTrue);
      expect(text.contains('/Type /Pages'), isTrue);
      expect(text.contains('/Count 2'), isTrue);
      expect(text.contains('/MediaBox [0 0 595.28 841.89]'), isTrue);
      expect(text.trimRight().endsWith('%%EOF'), isTrue);

      // Xref table: every offset must point at its 'N 0 obj' header,
      // and startxref must point at the xref table itself.
      final xrefAt = text.indexOf('\nxref\n');
      expect(xrefAt, greaterThan(0));
      final startxref = int.parse(
        RegExp(r'startxref\s+(\d+)').firstMatch(text)!.group(1)!,
      );
      expect(startxref, xrefAt + 1);
      final lines = text.substring(xrefAt + 1).split('\n');
      expect(lines[0], 'xref');
      expect(lines[1], '0 11'); // 10 objects + free entry 0
      for (var i = 1; i <= 10; i++) {
        final offset = int.parse(lines[2 + i].substring(0, 10));
        expect(
          text.substring(offset, offset + '$i 0 obj'.length),
          '$i 0 obj',
          reason: 'xref entry $i must point at object $i',
        );
      }
    });

    test('image XObjects are 1-bit DeviceGray with no nested dict', () {
      final writer = RawPdfWriter()
        ..addFramePage(
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
          caption: 'Frame 1 of 1',
        );
      final pdf = writer.build();
      // The extractor scans back to the nearest '<<' before 'stream', so
      // a nested DecodeParms dict would hide the image — pin its absence.
      expect(bytesContain(pdf, '/DecodeParms'), isFalse);
      expect(bytesContain(pdf, '/Subtype /Image'), isTrue);
      expect(bytesContain(pdf, '/BitsPerComponent 1'), isTrue);
      expect(bytesContain(pdf, '/ColorSpace /DeviceGray'), isTrue);
      expect(bytesContain(pdf, '/Filter /FlateDecode'), isTrue);
      // No RGB expansion, no alpha mask: the old builder's bloat.
      expect(bytesContain(pdf, '/DeviceRGB'), isFalse);
      expect(bytesContain(pdf, '/SMask'), isFalse);
    });

    test('frame page fits the image in the 520pt box, aspect kept', () {
      // Wide barcode-like image: 1056 x 140 -> 520 wide, ~69 tall.
      final writer = RawPdfWriter()
        ..addFramePage(
          imageWidth: 1056,
          imageHeight: 140,
          imageDeflate: tinyDeflate(),
          caption: 'Frame 1 of 1',
        );
      final pdf = writer.build();
      // Page 1's content stream is object 6.
      final ops = latin1.decode(inflateObjectStream(pdf, 6));
      // q 520 0 0 68.94 x y cm /Im0 Do Q — width 520, height 520*140/1056.
      expect(ops.contains('q 520 0 0 68.94 '), isTrue, reason: ops);
      expect(ops.contains('/Im0 Do'), isTrue);
      expect(ops.contains('(Frame 1 of 1)'), isTrue);
    });

    test('cover page carries title, manifest lines and caption', () {
      final writer = RawPdfWriter()
        ..addCoverPage(
          manifestLines: const ['File: demo.bin', 'SHA-256: abc123'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = latin1.decode(inflateObjectStream(pdf, 6));
      expect(ops.contains('(MIDDLE OUT)'), isTrue);
      expect(ops.contains('(Lossless file, printed as code.)'), isTrue);
      expect(ops.contains('(File: demo.bin)'), isTrue);
      expect(ops.contains('(SHA-256: abc123)'), isTrue);
      expect(
        ops.contains('(Scan with the Middle Out app to verify this file.)'),
        isTrue,
      );
    });

    test('captions escape parens, backslashes and unicode', () {
      final writer = RawPdfWriter()
        ..addFramePage(
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
          caption: 'Frame (1) of 2 \\ test \u{1F600} caf\u00e9',
        );
      final pdf = writer.build();
      final ops = inflateObjectStream(pdf, 6);
      final text = latin1.decode(ops);
      expect(
        text.contains('Frame \\(1\\) of 2 \\\\ test ? café'),
        isTrue,
        reason: text,
      );
    });

    test('em-dash maps to its WinAnsi byte, not a question mark', () {
      final writer = RawPdfWriter()
        ..addCoverPage(
          manifestLines: const ['Decode with the app \u2014 scan in order.'],
          imageWidth: 8,
          imageHeight: 8,
          imageDeflate: tinyDeflate(),
        );
      final pdf = writer.build();
      final ops = inflateObjectStream(pdf, 6);
      // U+2014 em-dash -> WinAnsi 0x97.
      expect(ops.contains(0x97), isTrue);
      expect(
        latin1.decode(ops).contains('Decode with the app ? scan in order.'),
        isFalse,
      );
    });
  });
}
