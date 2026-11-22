import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'code_grid.dart';
import 'encoder.dart';
import 'logo_tile.dart';
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

/// Assembles the encoded PDF: 1 portrait cover page + 1 landscape
/// full-bleed code page per frame, each frame embedded as a 1-bit image
/// XObject with the logo tile over its centre.
///
/// The cover carries a small square Middle Out Code grid with the decode
/// manifest (file name, sizes, SHA-256, frame count) — scannable by the
/// app. A real ISO QR cover code (readable by any phone camera) is a
/// v0.2 item.
///
/// The document is assembled by [RawPdfWriter], not the `pdf` package:
/// the package has no public API for a 1-bit image XObject, and its
/// `MemoryImage` path decoded each 1-bit PNG to RGBA, re-encoded it as
/// 8-bit RGB plus an alpha SMask, and re-deflated ~2.3 MB per page inside
/// `doc.save()` — ~194 ms per frame on the VM. The writer embeds the
/// already-deflated 1-bit pixels verbatim, so serialising a page costs
/// ~1 ms and the whole build runs at the per-frame loop rate.
class PdfDocument {
  /// Builds the PDF bytes for [result] (the encode of [fileName]).
  ///
  /// Two phases, reported through [onProgress] — fraction 0..1 of the
  /// PDF build plus a human-readable label:
  /// * Phase 1, "Creating images… N of M": builds every frame image
  ///   (grid + deflate), yielding to the event loop after every frame so
  ///   the UI can repaint the progress bar and respond to taps (Cancel)
  ///   during a long build. Without the yields the whole build blocks
  ///   the UI thread and the bar sits pinned at its last value for
  ///   minutes on large files.
  /// * Phase 2, "Binding into PDF…": assembles the document via
  ///   [RawPdfWriter] (cover + frame pages) and serialises it.
  ///
  /// When [shouldCancel] returns true the build stops promptly by
  /// throwing [BuildCancelledException]. Neither callback changes the
  /// PDF bytes: the loop body is untouched.
  ///
  /// [dark] builds the dark variant: code pages get a black background
  /// and inverted 1-bit pixels (white code on black). The cover page
  /// stays light in both variants.
  static Future<(Uint8List, PdfStats)> build(
    EncodeResult result,
    String fileName, {
    EncodeProgress? onProgress,
    bool Function()? shouldCancel,
    bool dark = false,
  }) async {
    final frames = result.frames;

    // --- Phase 1: build every frame image (grid + deflate) ---
    final images = <_FrameImage>[];
    for (var i = 0; i < frames.length; i++) {
      final raw = frames[i].toBytes();
      final grid = CodeGrid.buildFrameGrid(raw, barcode: result.barcode);
      final deflate = PngEncode.deflate1Bit(
        grid,
        grid[0].length,
        grid.length,
        dark: dark,
      );
      images.add(
        _FrameImage(
          width: grid[0].length,
          height: grid.length,
          deflate: deflate,
        ),
      );
      onProgress?.call(
        0.9 * (i + 1) / frames.length,
        'Creating images… ${i + 1} of ${frames.length}',
      );
      if (shouldCancel?.call() == true) {
        throw const BuildCancelledException();
      }
      // Yield so the UI repaints the bar and Cancel taps get through —
      // the per-frame work above is synchronous and would otherwise
      // block the UI thread for the whole build.
      await Future<void>.delayed(Duration.zero);
    }

    // --- Phase 2: bind the document ---
    onProgress?.call(0.95, 'Binding into PDF…');
    if (shouldCancel?.call() == true) {
      throw const BuildCancelledException();
    }
    await Future<void>.delayed(Duration.zero);

    // The logo tile is deflated once per document; the writer shares one
    // XObject across all frame pages.
    final logoDeflate = Uint8List.fromList(
      const ZLibEncoder().encode(LogoTile.rgb, level: 6),
    );
    final writer = RawPdfWriter(
      logoDeflate: logoDeflate,
      logoWidth: LogoTile.size,
      logoHeight: LogoTile.size,
    );

    // Cover page (unchanged: portrait, manifest text + small square
    // grid with its quiet zone, light in both variants).
    final manifest = _manifestText(result, fileName);
    final manifestGrid = CodeGrid.buildGrid(
      Uint8List.fromList(utf8.encode(manifest)),
      aspect: 1.0,
    );
    final (manifestW, manifestH, manifestDeflate) =
        _coverGridDeflate(manifestGrid);
    writer.addCoverPage(
      manifestLines: manifest.split('\n'),
      imageWidth: manifestW,
      imageHeight: manifestH,
      imageDeflate: manifestDeflate,
    );

    for (final image in images) {
      writer.addFramePage(
        imageWidth: image.width,
        imageHeight: image.height,
        imageDeflate: image.deflate,
        dark: dark,
      );
    }

    final bytes = writer.build();
    onProgress?.call(1, 'Binding into PDF…');
    return (
      bytes,
      PdfStats(pages: 1 + frames.length, sizeBytes: bytes.length),
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

  /// Cover grid matrix -> (width, height, deflate), with a quiet zone of
  /// white modules around the grid (the cover keeps its quiet zone;
  /// full-bleed code pages have none).
  static (int, int, Uint8List) _coverGridDeflate(List<Uint8List> grid) {
    final h = grid.length;
    final w = grid[0].length;
    const quiet = CodeGrid.quietModules;
    final width = w + 2 * quiet;
    final height = h + 2 * quiet;
    final rows = List<Uint8List>.generate(height, (_) => Uint8List(width));
    for (var r = 0; r < h; r++) {
      rows[r + quiet].setAll(quiet, grid[r]);
    }
    return (width, height, PngEncode.deflate1Bit(rows, width, height));
  }
}

/// One built frame image, ready to bind into the PDF.
class _FrameImage {
  /// Creates a frame image.
  const _FrameImage({
    required this.width,
    required this.height,
    required this.deflate,
  });

  /// Image width in pixels (grid modules).
  final int width;

  /// Image height in pixels (grid modules).
  final int height;

  /// Zlib-compressed packed 1-bit pixels (predictor 1).
  final Uint8List deflate;
}
