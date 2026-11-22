import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/code_grid.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/frame.dart';
import 'package:middle_out/codec/logo_tile.dart';
import 'package:middle_out/services/pdf_frame_extractor.dart';

/// Builds a minimal PDF holding one 1-bit image XObject.
///
/// The extractor scans for image XObjects and never touches the xref
/// table, so the fixture needs no valid xref — just a dictionary, a
/// `stream` / `endstream` pair, and flate-compressed 1-bit pixels
/// (DeviceGray: bit 0 = black, bit 1 = white).
Uint8List fixturePdf(List<Uint8List> pixels, int width, int height) {
  final stride = (width + 7) ~/ 8;
  final raw = Uint8List(height * stride);
  for (var y = 0; y < height; y++) {
    var current = 0;
    var bits = 0;
    var offset = y * stride;
    for (var x = 0; x < width; x++) {
      final bit = pixels[y][x] == 1 ? 0 : 1; // module black -> bit 0
      current = (current << 1) | bit;
      bits++;
      if (bits == 8) {
        raw[offset++] = current;
        current = 0;
        bits = 0;
      }
    }
    if (bits > 0) raw[offset] = current << (8 - bits);
  }
  final compressed = const ZLibEncoder().encode(raw);
  final header = ascii.encode(
    '%PDF-1.4\n1 0 obj\n<< /Type /XObject /Subtype /Image /Width $width '
    '/Height $height /BitsPerComponent 1 /ColorSpace /DeviceGray '
    '/Filter /FlateDecode /Length ${compressed.length} >>\nstream\n',
  );
  final footer = ascii.encode('\nendstream\nendobj\n');
  final out = BytesBuilder()
    ..add(header)
    ..add(compressed)
    ..add(footer);
  return out.toBytes();
}

/// Builds a minimal PDF holding one 1-bit code image XObject plus the
/// RGB logo tile XObject, as the real writer emits.
Uint8List fixturePdfWithLogo(List<Uint8List> pixels, int width, int height) {
  final codePdf = fixturePdf(pixels, width, height);
  final logoDeflate = const ZLibEncoder().encode(LogoTile.rgb);
  final logo = BytesBuilder()
    ..add(
      ascii.encode(
        '2 0 obj\n<< /Type /XObject /Subtype /Image /Width 64 /Height 64 '
        '/BitsPerComponent 8 /ColorSpace /DeviceRGB '
        '/Filter /FlateDecode /Length ${logoDeflate.length} >>\nstream\n',
      ),
    )
    ..add(logoDeflate)
    ..add(ascii.encode('\nendstream\nendobj\n'));
  return (BytesBuilder()
        ..add(codePdf)
        ..add(logo.toBytes()))
      .toBytes();
}

/// Square grid matrix plus quiet zone, as image pixels (old format and
/// the cover manifest grid).
List<Uint8List> gridPixels(Uint8List frameBytes) {
  final grid = CodeGrid.buildGrid(frameBytes, aspect: 1.0);
  final n = grid.length;
  const quiet = CodeGrid.quietModules;
  final size = n + 2 * quiet;
  final rows = List<Uint8List>.generate(size, (_) => Uint8List(size));
  for (var r = 0; r < n; r++) {
    rows[r + quiet].setAll(quiet, grid[r]);
  }
  return rows;
}

/// Rectangular QR grid matrix, no quiet zone (new full-bleed format).
List<Uint8List> rectGridPixels(Uint8List frameBytes) =>
    CodeGrid.buildGrid(frameBytes);

/// Bar-grid matrix, no quiet zone (new barcode format).
List<Uint8List> barGridPixels(Uint8List frameBytes) =>
    CodeGrid.buildGrid(frameBytes, aspect: CodeGrid.barcodeAspect);

/// Barcode rows as image pixels (barPx 2, row band 24 + gap 4).
List<Uint8List> barcodePixels(Uint8List frameBytes) {
  final rows = CodeGrid.buildBarcodeRows(frameBytes);
  const barPx = 2;
  const rowPx = 24;
  const gapPx = 4;
  const width = CodeGrid.barcodeRowBars * barPx;
  final height = rows.length * (rowPx + gapPx);
  final pixels = List<Uint8List>.generate(height, (_) => Uint8List(width));
  for (var ri = 0; ri < rows.length; ri++) {
    final y0 = ri * (rowPx + gapPx);
    for (var y = y0; y < y0 + rowPx; y++) {
      for (var bi = 0; bi < rows[ri].length; bi++) {
        if (rows[ri][bi] == 1) {
          for (var x = bi * barPx; x < (bi + 1) * barPx; x++) {
            pixels[y][x] = 1;
          }
        }
      }
    }
  }
  return pixels;
}

