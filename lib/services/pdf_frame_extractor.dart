import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../codec/code_grid.dart';
import '../codec/frame.dart';
import '../core/constants.dart';

/// What a PDF import found.
class PdfExtraction {
  /// Creates an extraction result.
  const PdfExtraction({
    required this.frames,
    required this.imagesFound,
    required this.imagesParsed,
  });

  /// Frame blobs recovered from the PDF's code images, deduplicated.
  final List<Uint8List> frames;

  /// Image XObjects found in the PDF.
  final int imagesFound;

  /// Images that decoded to pixel data.
  final int imagesParsed;
}

/// Recovers Middle Out frames from an encoded PDF.
///
/// The encoder embeds each frame as a 1-bit image XObject (see
/// [PdfDocument]); this reader finds those XObjects, inflates the
/// FlateDecode streams, samples the modules back out of the pixels, and
/// returns the frame blobs — which then feed the normal [Decoder].
/// The cover page's QR code parses to nothing (it is a real ISO QR code,
/// not a Middle Out grid) and is skipped; only blobs with a valid frame
/// header are kept.
///
/// Formats, identified by image aspect: new rectangular QR grids
/// (w/h ~ 1.414) and bar-grids (w/h ~ 5.657), both full-bleed with no
/// quiet zone; old square grids (w/h = 1, quiet zone 4) and old
/// stacked-row barcodes (528 bars/row, 24 px bands + 4 px gaps).
/// Dark pages are polarity-detected per image from the top-left finder
/// (guard bars for stacked barcodes) and inverted before parsing, so
/// light and dark PDFs decode identically.
///
/// The reader is deliberately tolerant: it handles 1-bit and 8-bit
/// greyscale (and RGB) images, and PNG/TIFF predictors, because the PDF
/// writer's exact image encoding is an implementation detail. Anything
/// it cannot parse is skipped, never guessed — a blob is only returned
/// when it parses as a frame.
class PdfFrameExtractor {
  /// Extracts frame blobs from [pdfBytes].
  static PdfExtraction extract(Uint8List pdfBytes) {
    final images = _findImages(pdfBytes);
    // New-format PDFs carry 1-bit code images plus one RGB logo tile;
    // prefer the 1-bit images and never try to parse the logo. Old-format
    // PDFs have only 8-bit RGB code images (no 1-bit image exists), so
    // when no 1-bit image is present every image is attempted.
    final hasOneBit = images.any(
      (image) => image.bitsPerComponent == 1 && image.colors == 1,
    );
    final candidates = hasOneBit
        ? [
            for (final image in images)
              if (image.bitsPerComponent == 1 && image.colors == 1) image,
          ]
        : images;
    final frames = <Uint8List>[];
    final seen = <String>{};
    var parsed = 0;
    for (final image in candidates) {
      final pixels = _decodeImage(image);
      if (pixels == null) continue;
      parsed++;
      final blob = _tryParseCode(pixels);
      if (blob == null) continue;
      final key = '${blob.length}-${blob.sublist(0, 16).join(',')}';
      if (seen.add(key)) frames.add(blob);
    }
    return PdfExtraction(
      frames: frames,
      imagesFound: images.length,
      imagesParsed: parsed,
    );
  }

  // --- PDF scanning -------------------------------------------------------

