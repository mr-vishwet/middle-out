import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'code_grid.dart';

/// Minimal PDF writer for encoded Middle Out documents: 1 LANDSCAPE cover
/// page + 1 LANDSCAPE full-bleed code page per frame.
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
/// Document shape: Catalog, Pages, Helvetica + Helvetica-Bold
/// (standard-14 fonts, never embedded), one shared RGB logo XObject (when
/// frame pages exist), then per page: Page, Flate content stream, image
/// XObject. The image dicts deliberately contain NO nested dictionary:
/// [PdfFrameExtractor] finds an image dict by scanning back to the nearest
/// `<<` before `stream`, so a nested DecodeParms dict would be found
/// instead of the outer dict and the image would be skipped. The image
/// streams are therefore predictor 1 (packed bits, no filter bytes, no
/// DecodeParms).
///
/// Code pages are A4 landscape with the code image spanning the ENTIRE
/// page rect — no border, no margins, no caption — and the logo tile
/// drawn over the grid's reserved centre. Dark pages paint a black
/// background rect first and carry inverted 1-bit pixels (inverted by
/// the caller at deflate time); the logo tile is the same in both themes.
///
/// The cover is landscape too (same A4 size as the code pages): logo tile
/// + "MIDDLE OUT" wordmark, file details only (name, original size,
/// format, theme, page count — no SHA-256, payload size, ratio or frame
/// counts; those live in the frame headers), and a real scannable QR code
/// to the Middle Out web app, drawn as a 1-bit image XObject with its
/// quiet zone. The cover stays light in both variants.
///
/// Validated against a real parser (poppler `pdfinfo`/`pdftotext` read
/// the output: correct page count, A4 size, extractable text) and by the
/// round-trip tests in `pdf_build_roundtrip_test.dart`.
class RawPdfWriter {
  /// A4 landscape page width in points (cover and code pages).
  static const double landscapeWidth = 841.89;

  /// A4 landscape page height in points (cover and code pages).
  static const double landscapeHeight = 595.28;

  /// Side of the cover QR image, in points.
  static const double coverQrSize = 180;

  /// Side of the logo tile on the cover, in points.
  static const double coverLogoSize = 64;

  /// Cover margin, in points.
  static const double coverMargin = 48;

  /// Creates a writer. [logoDeflate] is the zlib-compressed RGB pixels
  /// of the logo tile ([logoWidth] x [logoHeight], predictor 1); when
  /// given, every frame page draws it over the grid's centre tile. One
  /// shared XObject serves all frame pages, so the tile costs ~2 KB
  /// per document, not per page.
  ///
  /// [totalPages] enables eager (streaming) mode: when the caller knows
  /// the final page count up front ([PdfDocument.build] does — cover +
  /// one page per frame), each [addCoverPage]/[addFramePage] serialises
  /// its page's objects into the output immediately and drops the
  /// image bytes, instead of holding every page until [build]. The
  /// caller must then add exactly [totalPages] pages, in final order;
  /// [build] throws [StateError] otherwise. The output bytes are
  /// identical to the lazy path for the same pages (proven by the
  /// eager/lazy test in `pdf_writer_test.dart`).
  ///
  /// Without [totalPages] the writer keeps the old behaviour (collect
  /// pages, serialise in [build]) — used by tests and tooling.
  RawPdfWriter({
    Uint8List? logoDeflate,
    this.logoWidth = 64,
    this.logoHeight = 64,
    this.totalPages,
  }) : _logoDeflate = logoDeflate;

  /// Logo tile width in pixels.
  final int logoWidth;

  /// Logo tile height in pixels.
  final int logoHeight;

  /// Declared final page count, when eager mode is on (null = lazy).
  final int? totalPages;

  /// True when this writer streams pages as they are added.
  bool get _eager => totalPages != null;

  final Uint8List? _logoDeflate;

  final _pages = <_RawPdfPage>[];

  // Eager-mode serialisation state. [_out]/[_offsets] are created by
  // [_beginEager] on the first added page; [_pageObjs] holds the
  // precomputed object numbers for all [totalPages] pages (the Pages
  // object lists every page's object number, so the count must be
  // known before the first page is written).
  BytesBuilder? _out;
  List<int>? _offsets;
  int? _logoObj;
  List<(int, int, int)>? _pageObjs;
  int _eagerAdded = 0;

