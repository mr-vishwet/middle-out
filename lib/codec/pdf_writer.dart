import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Minimal PDF writer for encoded Middle Out documents: 1 cover page + 1
/// full-page code page per frame.
///
/// Why hand-rolled: the `pdf` package has no public API for a 1-bit image
/// XObject. Its only image path (`MemoryImage` -> `PdfImage.file`) decodes
/// each 1-bit PNG to 32-bit RGBA, strips it to 8-bit RGB plus a separate
/// alpha SMask, and re-deflates ~2.3 MB per page — measured at ~194 ms per
/// frame inside `doc.save()` on the VM (PNG decode ~19 ms, RGB/SMask
/// conversion ~66 ms, native deflate of the expanded pixels ~123 ms), and
/// the PDF came out ~1.7x larger than the 1-bit data (8-bit RGB XObject +
/// SMask per frame). This writer embeds the already-deflated 1-bit pixels
/// verbatim as a DeviceGray image XObject, so serialising a page costs
/// ~1 ms (a memcpy plus xref bookkeeping). Measured on the VM, 87 frames:
/// old `save()` 16.9 s, this writer 0.06 s; 1,125 frames extrapolate to
/// ~218 s vs ~0.8 s.
///
/// Document shape (fixed): Catalog, Pages, Helvetica + Helvetica-Bold
/// (standard-14 fonts, never embedded), then per page: Page, Flate
/// content stream, image XObject. The image dict deliberately contains
/// NO nested dictionary: [PdfFrameExtractor] finds an image dict by
/// scanning back to the nearest `<<` before `stream`, so a nested
/// DecodeParms dict would be found instead of the outer dict and the
/// image would be skipped. The image stream is therefore predictor 1
/// (packed bits, no filter bytes, no DecodeParms), which the extractor
/// already handles — no extractor change needed.
///
/// Validated against a real parser (poppler `pdfinfo`/`pdftotext` read
/// the output: correct page count, A4 size, extractable text) and by the
/// round-trip tests in `pdf_build_roundtrip_test.dart`.
class RawPdfWriter {
  /// A4 page width in points.
  static const double pageWidth = 595.28;

  /// A4 page height in points.
  static const double pageHeight = 841.89;

  /// Side of the square box the frame image is fitted into, in points.
  static const double frameBox = 520;

  /// Side of the cover manifest grid image, in points.
  static const double coverGridSize = 180;

  final _pages = <_RawPdfPage>[];

  /// Adds the cover page: title, subtitle, [manifestLines], the manifest
  /// grid image ([imageWidth] x [imageHeight], [imageDeflate] is the
  /// zlib-compressed packed 1-bit pixels, predictor 1), and the scan
  /// caption underneath it.
  void addCoverPage({
    required List<String> manifestLines,
    required int imageWidth,
    required int imageHeight,
    required Uint8List imageDeflate,
  }) {
    _pages.add(
      _RawPdfPage.cover(
        manifestLines: manifestLines,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageDeflate: imageDeflate,
      ),
    );
  }

  /// Adds one full-page code page: the frame image fitted into a
  /// [frameBox] x [frameBox] box (aspect preserved, centred) with
  /// [caption] centred underneath it.
  void addFramePage({
    required int imageWidth,
    required int imageHeight,
    required Uint8List imageDeflate,
    required String caption,
  }) {
    _pages.add(
      _RawPdfPage.frame(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageDeflate: imageDeflate,
        caption: caption,
      ),
    );
  }

  /// Pages added so far (cover + frames).
  int get pageCount => _pages.length;

