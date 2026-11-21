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
/// The cover page's manifest grid parses to text, not a frame, and is
/// skipped; only blobs with a valid frame header are kept.
///
/// The reader is deliberately tolerant: it tries both pixel polarities,
/// 1-bit and 8-bit greyscale (and RGB) images, and PNG/TIFF predictors,
/// because the PDF writer's exact image encoding is an implementation
/// detail. Anything it cannot parse is skipped, never guessed — a blob
/// is only returned when it parses as a frame.
class PdfFrameExtractor {
  /// Extracts frame blobs from [pdfBytes].
  static PdfExtraction extract(Uint8List pdfBytes) {
    final images = _findImages(pdfBytes);
    final frames = <Uint8List>[];
    final seen = <String>{};
    var parsed = 0;
    for (final image in images) {
      final pixels = _decodeImage(image);
      if (pixels == null) continue;
      parsed++;
      for (final invert in [false, true]) {
        final matrix = invert ? _invert(pixels) : pixels;
        final blob = _tryParseCode(matrix);
        if (blob == null) continue;
        final key = '${blob.length}-${blob.sublist(0, 16).join(',')}';
        if (seen.add(key)) frames.add(blob);
        break;
      }
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
      // Stream data starts after "stream" + EOL (\r\n or \n).
      var dataStart = streamAt + _streamMarker.length;
      if (dataStart < pdf.length && pdf[dataStart] == 0x0D) dataStart++;
      if (dataStart < pdf.length && pdf[dataStart] == 0x0A) dataStart++;
      // The dictionary sits just before "stream" — look back for "<<".
      final dictStart = _lastIndexOf(pdf, [0x3C, 0x3C], streamAt);
      searchFrom = dataStart;
      if (dictStart < 0 || streamAt - dictStart > 4096) continue;
      final dictText = latin1.decode(
        pdf.sublist(dictStart, streamAt),
        allowInvalid: true,
      );
      if (!dictText.contains('/Subtype') || !dictText.contains('/Image')) {
        continue;
      }
      final length = _dictInt(dictText, '/Length');
      final Uint8List streamBytes;
      if (length != null && dataStart + length <= pdf.length) {
        streamBytes =
            Uint8List.sublistView(pdf, dataStart, dataStart + length);
      } else {
        final endAt = _indexOf(pdf, _endstreamMarker, dataStart);
        if (endAt < 0) continue;
        var end = endAt;
        while (end > dataStart &&
            (pdf[end - 1] == 0x0A || pdf[end - 1] == 0x0D)) {
          end--;
        }
        streamBytes = Uint8List.sublistView(pdf, dataStart, end);
      }
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

  static List<Uint8List> _invert(List<Uint8List> matrix) => [
        for (final row in matrix)
          Uint8List.fromList([for (final v in row) v == 0 ? 1 : 0]),
      ];

  // --- Code sampling ------------------------------------------------------

  /// Tries to parse a pixel matrix as a Middle Out grid or barcode.
  /// Returns the frame blob only when it parses as a valid frame.
  static Uint8List? _tryParseCode(List<Uint8List> matrix) {
    final height = matrix.length;
    if (height == 0) return null;
    final width = matrix[0].length;
    // 2D grid: square image, quiet zone of 4 modules (fall back to 0).
    if (width == height) {
      for (final quiet in [CodeGrid.quietModules, 0]) {
        final n = width - 2 * quiet;
        if (n < CodeGrid.minSize) continue;
        final grid = List<Uint8List>.generate(
          n,
          (r) => Uint8List.sublistView(matrix[r + quiet], quiet, quiet + n),
        );
        final blob = _parseGridBlob(grid);
        if (blob != null) return blob;
      }
    }
    // Stacked barcode: 528 bars per row, barPx 2 (fall back to 1),
    // rows stacked at 24 px + 4 px gap (see PdfDocument).
    for (final barPx in [PdfBarcodeGeometry.barPx, 1]) {
      if (width % (CodeGrid.barcodeRowBars * barPx) != 0) continue;
      const rowStride = PdfBarcodeGeometry.rowPx + PdfBarcodeGeometry.gapPx;
      if (height % rowStride != 0) continue;
      final rowCount = height ~/ rowStride;
      final rows = <Uint8List>[];
      for (var r = 0; r < rowCount; r++) {
        final y = r * rowStride + PdfBarcodeGeometry.rowPx ~/ 2;
        final bars = Uint8List(CodeGrid.barcodeRowBars);
        for (var b = 0; b < CodeGrid.barcodeRowBars; b++) {
          bars[b] = matrix[y][b * barPx + barPx ~/ 2];
        }
        rows.add(bars);
      }
      final blob = _parseBarcodeBlob(rows);
      if (blob != null) return blob;
    }
    return null;
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
  /// The cover manifest grid parses to text and fails here, so it is
  /// skipped rather than treated as a frame.
  static bool _isFrame(Uint8List blob) {
    if (blob.length < kHeaderSize + 4) return false;
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