  /// Adds the cover page: logo tile, "MIDDLE OUT" wordmark, [detailLines]
  /// (file name, original size, format, theme, page count — nothing
  /// else), and the scannable cover QR ([imageWidth] x [imageHeight]
  /// modules including its quiet zone, [imageDeflate] the
  /// zlib-compressed packed 1-bit pixels, predictor 1) with the scan
  /// caption underneath it. Always light, in both themes.
  void addCoverPage({
    required List<String> detailLines,
    required int imageWidth,
    required int imageHeight,
    required Uint8List imageDeflate,
  }) {
    _addPage(
      _RawPdfPage.cover(
        detailLines: detailLines,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageDeflate: imageDeflate,
      ),
    );
  }

  /// Adds one full-bleed landscape code page: the frame image
  /// ([imageWidth] x [imageHeight] modules, [imageDeflate] the
  /// zlib-compressed packed 1-bit pixels, predictor 1) spans the whole
  /// page, with the logo tile over its reserved centre. [dark] paints
  /// the page background black first; the pixels themselves must already
  /// be inverted for dark (see [PngEncode.deflate1Bit]).
  void addFramePage({
    required int imageWidth,
    required int imageHeight,
    required Uint8List imageDeflate,
    bool dark = false,
  }) {
    _addPage(
      _RawPdfPage.frame(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        imageDeflate: imageDeflate,
        dark: dark,
      ),
    );
  }

  /// Adds [page]: in lazy mode it is collected for [build]; in eager
  /// mode it is serialised into the output immediately — the image
  /// bytes are copied into the page's image object, so the writer
  /// holds no reference to the caller's image buffer after this call
  /// returns and the caller can reuse or drop it. The PDF content
  /// itself (one copy per page, inside the output buffer) is
  /// unavoidable: it IS the document being built.
  void _addPage(_RawPdfPage page) {
    if (!_eager) {
      _pages.add(page);
      return;
    }
    if (_eagerAdded >= totalPages!) {
      throw StateError(
        'RawPdfWriter: eager mode declared $totalPages pages but a '
        '${_eagerAdded + 1}th page was added',
      );
    }
    _beginEager();
    _writePage(_out!, _offsets!, page, _pageObjs![_eagerAdded], _logoObj);
    _eagerAdded++;
  }

  /// Pages added so far (cover + frames).
  int get pageCount => _eager ? _eagerAdded : _pages.length;

  /// True when the document carries pages and a logo to draw (the cover
  /// and every frame page draw the tile from one shared XObject).
  bool get _hasLogo => _logoDeflate != null && _pages.isNotEmpty;

  /// Object numbering: 1 Catalog, 2 Pages, 3 Helvetica, 4 Helvetica-Bold,
  /// then the shared logo XObject (when [hasLogo]), then per page:
  /// Page, Contents, Image (3 objects each). Returns the logo object
  /// number (null when no logo) and one (page, content, image) triple
  /// per page.
  static (int?, List<(int, int, int)>) _numbering(
    int pageCount, {
    required bool hasLogo,
  }) {
    var nextObj = 5;
    final int? logoObj = hasLogo ? nextObj++ : null;
    final pageObjs = <(int, int, int)>[];
    for (var i = 0; i < pageCount; i++) {
      pageObjs.add((nextObj, nextObj + 1, nextObj + 2));
      nextObj += 3;
    }
    return (logoObj, pageObjs);
  }

  /// Appends one object to [out], recording its byte offset. The
  /// object number is the count of objects already written + 1, so
  /// callers must append in object-number order.
  static void _addObject(
    BytesBuilder out,
    List<int> offsets,
    List<int> body,
  ) {
    offsets.add(out.length);
    out.add(_ascii('${offsets.length} 0 obj\n'));
    out.add(body);
    out.add(_ascii('\nendobj\n'));
  }