  /// Serialises the document. Pure byte concatenation plus the xref
  /// table — no pixel work happens here.
  Uint8List build() {
    // Object numbering: 1 Catalog, 2 Pages, 3 Helvetica, 4 Helvetica-Bold,
    // then per page i: Page 5+3i, Contents 6+3i, Image 7+3i.
    final out = BytesBuilder();
    final offsets = <int>[];
    void addObject(List<int> body) {
      offsets.add(out.length);
      out.add(_ascii('${offsets.length} 0 obj\n'));
      out.add(body);
      out.add(_ascii('\nendobj\n'));
    }

    out.add(_ascii('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'));
    final n = _pages.length;
    final kids = [for (var i = 0; i < n; i++) '${5 + 3 * i} 0 R'].join(' ');
    addObject(_ascii('<< /Type /Catalog /Pages 2 0 R >>'));
    addObject(_ascii('<< /Type /Pages /Kids [$kids] /Count $n >>'));
    addObject(
      _ascii(
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
        '/Encoding /WinAnsiEncoding >>',
      ),
    );
    addObject(
      _ascii(
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
        '/Encoding /WinAnsiEncoding >>',
      ),
    );
    for (var i = 0; i < n; i++) {
      final page = _pages[i];
      final imageObj = 7 + 3 * i;
      final contentObj = 6 + 3 * i;
      addObject(
        _ascii(
          '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 $pageWidth $pageHeight] '
          '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> '
          '/XObject << /Im0 $imageObj 0 R >> '
          '/ProcSet [/PDF /Text /ImageB /ImageC] >> '
          '/Contents $contentObj 0 R >>',
        ),
      );
      final compressed = Uint8List.fromList(
        const ZLibEncoder().encode(page.contentOperators()),
      );
      addObject(
        (BytesBuilder()
              ..add(
                _ascii(
                  '<< /Length ${compressed.length} /Filter /FlateDecode >>\n'
                  'stream\n',
                ),
              )
              ..add(compressed)
              ..add(_ascii('\nendstream')))
            .toBytes(),
      );
      addObject(
        (BytesBuilder()
              ..add(
                _ascii(
                  '<< /Type /XObject /Subtype /Image '
                  '/Width ${page.imageWidth} /Height ${page.imageHeight} '
                  '/BitsPerComponent 1 /ColorSpace /DeviceGray '
                  '/Filter /FlateDecode '
                  '/Length ${page.imageDeflate.length} >>\n'
                  'stream\n',
                ),
              )
              ..add(page.imageDeflate)
              ..add(_ascii('\nendstream')))
            .toBytes(),
      );
    }

    final xrefAt = out.length;
    final total = offsets.length + 1;
    final xref = StringBuffer()
      ..writeln('xref')
      ..writeln('0 $total')
      ..writeln('0000000000 65535 f ');
    for (final off in offsets) {
      xref.writeln('${off.toString().padLeft(10, '0')} 00000 n ');
    }
    xref
      ..writeln('trailer')
      ..writeln('<< /Size $total /Root 1 0 R >>')
      ..writeln('startxref')
      ..writeln(xrefAt)
      ..writeln('%%EOF');
    out.add(_ascii(xref.toString()));
    return out.toBytes();
  }
}

/// One page of the encoded PDF: a 1-bit image plus text operators.
class _RawPdfPage {
  _RawPdfPage.cover({
    required this.manifestLines,
    required this.imageWidth,
    required this.imageHeight,
    required this.imageDeflate,
  }) : isCover = true,
       caption = 'Scan with the Middle Out app to verify this file.';

  _RawPdfPage.frame({
    required this.imageWidth,
    required this.imageHeight,
    required this.imageDeflate,
    required this.caption,
  }) : isCover = false,
       manifestLines = const [];

  /// True for the cover page.
  final bool isCover;

  /// Cover manifest lines (empty on frame pages).
  final List<String> manifestLines;

  /// Image width in pixels.
  final int imageWidth;

  /// Image height in pixels.
  final int imageHeight;

  /// Zlib-compressed packed 1-bit pixels (predictor 1, DeviceGray:
  /// bit 0 = black).
  final Uint8List imageDeflate;

  /// Caption centred under the image.
  final String caption;

  /// The page's content-stream operators (uncompressed).
  Uint8List contentOperators() {
    final buf = StringBuffer();
    if (isCover) {
      buf.write(_text('MIDDLE OUT', 34, 48, 750, bold: true));
      buf.write(_text('Lossless file, printed as code.', 13, 48, 720));
      var y = 680.0;
      for (final line in manifestLines) {
        buf.write(_text(line, 11, 48, y));
        y -= 19;
      }
      final gridY = y - 24 - RawPdfWriter.coverGridSize;
      buf.write(
        _imageOp(
          RawPdfWriter.coverGridSize,
          RawPdfWriter.coverGridSize,
          (RawPdfWriter.pageWidth - RawPdfWriter.coverGridSize) / 2,
          gridY,
        ),
      );
      buf.write(_textCentred(caption, 10, gridY - 16));
    } else {
      final aspect = imageWidth / imageHeight;
      final double w, h;
      if (aspect >= 1) {
        w = RawPdfWriter.frameBox;
        h = RawPdfWriter.frameBox / aspect;
      } else {
        w = RawPdfWriter.frameBox * aspect;
        h = RawPdfWriter.frameBox;
      }
      const bottom = 48.0;
      const top = RawPdfWriter.pageHeight - 48;
      final x = (RawPdfWriter.pageWidth - w) / 2;
      final y = bottom + (top - bottom - h) / 2;
      buf.write(_imageOp(w, h, x, y));
      buf.write(_textCentred(caption, 10, 24));
    }
    return Uint8List.fromList(_latin1(buf.toString()));
  }

  static String _imageOp(double w, double h, double x, double y) =>
      'q ${_num(w)} 0 0 ${_num(h)} ${_num(x)} ${_num(y)} cm /Im0 Do Q\n';

  static String _text(
    String s,
    double size,
    double x,
    double y, {
    bool bold = false,
  }) =>
      'BT /${bold ? 'F2' : 'F1'} ${_num(size)} Tf '
      '${_num(x)} ${_num(y)} Td (${_escape(s)}) Tj ET\n';

