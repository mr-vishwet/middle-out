import 'dart:convert';
import 'dart:typed_data';

import 'code_grid.dart';
import 'encoder.dart';
import 'pdf_writer.dart';
import 'png_encode.dart';

/// Statistics for an assembled encoded PDF.
class PdfStats {
  /// Creates PDF statistics: [pages] pages totalling [sizeBytes] bytes.
  const PdfStats({required this.pages, required this.sizeBytes});

  /// Number of pages in the encoded PDF (cover + one per frame).
  final int pages;

  /// Total size of the encoded PDF in bytes.
  final int sizeBytes;
}

/// Thrown when PdfDocument.build is cancelled through its shouldCancel
/// callback. Deliberately not a CodecException: callers treat a
/// cancellation as "stop quietly", not as an error to show the user.
/// The partial document is discarded.
class BuildCancelledException implements Exception {
  /// Creates a build-cancelled exception.
  const BuildCancelledException();

  @override
  String toString() => 'Build cancelled';
}

/// Assembles the encoded PDF: 1 cover page + 1 full-page code page per
/// frame, each frame embedded as a 1-bit image XObject.
///
/// The cover carries a small Middle Out Code grid with the decode manifest
/// (file name, sizes, SHA-256, frame count) — scannable by the app. A real
/// ISO QR cover code (readable by any phone camera) is a v0.2 item.
///
/// The document is assembled by [RawPdfWriter], not the `pdf` package:
/// the package has no public API for a 1-bit image XObject, and its
/// `MemoryImage` path decoded each 1-bit PNG to RGBA, re-encoded it as
/// 8-bit RGB plus an alpha SMask, and re-deflated ~2.3 MB per page inside
/// `doc.save()` — ~194 ms per frame on the VM. The writer embeds the
/// already-deflated 1-bit pixels verbatim, so serialising a page costs
/// ~1 ms and the whole build runs at the per-frame loop rate (~14 ms per
/// frame in grid mode, ~31 ms in barcode mode, measured on the VM).
class PdfDocument {
  /// Barcode rendering geometry inside the PDF image (pixels per bar/row).
  static const int barcodeBarPx = 2;

  /// Height of one barcode row in the PDF image, in pixels.
  static const int barcodeRowPx = 24;

  /// Vertical gap between barcode rows in the PDF image, in pixels.
  static const int barcodeGapPx = 4;

  /// Builds the PDF bytes for [result] (the encode of [fileName]).
  ///
  /// Reports progress through [onProgress] — fraction 0..1 of the PDF
  /// build plus a human-readable label ('Building PDF… page N of M') —
  /// and yields to the event loop after every frame, so the UI can
  /// repaint the progress bar and respond to taps (Cancel) during a
  /// long build. Without the yields the whole build blocks the UI
  /// thread and the bar sits pinned at its last value for minutes on
  /// large files. When [shouldCancel] returns true the build stops
  /// promptly by throwing [BuildCancelledException]. Neither callback
  /// changes the PDF bytes: the loop body is untouched.
  static Future<(Uint8List, PdfStats)> build(
    EncodeResult result,
    String fileName, {
    EncodeProgress? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final writer = RawPdfWriter();
    final stats = result.stats;

    // --- Cover page ---
    final manifest = _manifestText(result, fileName);
    final manifestGrid = CodeGrid.buildGrid(
      Uint8List.fromList(utf8.encode(manifest)),
    );
    final (manifestW, manifestH, manifestDeflate) = _gridDeflate(manifestGrid);
    writer.addCoverPage(
      manifestLines: manifest.split('\n'),
      imageWidth: manifestW,
      imageHeight: manifestH,
      imageDeflate: manifestDeflate,
    );

    // --- One full-page code page per frame ---
    final totalPages = 1 + result.frames.length;
    for (var i = 0; i < result.frames.length; i++) {
      final frame = result.frames[i];
      final raw = frame.toBytes();
      final int imageWidth, imageHeight;
      final Uint8List deflate;
      if (result.barcode) {
        (imageWidth, imageHeight, deflate) = _barcodeDeflate(
          CodeGrid.buildBarcodeRows(raw),
        );
      } else {
        (imageWidth, imageHeight, deflate) = _gridDeflate(
          CodeGrid.buildGrid(raw),
        );
      }
      final kind = frame.isData ? 'DATA' : 'PARITY';
      writer.addFramePage(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageDeflate: deflate,
        caption:
            'Frame ${frame.frameIndex + 1} of ${stats.frameCount}  ·  '
            '$kind  ·  Group ${frame.groupIndex + 1}  ·  '
            '${frame.payload.length} bytes',
      );
      onProgress?.call(
        (i + 1) / result.frames.length,
        'Building PDF… page ${i + 2} of $totalPages',
      );
      if (shouldCancel?.call() == true) {
        throw const BuildCancelledException();
      }
      // Yield so the UI repaints the bar and Cancel taps get through —
      // the per-frame work above is synchronous and would otherwise
      // block the UI thread for the whole build.
      await Future<void>.delayed(Duration.zero);
    }

    onProgress?.call(1, 'Saving PDF…');
    final bytes = writer.build();
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

  /// Grid matrix -> (width, height, deflate), with a quiet zone of white
  /// modules around the grid.
  static (int, int, Uint8List) _gridDeflate(List<Uint8List> grid) {
    final n = grid.length;
    const quiet = CodeGrid.quietModules;
    final size = n + 2 * quiet;
    final rows = List<Uint8List>.generate(size, (_) => Uint8List(size));
    for (var r = 0; r < n; r++) {
      rows[r + quiet].setAll(quiet, grid[r]);
    }
    return (size, size, PngEncode.deflate1Bit(rows, size, size));
  }

  /// Barcode rows -> (width, height, deflate). Packed directly from the
  /// bar rows — no full-pixel expansion (see [PngEncode.deflateBarcodeRows]).
  static (int, int, Uint8List) _barcodeDeflate(List<Uint8List> rows) =>
      PngEncode.deflateBarcodeRows(
        rows,
        barPx: barcodeBarPx,
        rowPx: barcodeRowPx,
        gapPx: barcodeGapPx,
      );
}