  static const List<int> _streamMarker = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D];
  static const List<int> _endstreamMarker = [
    0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D,
  ];

  /// One image XObject: dictionary text + raw stream bytes.
  static List<_PdfImage> _findImages(Uint8List pdf) {
    final images = <_PdfImage>[];
    var searchFrom = 0;
    while (true) {
      final streamAt = _indexOf(pdf, _streamMarker, searchFrom);
      if (streamAt < 0) break;
      // A "stream" match inside "endstream" is not a stream start: a
      // real "stream" keyword follows its dict's ">>" + EOL, while
      // "endstream" has 'd' (0x64) before it.
      if (streamAt > 0 && pdf[streamAt - 1] == 0x64) {
        searchFrom = streamAt + 1;
        continue;
      }
      // Stream data starts after "stream" + EOL (\r\n or \n).
      var dataStart = streamAt + _streamMarker.length;
      if (dataStart < pdf.length && pdf[dataStart] == 0x0D) dataStart++;
      if (dataStart < pdf.length && pdf[dataStart] == 0x0A) dataStart++;
      // The dictionary sits just before "stream" — look back for "<<".
      final dictStart = _lastIndexOf(pdf, [0x3C, 0x3C], streamAt);
      if (dictStart < 0 || streamAt - dictStart > 4096) {
        // No dictionary: skip past the matching endstream, if any.
        final endAt = _indexOf(pdf, _endstreamMarker, dataStart);
        searchFrom = endAt < 0 ? pdf.length : endAt + _endstreamMarker.length;
        continue;
      }
      final dictText = latin1.decode(
        pdf.sublist(dictStart, streamAt),
        allowInvalid: true,
      );
      // Extent of this stream's data. The next scan starts past it (and
      // past its endstream), so a "stream" byte sequence inside
      // compressed data never reads as a second stream — a phantom
      // image. (The old code resumed inside the stream data, and every
      // multi-image PDF picked up phantoms from "endstream" matches.)
      final length = _dictInt(dictText, '/Length');
      final int dataEnd;
      if (length != null && dataStart + length <= pdf.length) {
        dataEnd = dataStart + length;
      } else {
        final endAt = _indexOf(pdf, _endstreamMarker, dataStart);
        if (endAt < 0) {
          searchFrom = pdf.length;
          continue;
        }
        var end = endAt;
        while (end > dataStart &&
            (pdf[end - 1] == 0x0A || pdf[end - 1] == 0x0D)) {
          end--;
        }
        dataEnd = end;
      }
      final endAt = _indexOf(pdf, _endstreamMarker, dataEnd);
      searchFrom = endAt < 0 ? dataEnd : endAt + _endstreamMarker.length;
      if (!dictText.contains('/Subtype') || !dictText.contains('/Image')) {
        continue;
      }
      final streamBytes = Uint8List.sublistView(pdf, dataStart, dataEnd);
      final width = _dictInt(dictText, '/Width');
      final height = _dictInt(dictText, '/Height');
      final bpc = _dictInt(dictText, '/BitsPerComponent') ?? 1;
      if (width == null || height == null) continue;
      final colors = dictText.contains('/DeviceRGB') ? 3 : 1;
      final predictor = _dictInt(dictText, '/Predictor') ?? 1;
      images.add(
        _PdfImage(
          width: width,
          height: height,
          bitsPerComponent: bpc,
          colors: colors,
          predictor: predictor,
          stream: streamBytes,
          flate: dictText.contains('/FlateDecode'),
        ),
      );
    }
    return images;
  }

  static int? _dictInt(String dict, String key) {
    final match = RegExp('$key\\s+(\\d+)').firstMatch(dict);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static int _indexOf(Uint8List haystack, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int _lastIndexOf(Uint8List haystack, List<int> needle, int before) {
    outer:
    for (var i = before - needle.length; i >= 0; i--) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  // --- Image decoding -----------------------------------------------------

  /// Inflates and unpacks one image XObject into a 0/1 pixel matrix
  /// (1 = black module), or null when the image cannot be decoded.
  static List<Uint8List>? _decodeImage(_PdfImage image) {
    if (!image.flate) return null;
    late Uint8List raw;
    try {
      raw = Uint8List.fromList(const ZLibDecoder().decodeBytes(image.stream));
    } catch (_) {
      return null;
    }
    final rowBytes = (image.width * image.bitsPerComponent * image.colors +
            7) ~/
        8;
    final rows = _unpredict(raw, rowBytes, image);
    if (rows == null) return null;
    final matrix = List<Uint8List>.generate(
      image.height,
      (_) => Uint8List(image.width),
    );
    if (image.bitsPerComponent == 1 && image.colors == 1) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          // DeviceGray 1-bit: 0 = black, 1 = white.
          final bit = (rows[y][x ~/ 8] >> (7 - x % 8)) & 1;
          matrix[y][x] = bit == 0 ? 1 : 0;
        }
      }
    } else if (image.bitsPerComponent == 8) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final base = x * image.colors;
          var luminance = 0;
          for (var c = 0; c < image.colors; c++) {
            luminance += rows[y][base + c];
          }
          luminance ~/= image.colors;
          matrix[y][x] = luminance < 128 ? 1 : 0;
        }
      }
    } else {
      return null;
    }
    return matrix;
  }

  /// Undoes a FlateDecode predictor, returning one byte-row per image row.
  static List<Uint8List>? _unpredict(
    Uint8List raw,
    int rowBytes,
    _PdfImage image,
  ) {
    final predictor = image.predictor;
    if (predictor == 1) {
      if (raw.length < rowBytes * image.height) return null;
      return List<Uint8List>.generate(
        image.height,
        (y) => Uint8List.sublistView(raw, y * rowBytes, (y + 1) * rowBytes),
      );
    }
    if (predictor == 2) {
      // TIFF predictor: each sample differs from the one to its left.
      if (raw.length < rowBytes * image.height) return null;
      final rows = <Uint8List>[];
      final bpp = ((image.bitsPerComponent * image.colors + 7) ~/ 8)
          .clamp(1, rowBytes);
      for (var y = 0; y < image.height; y++) {
        final row = Uint8List.fromList(
          raw.sublist(y * rowBytes, (y + 1) * rowBytes),
        );
        for (var i = bpp; i < rowBytes; i++) {
          row[i] = (row[i] + row[i - bpp]) & 0xFF;
        }
        rows.add(row);
      }
      return rows;
    }
    if (predictor >= 10 && predictor <= 15) {
      // PNG predictors: one filter byte per row.
      final stride = rowBytes + 1;
      if (raw.length < stride * image.height) return null;
      final bpp = ((image.bitsPerComponent * image.colors + 7) ~/ 8)
          .clamp(1, rowBytes);
      final rows = <Uint8List>[];
      var previous = Uint8List(rowBytes);
      for (var y = 0; y < image.height; y++) {
        final filter = raw[y * stride];
        final row = Uint8List.fromList(
          raw.sublist(y * stride + 1, (y + 1) * stride),
        );
        for (var i = 0; i < rowBytes; i++) {
          final a = i >= bpp ? row[i - bpp] : 0;
          final b = previous[i];
          final c = i >= bpp ? previous[i - bpp] : 0;
          final predict = switch (filter) {
            1 => a,
            2 => b,
            3 => (a + b) ~/ 2,
            4 => _paeth(a, b, c),
            _ => 0,
          };
          row[i] = (row[i] + predict) & 0xFF;
        }
        rows.add(row);
        previous = row;
      }
      return rows;
    }
    return null;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  // --- Code sampling ------------------------------------------------------

  /// Tries to parse a pixel matrix as a Middle Out grid or barcode.
  /// Returns the frame blob only when it parses as a valid frame.
  /// Branches on the image aspect; each branch falls through to the next
  /// on a parse failure, so a misclassified image only costs a failed
  /// parse attempt, never a wrong frame.
  static Uint8List? _tryParseCode(List<Uint8List> matrix) {
    final height = matrix.length;
    if (height == 0) return null;
    final width = matrix[0].length;
    // 1. Stacked-row barcode (old format): exact structural match on the
    // row width and band pitch. Runs first because a bar-grid can share
    // the aspect of a short stacked barcode by coincidence; the
    // guard-bar check rejects non-barcodes below.
    final stacked = _tryStackedBarcode(matrix, width, height);
    if (stacked != null) return stacked;
    // 2. Bar-grid (new barcode): aspect ~5.657, no quiet zone.
    if (_nearAspect(width / height, CodeGrid.barcodeAspect)) {
      final blob = _tryGrid(matrix, 0, 0, width, height);
      if (blob != null) return blob;
    }
    // 3. Rectangular QR grid (new format): aspect ~1.414, no quiet zone.
    if (_nearAspect(width / height, CodeGrid.qrAspect)) {
      final blob = _tryGrid(matrix, 0, 0, width, height);
      if (blob != null) return blob;
    }
    // 4. Square grid (old format): quiet zone of 4 modules
    // (fall back to 0). The cover QR is square too, but it is a real
    // ISO QR code, not a Middle Out grid — it fails the frame check
    // below and is skipped.
    if (width == height) {
      for (final quiet in [CodeGrid.quietModules, 0]) {
        final n = width - 2 * quiet;
        if (n < CodeGrid.minSize) continue;
        final blob = _tryGrid(matrix, quiet, quiet, n, n);
        if (blob != null) return blob;
      }
    }
    return null;
  }

  /// True when [aspect] is within tolerance of [target]. Grid aspects
  /// land within 0.5/h (<= 0.016 for h >= 32) of their nominal value,
  /// while the formats sit 0.4+ apart, so 0.05 separates them cleanly.
  static bool _nearAspect(double aspect, double target) =>
      (aspect - target).abs() < 0.05;

  /// Parses the w x h grid at (r0, c0) of [matrix], auto-detecting the
  /// polarity from the top-left finder first and falling back to the
  /// opposite polarity when the finder is damaged.
  static Uint8List? _tryGrid(
    List<Uint8List> matrix,
    int r0,
    int c0,
    int w,
    int h,
  ) {
    final inverted = _finderSaysInverted(matrix, r0, c0);
    final blob = _parseGridBlob(
      _subGrid(matrix, r0, c0, w, h, invert: inverted),
    );
    if (blob != null) return blob;
    return _parseGridBlob(
      _subGrid(matrix, r0, c0, w, h, invert: !inverted),
    );
  }

  /// Extracts the w x h sub-grid at (r0, c0), optionally inverting the
  /// bits (dark pages) as it copies — no full-matrix inversion.
  static List<Uint8List> _subGrid(
    List<Uint8List> matrix,
    int r0,
    int c0,
    int w,
    int h, {
    required bool invert,
  }) {
    return List<Uint8List>.generate(h, (r) {
      final row = Uint8List(w);
      final src = matrix[r0 + r];
      for (var c = 0; c < w; c++) {
        row[c] = invert ? src[c0 + c] ^ 1 : src[c0 + c];
      }
      return row;
    });
  }

  /// True when the 7x7 top-left finder at (r0, c0) matches the expected
  /// pattern better inverted than as-is — i.e. the page is dark.
  /// The finder is an outer black ring, a white middle ring and a black
  /// 3x3 core; on a dark page every bit flips. A tie (damaged finder)
  /// reads as light, and [_tryGrid] retries inverted.
  static bool _finderSaysInverted(List<Uint8List> matrix, int r0, int c0) {
    if (r0 + 7 > matrix.length || c0 + 7 > matrix[0].length) return false;
    var matchNormal = 0;
    var matchInverted = 0;
    for (var dr = 0; dr < 7; dr++) {
      for (var dc = 0; dc < 7; dc++) {
        final onRing = dr == 0 || dr == 6 || dc == 0 || dc == 6;
        final inCore = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
        final expected = (onRing || inCore) ? 1 : 0;
        if (matrix[r0 + dr][c0 + dc] == expected) {
          matchNormal++;
        } else {
          matchInverted++;
        }
      }
    }
    return matchInverted > matchNormal;
  }

  /// Tries the stacked-row barcode path (old format): 528 bars per row,
  /// barPx 2 (fall back to 1), rows stacked at 24 px + 4 px gap.
  /// Polarity comes from the guard bars — the first band's start guard
  /// is 4 black bars, so an all-white guard means a dark page — with
  /// the opposite polarity as fallback.
  static Uint8List? _tryStackedBarcode(
    List<Uint8List> matrix,
    int width,
    int height,
  ) {
    for (final barPx in [PdfBarcodeGeometry.barPx, 1]) {
      if (width % (CodeGrid.barcodeRowBars * barPx) != 0) continue;
      const rowStride = PdfBarcodeGeometry.rowPx + PdfBarcodeGeometry.gapPx;
      if (height % rowStride != 0) continue;
      final rowCount = height ~/ rowStride;
      const y = PdfBarcodeGeometry.rowPx ~/ 2;
      var guardBlack = 0;
      for (var b = 0; b < 4; b++) {
        if (matrix[y][b * barPx + barPx ~/ 2] == 1) guardBlack++;
      }
      final inverted = guardBlack == 0;
      final blob = _parseBarcodeBlob(
        _sampleBarcodeRows(matrix, barPx, rowCount, invert: inverted),
      );
      if (blob != null) return blob;
      final flipped = _parseBarcodeBlob(
        _sampleBarcodeRows(matrix, barPx, rowCount, invert: !inverted),
      );
      if (flipped != null) return flipped;
    }
    return null;
  }

  /// Samples stacked barcode rows out of [matrix]: one sample row per
  /// band (its vertical middle), one sample per bar (its centre),
  /// optionally inverted.
  static List<Uint8List> _sampleBarcodeRows(
    List<Uint8List> matrix,
    int barPx,
    int rowCount, {
    required bool invert,
  }) {
    const rowStride = PdfBarcodeGeometry.rowPx + PdfBarcodeGeometry.gapPx;
    final rows = <Uint8List>[];
    for (var r = 0; r < rowCount; r++) {
      final y = r * rowStride + PdfBarcodeGeometry.rowPx ~/ 2;
      final bars = Uint8List(CodeGrid.barcodeRowBars);
      for (var b = 0; b < CodeGrid.barcodeRowBars; b++) {
        final bit = matrix[y][b * barPx + barPx ~/ 2];
        bars[b] = invert ? bit ^ 1 : bit;
      }
      rows.add(bars);
    }
    return rows;
  }

  static Uint8List? _parseGridBlob(List<Uint8List> grid) {
    try {
      final blob = CodeGrid.parseGrid(grid);
      return _isFrame(blob) ? blob : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _parseBarcodeBlob(List<Uint8List> rows) {
    try {
      final blob = CodeGrid.parseBarcodeRows(rows);
      return _isFrame(blob) ? blob : null;
    } catch (_) {
      return null;
    }
  }

  /// True when [blob] parses as a Middle Out frame (magic + header CRC).
  /// Anything else — an old cover manifest grid (text), the new cover
  /// QR — fails here and is skipped rather than treated as a frame.
  static bool _isFrame(Uint8List blob) {
    // Pre-filter on the SMALLEST header (v1, 97 bytes): a v1 frame with
    // an empty payload is only 101 bytes, and the real validation happens
    // in Frame.fromBytes below.
    if (blob.length < kHeaderSizeV1 + 4) return false;
    for (var i = 0; i < 4; i++) {
      if (blob[i] != kFrameMagic[i]) return false;
    }
    try {
      Frame.fromBytes(blob);
      return true;
    } on CorruptFrameException {
      // A header-CRC failure means this is not one of our frames.
      return false;
    }
  }
}

/// Barcode pixel geometry shared with [PdfDocument] (bar width and row
/// pitch of the rendered barcode image).
abstract final class PdfBarcodeGeometry {
  /// Pixels per bar in the rendered barcode image.
  static const int barPx = 2;

  /// Pixel height of one barcode row band.
  static const int rowPx = 24;

  /// Pixel gap between barcode row bands.
  static const int gapPx = 4;
}

/// One parsed image XObject.
class _PdfImage {
  /// Creates a parsed image XObject.
  const _PdfImage({
    required this.width,
    required this.height,
    required this.bitsPerComponent,
    required this.colors,
    required this.predictor,
    required this.stream,
    required this.flate,
  });

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Bits per colour component.
  final int bitsPerComponent;

  /// Colour components per pixel (1 gray, 3 RGB).
  final int colors;

  /// FlateDecode predictor (1 = none).
  final int predictor;

  /// Raw (still compressed) stream bytes.
  final Uint8List stream;

  /// True when the stream uses FlateDecode.
  final bool flate;
}