/// Inverts a pixel matrix (dark-page polarity).
List<Uint8List> invertPixels(List<Uint8List> pixels) => [
      for (final row in pixels)
        Uint8List.fromList([for (final v in row) v ^ 1]),
    ];

void main() {
  group('PdfFrameExtractor', () {
    test('recovers a frame from a rectangular QR image XObject', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — grid mode. '.codeUnits,
      );
      final frame = Encoder.encode(data).frames.first;
      final pixels = rectGridPixels(frame.toBytes());
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.imagesFound, 1);
      expect(extraction.imagesParsed, 1);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.frameIndex, frame.frameIndex);
      expect(recovered.payload, frame.payload);
    });

    test('recovers a frame from a bar-grid image XObject', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — bar-grid mode. '.codeUnits,
      );
      final frame = Encoder.encode(data, barcode: true).frames.first;
      final pixels = barGridPixels(frame.toBytes());
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
      expect(recovered.isBarcode, isTrue);
    });

    test('recovers a frame from a square grid image XObject', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — square grid. '.codeUnits,
      );
      final frame = Encoder.encode(data).frames.first;
      final pixels = gridPixels(frame.toBytes());
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.imagesFound, 1);
      expect(extraction.imagesParsed, 1);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.frameIndex, frame.frameIndex);
      expect(recovered.payload, frame.payload);
    });

    test('recovers a frame from a stacked barcode image XObject', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — barcode mode. '.codeUnits,
      );
      final frame = Encoder.encode(data, barcode: true).frames.first;
      final pixels = barcodePixels(frame.toBytes());
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
      expect(recovered.isBarcode, isTrue);
    });

    test('polarity auto-detect: inverted QR grid still decodes', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — dark grid. '.codeUnits,
      );
      final frame = Encoder.encode(data).frames.first;
      final pixels = invertPixels(rectGridPixels(frame.toBytes()));
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
    });

    test('polarity auto-detect: inverted bar-grid still decodes', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — dark bar-grid. '.codeUnits,
      );
      final frame = Encoder.encode(data, barcode: true).frames.first;
      final pixels = invertPixels(barGridPixels(frame.toBytes()));
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
      expect(recovered.isBarcode, isTrue);
    });

    test('polarity auto-detect: inverted stacked barcode still decodes',
        () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — dark stacked barcode. '.codeUnits,
      );
      final frame = Encoder.encode(data, barcode: true).frames.first;
      final pixels = invertPixels(barcodePixels(frame.toBytes()));
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
      expect(recovered.isBarcode, isTrue);
    });

    test('skips the RGB logo XObject and still recovers the frame', () {
      final data = Uint8List.fromList(
        'Middle Out PDF fixture — logo present. '.codeUnits,
      );
      final frame = Encoder.encode(data).frames.first;
      final pixels = rectGridPixels(frame.toBytes());
      final pdf = fixturePdfWithLogo(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.imagesFound, 2);
      // The logo is never decoded: only the 1-bit code image is parsed.
      expect(extraction.imagesParsed, 1);
      expect(extraction.frames.length, 1);
      final recovered = Frame.fromBytes(extraction.frames.first);
      expect(recovered.payload, frame.payload);
    });

    test('skips the cover manifest grid (text, not a frame)', () {
      final manifest = Uint8List.fromList(
        utf8.encode('File: demo.txt\nSHA-256: abc123'),
      );
      final pixels = gridPixels(manifest);
      final pdf = fixturePdf(pixels, pixels[0].length, pixels.length);
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.imagesFound, 1);
      expect(extraction.frames, isEmpty);
    });

    test('a PDF with no images yields no frames', () {
      final pdf = Uint8List.fromList(
        ascii.encode('%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n'),
      );
      final extraction = PdfFrameExtractor.extract(pdf);
      expect(extraction.imagesFound, 0);
      expect(extraction.frames, isEmpty);
    });
  });
}