  static String _textCentred(String s, double size, double y) {
    final w = _stringWidth(s, size);
    return _text(s, size, (RawPdfWriter.pageWidth - w) / 2, y);
  }

  /// Helvetica string width in points, from the standard AFM metrics.
  static double _stringWidth(String s, double size) {
    var w = 0.0;
    for (final code in s.runes) {
      if (code >= 32 && code <= 126) {
        w += _helveticaWidthsAscii[code - 32];
      } else {
        w += 0.5; // fallback for sanitised chars
      }
    }
    return w * size;
  }

  /// PDF literal-string escaping: backslash, parens; chars outside
  /// printable ASCII / WinAnsi 160-255 become '?' unless they have a
  /// WinAnsi mapping below. The middle dot in frame captions (U+00B7)
  /// is WinAnsi 0xB7 and passes through; the em-dash in the cover
  /// manifest (U+2014) maps to WinAnsi 0x97.
  static String _escape(String s) {
    final buf = StringBuffer();
    // Runes, not codeUnits: an astral char (e.g. an emoji) is one rune
    // but two UTF-16 code units, and must degrade to a single '?'.
    for (final code in s.runes) {
      if (code == 0x28 || code == 0x29 || code == 0x5C) {
        buf.write('\\');
        buf.writeCharCode(code);
      } else if ((code >= 32 && code <= 126) || (code >= 160 && code <= 255)) {
        buf.writeCharCode(code);
      } else if (_winAnsiPunctuation.containsKey(code)) {
        buf.writeCharCode(_winAnsiPunctuation[code]!);
      } else {
        buf.write('?');
      }
    }
    return buf.toString();
  }

  /// Common punctuation mapped to its WinAnsi (cp1252) byte, so file
  /// names and the cover manifest keep their dashes and quotes instead
  /// of degrading to '?'.
  static const Map<int, int> _winAnsiPunctuation = {
    0x20AC: 0x80, // Euro sign
    0x201A: 0x82, // single low-9 quote
    0x0192: 0x83, // Latin small f with hook
    0x201E: 0x84, // double low-9 quote
    0x2026: 0x85, // ellipsis
    0x2020: 0x86, // dagger
    0x2021: 0x87, // double dagger
    0x02C6: 0x88, // circumflex
    0x2030: 0x89, // per mille
    0x0160: 0x8A, // S with caron
    0x2039: 0x8B, // single left angle quote
    0x0152: 0x8C, // OE ligature
    0x017D: 0x8E, // Z with caron
    0x2018: 0x91, // left single quote
    0x2019: 0x92, // right single quote
    0x201C: 0x93, // left double quote
    0x201D: 0x94, // right double quote
    0x2022: 0x95, // bullet
    0x2013: 0x96, // en-dash
    0x2014: 0x97, // em-dash
    0x02DC: 0x98, // tilde
    0x2122: 0x99, // trademark
    0x0161: 0x9A, // s with caron
    0x203A: 0x9B, // single right angle quote
    0x0153: 0x9C, // oe ligature
    0x017E: 0x9E, // z with caron
    0x0178: 0x9F, // Y diaeresis
  };

  static String _num(double v) {
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  static List<int> _latin1(String s) {
    final out = <int>[];
    for (final code in s.codeUnits) {
      out.add(code <= 255 ? code : 0x3F); // '?' fallback
    }
    return out;
  }
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

/// Helvetica advance widths (em fractions), ASCII 32..126, from the
/// standard AFM metrics (the same table the `pdf` package ships).
const List<double> _helveticaWidthsAscii = <double>[
  0.278,
  0.278,
  0.355,
  0.556,
  0.556,
  0.889,
  0.667,
  0.191,
  0.333,
  0.333,
  0.389,
  0.584,
  0.278,
  0.333,
  0.278,
  0.278,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.556,
  0.278,
  0.278,
  0.584,
  0.584,
  0.584,
  0.556,
  1.015,
  0.667,
  0.667,
  0.722,
  0.722,
  0.667,
  0.611,
  0.778,
  0.722,
  0.278,
  0.500,
  0.667,
  0.556,
  0.833,
  0.722,
  0.778,
  0.667,
  0.778,
  0.722,
  0.667,
  0.611,
  0.722,
  0.667,
  0.944,
  0.667,
  0.667,
  0.611,
  0.278,
  0.278,
  0.277,
  0.469,
  0.556,
  0.333,
  0.556,
  0.556,
  0.500,
  0.556,
  0.556,
  0.278,
  0.556,
  0.556,
  0.222,
  0.222,
  0.500,
  0.222,
  0.833,
  0.556,
  0.556,
  0.556,
  0.556,
  0.333,
  0.500,
  0.278,
  0.556,
  0.500,
  0.722,
  0.500,
  0.500,
  0.500,
  0.334,
  0.260,
  0.334,
  0.584,
];