  /// Writes the header and the front matter (Catalog, Pages with the
  /// full Kids list + Count, both fonts, the shared logo XObject) for
  /// a document of [pageCount] pages. The Kids list needs every page's
  /// object number, which is why eager mode needs [totalPages] up
  /// front — the front matter is written before the first page.
  void _writeFrontMatter(
    BytesBuilder out,
    List<int> offsets,
    int pageCount,
    int? logoObj,
    List<(int, int, int)> pageObjs,
  ) {
    out.add(_ascii('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'));
    final kids =
        [for (final objs in pageObjs) '${objs.$1} 0 R'].join(' ');
    _addObject(out, offsets, _ascii('<< /Type /Catalog /Pages 2 0 R >>'));
    _addObject(
      out,
      offsets,
      _ascii('<< /Type /Pages /Kids [$kids] /Count $pageCount >>'),
    );
    _addObject(
      out,
      offsets,
      _ascii(
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
        '/Encoding /WinAnsiEncoding >>',
      ),
    );
    _addObject(
      out,
      offsets,
      _ascii(
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
        '/Encoding /WinAnsiEncoding >>',
      ),
    );
    if (logoObj != null) {
      final deflate = _logoDeflate!;
      _addObject(
        out,
        offsets,
        (BytesBuilder()
              ..add(
                _ascii(
                  '<< /Type /XObject /Subtype /Image '
                  '/Width $logoWidth /Height $logoHeight '
                  '/BitsPerComponent 8 /ColorSpace /DeviceRGB '
                  '/Filter /FlateDecode '
                  '/Length ${deflate.length} >>\n'
                  'stream\n',
                ),
              )
              ..add(deflate)
              ..add(_ascii('\nendstream')))
            .toBytes(),
      );
    }
  }

