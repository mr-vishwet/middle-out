import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'code_grid.dart';
import 'encoder.dart';
import 'png_encode.dart';

/// Statistics for an assembled encoded PDF.
class PdfStats {
  const PdfStats({required this.pages, required this.sizeBytes});
  final int pages;
  final int sizeBytes;
}

/// Assembles the encoded PDF: 1 cover page + 1 full-page code page per
/// frame, each frame embedded as a 1-bit image XObject.
///
/// The cover carries a small Middle Out Code grid with the decode manifest
/// (file name, sizes, SHA-256, frame count) — scannable by the app. A real
/// ISO QR cover code (readable by any phone camera) is a v0.2 item.
class PdfDocument {
  /// Barcode rendering geometry inside the PDF image (pixels per bar/row).
  static const int barcodeBarPx = 2;
  static const int barcodeRowPx = 24;
  static const int barcodeGapPx = 4;

  /// Builds the PDF bytes for [result] (the encode of [fileName]).
  static Future<(Uint8List, PdfStats)> build(
    EncodeResult result,
    String fileName,
  ) async {
    final doc = pw.Document();
    final stats = result.stats;

    // --- Cover page ---
    final manifest = _manifestText(result, fileName);
    final manifestGrid = CodeGrid.buildGrid(
      Uint8List.fromList(utf8.encode(manifest)),
    );
    final manifestPng = _gridPng(manifestGrid);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(height: 48),
            pw.Text(
              'MIDDLE OUT',
              style: pw.TextStyle(
                fontSize: 34,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Lossless file, printed as code.',
              style: const pw.TextStyle(fontSize: 13),
            ),
            pw.SizedBox(height: 32),
            for (final line in manifest.split('\n'))
              pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 8),
                child: pw.Text(line, style: const pw.TextStyle(fontSize: 11)),
              ),
            pw.SizedBox(height: 24),
            pw.Center(
              child: pw.Image(
                pw.MemoryImage(manifestPng),
                width: 180,
                height: 180,
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Center(
              child: pw.Text(
                'Scan with the Middle Out app to verify this file.',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );

    // --- One full-page code page per frame ---
    for (final frame in result.frames) {
      final raw = frame.toBytes();
      final Uint8List png;
      final double aspect;
      if (result.barcode) {
        final rows = CodeGrid.buildBarcodeRows(raw);
        png = _barcodePng(rows);
        aspect = (CodeGrid.barcodeRowBars * barcodeBarPx) /
            (rows.length * (barcodeRowPx + barcodeGapPx));
      } else {
        png = _gridPng(CodeGrid.buildGrid(raw));
        aspect = 1;
      }
      final kind = frame.isData ? 'DATA' : 'PARITY';
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => pw.Column(
            children: [
              pw.Expanded(
                child: pw.Center(
                  child: pw.Image(
                    pw.MemoryImage(png),
                    width: aspect >= 1 ? 520 : 520 * aspect,
                    height: aspect >= 1 ? 520 / aspect : 520,
                  ),
                ),
              ),
              pw.SizedBox(height: 16),
              pw.Text(
                'Frame ${frame.frameIndex + 1} of ${stats.frameCount}  ·  '
                '$kind  ·  Group ${frame.groupIndex + 1}  ·  '
                '${frame.payload.length} bytes',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(height: 12),
            ],
          ),
        ),
      );
    }

    final bytes = await doc.save();
    return (
      bytes,
      PdfStats(pages: 1 + result.frames.length, sizeBytes: bytes.length),
    );
  }

  static String _manifestText(EncodeResult result, String fileName) {
    final stats = result.stats;
    return [
      'File: $fileName',
      'Original size: ${stats.originalSize} bytes',
      'Encoded payload: ${stats.compressedSize} bytes',
      'Ratio: ${stats.ratio.toStringAsFixed(1)}x',
      'SHA-256: ${stats.sha256Hex}',
      'Frames: ${stats.frameCount} '
          '(${stats.groupCount} group(s) of 6 DATA + 2 PARITY)',
      'Format: ${result.barcode ? 'Barcode' : 'QR-style grid'}',
      'Decode with the Middle Out app — scan the frames in order.',
    ].join('\n');
  }

  /// Grid matrix -> PNG bytes, with a quiet zone of white modules.
  static Uint8List _gridPng(List<Uint8List> grid) {
    final n = grid.length;
    final quiet = CodeGrid.quietModules;
    final size = n + 2 * quiet;
    final rows = List<Uint8List>.generate(size, (_) => Uint8List(size));
    for (var r = 0; r < n; r++) {
      rows[r + quiet].setAll(quiet, grid[r]);
    }
    return PngEncode.encode1Bit(rows, size, size);
  }

  /// Barcode rows -> PNG bytes (bars widened, rows stacked with gaps).
  static Uint8List _barcodePng(List<Uint8List> rows) {
    final width = CodeGrid.barcodeRowBars * barcodeBarPx;
    final height = rows.length * (barcodeRowPx + barcodeGapPx);
    final pixels = List<Uint8List>.generate(height, (_) => Uint8List(width));
    for (var ri = 0; ri < rows.length; ri++) {
      final y0 = ri * (barcodeRowPx + barcodeGapPx);
      for (var y = y0; y < y0 + barcodeRowPx; y++) {
        for (var bi = 0; bi < rows[ri].length; bi++) {
          if (rows[ri][bi] == 1) {
            for (var x = bi * barcodeBarPx;
                x < (bi + 1) * barcodeBarPx;
                x++) {
              pixels[y][x] = 1;
            }
          }
        }
      }
    }
    return PngEncode.encode1Bit(pixels, width, height);
  }
}
