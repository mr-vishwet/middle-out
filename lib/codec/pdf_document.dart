import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/format.dart';
import 'code_grid.dart';
import 'cover_qr.dart';
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

/// Assembles the encoded PDF: 1 landscape cover page + 1 landscape
/// full-bleed code page per frame, each frame embedded as a 1-bit image
/// XObject with the logo tile over its centre.
///
/// The cover carries branding (logo tile + "MIDDLE OUT" wordmark), file
/// details only (name, original size, code format, theme, page count),
/// and a real scannable QR code to the Middle Out web app. It carries NO
/// SHA-256, payload size, ratio, frame counts or decode instructions —
/// those live in the frame headers, and the decoder never reads the
/// cover. The cover stays light in both variants.
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
  /// One fused pass, reported through [onProgress] — fraction 0..1 of
  /// the PDF build plus a human-readable label. The progress sequence
  /// is unchanged from the old two-phase build, so the UI and its
  /// tests see the same callbacks:
  /// * Per frame, "Creating images… N of M": the frame is packed
  ///   row-by-row ([CodeGrid.packFrameGrid] — no w x h matrix is ever
  ///   built), deflated ([PngEncode.deflatePacked]) and bound into the
  ///   document immediately ([RawPdfWriter] in eager mode, given the
  ///   total page count up front), then its buffers are dropped. The
  ///   loop yields to the event loop after every frame so the UI can
  ///   repaint the progress bar and respond to taps (Cancel) during a
  ///   long build. Without the yields the whole build blocks the UI
  ///   thread and the bar sits pinned at its last value for minutes on
  ///   large files.
  /// * "Binding into PDF…" at 0.95 and at 1.0: the writer only appends
  ///   the xref table + trailer here — every page is already bound.
  ///
  /// Memory: the old build held ALL frame images (phase 1) AND a
  /// second copy inside the writer's page list before binding, so a
  /// big document peaked at ~3x the PDF size plus one full grid
  /// matrix per frame. This build holds the output-so-far (one copy
  /// of the PDF, unavoidable — it is returned as bytes) plus one
  /// page's packed image + deflate buffers transiently. The honest
  /// ceiling is therefore the PDF itself: in-browser encoding is
  /// bounded by RAM for (input + compressed stream + PDF), realistically
  /// a few hundred MB of PDF on a typical device. Beyond that the
  /// route is the streaming/native encoder, which frames off disk —
  /// and, for a true multi-GB PDF, a file sink plumbed through the
  /// controller (the writer already emits pages incrementally; only
  /// the sink + the returned-bytes API stand between it and disk).
  /// Nothing here pretends a 50 GB PDF fits in a browser tab.
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

    // The logo tile is deflated once per document; the writer shares one
    // XObject across all frame pages.
    final logoDeflate = Uint8List.fromList(
      const ZLibEncoder().encode(LogoTile.rgb, level: 6),
    );
    // Eager writer: the page count is known up front (cover + one
    // page per frame), so each page is serialised as it is built and
    // its image bytes are dropped — no phase-1 image list.
    final writer = RawPdfWriter(
      logoDeflate: logoDeflate,
      logoWidth: LogoTile.size,
      logoHeight: LogoTile.size,
      totalPages: 1 + frames.length,
    );

    // Cover page: landscape like the code pages, branding + details +
    // the scannable QR, light in both variants.
    final (qrW, qrH, qrDeflate) = _coverQrDeflate();
    writer.addCoverPage(
      detailLines: _detailLines(result, fileName, dark),
      imageWidth: qrW,
      imageHeight: qrH,
      imageDeflate: qrDeflate,
    );

    for (var i = 0; i < frames.length; i++) {
      final raw = frames[i].toBytes();
      final packed = CodeGrid.packFrameGrid(raw, barcode: result.barcode);
      final deflate = PngEncode.deflatePacked(
        packed.bytes,
        packed.width,
        packed.height,
        dark: dark,
      );
      writer.addFramePage(
        imageWidth: packed.width,
        imageHeight: packed.height,
        imageDeflate: deflate,
        dark: dark,
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

    // Binding: every page is already serialised; only the xref table
    // + trailer remain.
    onProgress?.call(0.95, 'Binding into PDF…');
    if (shouldCancel?.call() == true) {
      throw const BuildCancelledException();
    }
    await Future<void>.delayed(Duration.zero);

    final bytes = writer.build();
    onProgress?.call(1, 'Binding into PDF…');
    return (
      bytes,
      PdfStats(pages: 1 + frames.length, sizeBytes: bytes.length),
    );
  }

  /// The cover's detail lines: file name, original size, code format,
  /// theme, page count — nothing else. No SHA-256, payload size, ratio
  /// or frame counts: those live in the frame headers, not on the cover.
  /// Long file names are truncated so the line cannot run into the QR.
  ///
  /// A re-encoded encode adds two plain lines: the decoded file is a
  /// lower-quality copy, not the original, and what it was re-encoded
  /// from/with. The cover is the one place (with history) where the
  /// original's size survives — the frame headers carry only the
  /// re-encoded bytes' size and SHA.
  static List<String> _detailLines(
    EncodeResult result,
    String fileName,
    bool dark,
  ) {
    const maxName = 80;
    final name = fileName.length > maxName
        ? '${fileName.substring(0, maxName - 3)}...'
        : fileName;
    final stats = result.stats;
    final lines = [
      'File: $name',
      'Original size: ${formatBytes(stats.originalSize)}',
      'Format: ${result.barcode ? 'Barcode' : 'QR-style grid'}',
      'Theme: ${dark ? 'Dark' : 'Light'}',
      'Pages: ${1 + result.frames.length}',
    ];
    final reencode = stats.reencode;
    if (reencode != null) {
      // The 'Original size' line above is the RE-ENCODED size (the
      // frames' originalSize): say so plainly, with the true original.
      lines[1] =
          'Original size: ${formatBytes(stats.originalSize)} (re-encoded)';
      const maxSettings = 40;
      final settings = reencode.settingsLabel.length > maxSettings
          ? '${reencode.settingsLabel.substring(0, maxSettings - 3)}...'
          : reencode.settingsLabel;
      lines.add(
        'Re-encoded to fit 10:1 — decoded file is a lower-quality '
        'copy, not the original',
      );
      lines.add(
        'Re-encoded from ${formatBytes(reencode.originalSizeBytes)} '
        'with ${reencode.encoder} ($settings)',
      );
    }
    return lines;
  }

  /// The cover QR as (width, height, deflate), with a quiet zone of
  /// white modules around it. The quiet zone is REQUIRED — a QR without
  /// one fails to scan (see [CoverQr]).
  static (int, int, Uint8List) _coverQrDeflate() {
    final grid = CoverQr.modules;
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