  /// Writes one page's three objects (Page dict, Flate content stream,
  /// image XObject) for [page] with object numbers [objs]; [logoObj]
  /// is the shared logo XObject number (null when no logo).
  void _writePage(
    BytesBuilder out,
    List<int> offsets,
    _RawPdfPage page,
    (int, int, int) objs,
    int? logoObj,
  ) {
    final (_, contentObj, imageObj) = objs;
    const mediaBox = '[0 0 $landscapeWidth $landscapeHeight]';
    final xobjects = logoObj == null
        ? '/Im0 $imageObj 0 R'
        : '/Im0 $imageObj 0 R /Im1 $logoObj 0 R';
    _addObject(
      out,
      offsets,
      _ascii(
        '<< /Type /Page /Parent 2 0 R '
        '/MediaBox $mediaBox '
        '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> '
        '/XObject << $xobjects >> '
        '/ProcSet [/PDF /Text /ImageB /ImageC] >> '
        '/Contents $contentObj 0 R >>',
      ),
    );
    final compressed = Uint8List.fromList(
      const ZLibEncoder().encode(
        page.contentOperators(hasLogo: logoObj != null),
      ),
    );
    _addObject(
      out,
      offsets,
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
    _addObject(
      out,
      offsets,
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

  /// Appends the xref table + trailer for the objects recorded in
  /// [offsets] to [out]. Pure byte concatenation — no pixel work.
  static void _writeXref(BytesBuilder out, List<int> offsets) {
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
  }

  /// Starts eager serialisation: computes the object numbering for
  /// [totalPages] pages and writes the front matter. Idempotent —
  /// the first added page triggers it, [build] triggers it for the
  /// zero-pages edge.
  void _beginEager() {
    if (_out != null) return;
    final n = totalPages!;
    final (logoObj, pageObjs) = _numbering(
      n,
      hasLogo: _logoDeflate != null,
    );
    _logoObj = logoObj;
    _pageObjs = pageObjs;
    _out = BytesBuilder();
    _offsets = <int>[];
    _writeFrontMatter(_out!, _offsets!, n, logoObj, pageObjs);
  }

  /// Serialises the document. Pure byte concatenation plus the xref
  /// table — no pixel work happens here.
  ///
  /// In eager mode the pages were already serialised by [addCoverPage]/
  /// [addFramePage]; this only appends the xref + trailer (and throws
  /// [StateError] when fewer than [totalPages] pages were added).
  /// In lazy mode it serialises everything from the collected pages.
  Uint8List build() {
    if (_eager) {
      _beginEager();
      if (_eagerAdded != totalPages) {
        throw StateError(
          'RawPdfWriter: eager mode declared $totalPages pages but '
          'only $_eagerAdded were added',
        );
      }
      final out = _out!;
      _writeXref(out, _offsets!);
      return out.toBytes();
    }
    final n = _pages.length;
    final (logoObj, pageObjs) = _numbering(
      n,
      hasLogo: _hasLogo,
    );
    final out = BytesBuilder();
    final offsets = <int>[];
    _writeFrontMatter(out, offsets, n, logoObj, pageObjs);
    for (var i = 0; i < n; i++) {
      _writePage(out, offsets, _pages[i], pageObjs[i], logoObj);
    }
    _writeXref(out, offsets);
    return out.toBytes();
  }
}

/// One page of the encoded PDF: a 1-bit image plus text operators.
class _RawPdfPage {
  _RawPdfPage.cover({
    required this.detailLines,
    required this.imageWidth,
    required this.imageHeight,
    required this.imageDeflate,
  }) : isCover = true,
       dark = false,
       caption = 'Scan to open the Middle Out app.';

  _RawPdfPage.frame({
    required this.imageWidth,
    required this.imageHeight,
    required this.imageDeflate,
    required this.dark,
  }) : isCover = false,
       detailLines = const [],
       caption = '';

  /// True for the cover page.
  final bool isCover;

  /// Cover detail lines (empty on frame pages).
  final List<String> detailLines;

  /// Image width in pixels.
  final int imageWidth;

  /// Image height in pixels.
  final int imageHeight;

  /// Zlib-compressed packed 1-bit pixels (predictor 1, DeviceGray:
  /// bit 0 = black; dark pages carry pre-inverted pixels).
  final Uint8List imageDeflate;

  /// True for a dark code page (black background, inverted pixels).
  final bool dark;

  /// Caption centred under the image (cover only).
  final String caption;

  /// The page's content-stream operators (uncompressed).
  Uint8List contentOperators({required bool hasLogo}) {
    final buf = StringBuffer();
    if (isCover) {
      // Landscape cover: logo tile + wordmark top-left, file details
      // below them, scannable QR on the right with its caption.
      const margin = RawPdfWriter.coverMargin;
      const pageW = RawPdfWriter.landscapeWidth;
      const pageH = RawPdfWriter.landscapeHeight;
      const logoSide = RawPdfWriter.coverLogoSize;
      if (hasLogo) {
        buf.write(_logoOpAt(margin, pageH - margin - logoSide, logoSide));
      }
      buf.write(_text('MIDDLE OUT', 34, margin + logoSide + 16, 505, bold: true));
      buf.write(_text('Lossless file, printed as code.', 13, margin + logoSide + 16, 478));
      var y = 420.0;
      for (final line in detailLines) {
        buf.write(_text(line, 11, margin, y));
        y -= 20;
      }
      const qrSize = RawPdfWriter.coverQrSize;
      const qrX = pageW - margin - qrSize;
      const qrY = (pageH - qrSize) / 2;
      buf.write(_imageOp(qrSize, qrSize, qrX, qrY, '/Im0'));
      buf.write(_textCentredAt(caption, 10, qrY - 16, qrX + qrSize / 2));
    } else {
      // Full-bleed: the code image spans the entire landscape page.
      if (dark) {
        buf.write(
          '0 g 0 0 ${_num(RawPdfWriter.landscapeWidth)} '
          '${_num(RawPdfWriter.landscapeHeight)} re f\n',
        );
      }
      buf.write(
        _imageOp(
          RawPdfWriter.landscapeWidth,
          RawPdfWriter.landscapeHeight,
          0,
          0,
          '/Im0',
        ),
      );
      if (hasLogo) {
        buf.write(_logoOp());
      }
    }
    return Uint8List.fromList(_latin1(buf.toString()));
  }

  /// The logo tile over the grid's reserved centre tile.
  ///
  /// The centre tile spans grid columns [c0, c0+tileW) and rows
  /// [r0, r0+tileH); PDF Y is bottom-up while image rows are top-down, so
  /// the tile's bottom edge sits at pageHeight - (r0+tileH)/h*pageHeight.
  /// The tile is square AS DRAWN in both formats (the tile rule sizes it
  /// that way — see [CodeGrid.centreTile]), so the logo fills it exactly;
  /// the min() keeps it square even if rounding leaves the rect a hair
  /// off-square. Drawing it stretched to the full tile rect would
  /// distort the M, and drawing it wider than the reserved tile would
  /// cover live data modules.
  String _logoOp() {
    final (r0, c0, tileW, tileH) =
        CodeGrid.centreTile(imageWidth, imageHeight);
    const pageW = RawPdfWriter.landscapeWidth;
    const pageH = RawPdfWriter.landscapeHeight;
    final tileWPt = tileW / imageWidth * pageW;
    final tileHPt = tileH / imageHeight * pageH;
    final logoSide = min(tileWPt, tileHPt);
    final x = c0 / imageWidth * pageW + (tileWPt - logoSide) / 2;
    final tileBottom = pageH - (r0 + tileH) / imageHeight * pageH;
    final y = tileBottom + (tileHPt - logoSide) / 2;
    return _logoOpAt(x, y, logoSide);
  }

  /// The logo tile as a [side]-point square at ([x], [y]), inside a
  /// rounded-rectangle clip so the tile keeps its rounded corners.
  /// Shared by the cover (fixed position) and frame pages ([_logoOp]).
  static String _logoOpAt(double x, double y, double logoSide) {
    final r = logoSide * 0.2;
    // Rounded-rectangle clip path (bezier corners, kappa = 0.5523),
    // then the logo image inside the same q...Q block.
    const k = 0.5522847498;
    final buf = StringBuffer('q ');
    buf.write('${_num(x + r)} ${_num(y)} m ');
    buf.write('${_num(x + logoSide - r)} ${_num(y)} l ');
    buf.write(
      '${_num(x + logoSide - r + k * r)} ${_num(y)} '
      '${_num(x + logoSide)} ${_num(y + r - k * r)} '
      '${_num(x + logoSide)} ${_num(y + r)} c ',
    );
    buf.write('${_num(x + logoSide)} ${_num(y + logoSide - r)} l ');
    buf.write(
      '${_num(x + logoSide)} ${_num(y + logoSide - r + k * r)} '
      '${_num(x + logoSide - r + k * r)} ${_num(y + logoSide)} '
      '${_num(x + logoSide - r)} ${_num(y + logoSide)} c ',
    );
    buf.write('${_num(x + r)} ${_num(y + logoSide)} l ');
    buf.write(
      '${_num(x + r - k * r)} ${_num(y + logoSide)} '
      '${_num(x)} ${_num(y + logoSide - r + k * r)} '
      '${_num(x)} ${_num(y + logoSide - r)} c ',
    );
    buf.write('${_num(x)} ${_num(y + r)} l ');
    buf.write(
      '${_num(x)} ${_num(y + r - k * r)} '
      '${_num(x + r - k * r)} ${_num(y)} '
      '${_num(x + r)} ${_num(y)} c ',
    );
    buf.write('h W n\n');
    buf.write(
      '${_num(logoSide)} 0 0 ${_num(logoSide)} ${_num(x)} ${_num(y)} '
      'cm /Im1 Do Q\n',
    );
    return buf.toString();
  }

  static String _imageOp(
    double w,
    double h,
    double x,
    double y,
    String name,
  ) =>
      'q ${_num(w)} 0 0 ${_num(h)} ${_num(x)} ${_num(y)} cm $name Do Q\n';

  static String _text(
    String s,
    double size,
    double x,
    double y, {
    bool bold = false,
  }) =>
      'BT /${bold ? 'F2' : 'F1'} ${_num(size)} Tf '
      '${_num(x)} ${_num(y)} Td (${_escape(s)}) Tj ET\n';

  static String _textCentredAt(String s, double size, double y, double centerX) {
    final w = _stringWidth(s, size);
    return _text(s, size, centerX - w / 2, y);
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
  /// is WinAnsi 0xB7 and passes through; an em-dash in a file name
  /// (U+2014) maps to WinAnsi 0x97.
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
  /// names and cover details keep their dashes and quotes instead
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
