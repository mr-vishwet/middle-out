import 'dart:math' show max;
import 'dart:typed_data';

import 'frame.dart';

/// The visual codes: a Middle Out Code grid (2D) and a stacked-row barcode.
///
/// A real ISO QR code holds ~3 KB; a Middle Out frame holds up to
/// ~1.7 GB (equal-split encodes divide the stream into at most 30
/// adaptive chunks — see `Encoder.dataPageCount` in encoder.dart), so the 2D mode is a
/// custom grid — QR-style finders, timing patterns and a centre tile
/// reserved for the logo — rather than an ISO QR code.
/// Barcode mode draws the same grid stretched 4x wide, so the modules
/// become tall thin bars ([barcodeAspect]); the old stacked-row barcode
/// ([buildBarcodeRows]/[parseBarcodeRows]) is kept only so PDFs encoded
/// before the full-bleed redesign still decode.
///
/// Grids are RECTANGULAR (w x h), matching the A4 landscape code page:
/// the QR grid's aspect is the page aspect (841.89/595.28), the bar-grid's
/// is 4x that. Old square grids (aspect 1.0) still parse through the
/// same path.
///
/// Both formats carry a 4-byte big-endian length prefix so the parser knows
/// where the payload ends and the padding begins. Geometry mirrors
/// `reference/codec_reference.py` exactly.
///
/// Matrices are `List<Uint8List>` rows of 0 (white) / 1 (black) modules.
class CodeGrid {
  /// Smallest grid dimension in modules; grids grow from here.
  static const int minSize = 32;

  /// Grid height grows in steps of this many modules.
  static const int step = 2;

  /// Largest grid height in modules. A 5 MB frame needs h ~ 5,600, a
  /// 10.5 MB frame h ~ 7,880 and a 77 MB frame (the densest page of a
  /// 1 GB encode) h ~ 21,300 — all far below this. 131,072 covers a
  /// ~2.9 GB frame at QR aspect: a 50 GB file at the 30-page cap needs
  /// h ~ 102,900 for its ~1.79 GB pages. The cap is a format
  /// guardrail, not a memory bound — the streaming renderer
  /// ([packGrid]) holds one page as packed bytes (~1 byte per 8 cells
  /// plus the deflate buffers), and the memory guard refuses
  /// in-memory builds long before a 2.9 GB page is attempted. A 100 GB
  /// file at 30 pages would need h ~ 145,500 and is refused by this
  /// cap; its route is the streaming encoder's fixed 64 KiB frames.
  /// Mirrors the Python reference's cap.
  static const int maxHeight = 131072;

  /// Quiet-zone width around a grid, in modules. Code pages are
  /// full-bleed (no quiet zone); the cover QR keeps one — a QR without
  /// a quiet zone fails to scan.
  static const int quietModules = 4;

  /// Payload bytes carried by one (old) barcode row.
  static const int barcodeRowBytes = 64;

  /// QR grid aspect (w/h): the A4 landscape page aspect, 841.89/595.28.
  static const double qrAspect = 841.89 / 595.28;

  /// How much wider than the QR grid the bar-grid is: the stretch that
  /// turns square modules into tall thin bars on the page.
  static const double barcodeStretch = 4;

  /// Bar-grid aspect (w/h): [barcodeStretch] x the page aspect.
  static const double barcodeAspect = barcodeStretch * qrAspect;

  /// A4 landscape page width in points (841.89) — the page the code
  /// grids fill edge to edge. Mirrors [RawPdfWriter]'s page size; the
  /// tile rule needs it so the logo tile is square as drawn.
  static const double pageWidthPt = 841.89;

  /// A4 landscape page height in points (595.28). See [pageWidthPt].
  static const double pageHeightPt = 595.28;

  // --- Grid geometry -------------------------------------------------------

  /// (startRow, startCol, tileW, tileH) of the logo tile, centred.
  ///
  /// Square grids (w == h — old-format grids): the OLD rule, unchanged
  /// — side = max(8, n ~/ 4) — so old square goldens stay byte-identical.
  ///
  /// Landscape grids (QR and bar-grid): the tile is square AS DRAWN (in
  /// points on the landscape page), so its module counts differ by axis:
  /// tileW = max(8, halfUp(w * 595.28 / (4 * 841.89))),
  /// tileH = max(8, halfUp(h / 4)). [double.round] is half-up for
  /// non-negative values, matching the Python reference's
  /// floor(x + 0.5) bit-for-bit. The old square-in-modules rule made the
  /// bar-grid tile a tall white pillar (the 4x vertical stretch turned
  /// a square module tile into a 4:1 rectangle in points); the new rule
  /// keeps the logo tile square on the page in both formats.
  /// Check: QR full frame (883x624) -> 156x156 (unchanged from the old
  /// rule); bar full frame (1742x308) -> 308x77 modules = 148.8x148.8 pt.
  static (int, int, int, int) centreTile(int w, int h) {
    if (w == h) {
      final side = max(8, w ~/ 4);
      return ((h - side) ~/ 2, (w - side) ~/ 2, side, side);
    }
    final tileW = max(8, (w * pageHeightPt / (4 * pageWidthPt)).round());
    final tileH = max(8, (h / 4).round());
    return ((h - tileH) ~/ 2, (w - tileW) ~/ 2, tileW, tileH);
  }

  /// True when cell (r, c) of a `w` x `h` grid is reserved for a
  /// structural pattern — a finder block, the timing row/column, or the
  /// centre logo tile — and cannot carry a data bit.
  ///
  /// All reserved regions are rectangles/lines, so membership is a few
  /// O(1) range checks with zero allocation. The previous implementation
  /// built a `Set<(int, int)>` of every reserved cell on every call and
  /// probed it with a fresh tuple per cell — ~800 ms per 64 KiB frame,
  /// which was ~96% of the whole PDF build. [centreStartRow],
  /// [centreStartCol], [centreTileW] and [centreTileH] are the
  /// precomputed centre tile from [centreTile], so the per-cell loop
  /// never recomputes them.
  static bool isReserved(
    int r,
    int c,
    int w,
    int h,
    int centreStartRow,
    int centreStartCol,
    int centreTileW,
    int centreTileH,
  ) {
    // Three 8x8 finder blocks: top-left, top-right, bottom-left.
    if (r < 8 && c < 8) return true;
    if (r < 8 && c >= w - 8) return true;
    if (r >= h - 8 && c < 8) return true;
    // Timing row 6 / column 6, between the finders.
    if (r == 6 && c >= 8 && c < w - 8) return true;
    if (c == 6 && r >= 8 && r < h - 8) return true;
    // Centre logo tile (tileW x tileH modules).
    return r >= centreStartRow &&
        r < centreStartRow + centreTileH &&
        c >= centreStartCol &&
        c < centreStartCol + centreTileW;
  }

  /// Placeable (non-reserved) cells of a `w` x `h` grid, in bits.
  ///
  /// Reserved cells are the three 8x8 finder blocks (192), the timing
  /// row (w - 16) and column (h - 16), and the centre tile
  /// (tileW x tileH, from [centreTile]). The regions are disjoint for
  /// every w, h >= 32, so the count is pure arithmetic — no set is ever
  /// built. Proven equal to an independent set computation across QR,
  /// bar-grid and square sizes in `code_grid_test.dart`.
  static int gridCapacityBits(int w, int h) {
    final (_, _, tileW, tileH) = centreTile(w, h);
    return w * h - 192 - (w - 16) - (h - 16) - tileW * tileH;
  }

  /// Smallest (width, height) whose capacity fits a payload of
  /// [payloadLength] bytes (plus the 4-byte length prefix), at the given
  /// [aspect] (w/h). Height steps by [step] from [minSize]; width is
  /// round(h * aspect), at least [minSize].
  static (int, int) chooseGridSize(
    int payloadLength, {
    double aspect = qrAspect,
  }) {
    final needBits = (payloadLength + 4) * 8;
    var h = minSize;
    while (true) {
      final w = max(minSize, (h * aspect).round());
      if (gridCapacityBits(w, h) >= needBits) return (w, h);
      h += step;
      if (h > maxHeight) {
        throw const CodecException('payload too large for a single code grid');
      }
    }
  }

  /// Renders [payload] into packed 1-bit rows at the given [aspect]
  /// (default the QR page aspect) — the streaming renderer.
  ///
  /// The grid math is O(1) arithmetic per cell ([isReserved],
  /// [centreTile]), so each row's bits are computed on the fly and
  /// packed 8-per-byte instead of materialising the full w x h matrix
  /// of one-byte-per-cell: a 10.5 MB frame's matrix is ~88 MB of
  /// [Uint8List] rows, while the packed bytes are ~10.5 MB. Per-page
  /// memory is O(image bytes), not O(cells x bool). The returned bits
  /// are the module bits themselves (1 = black module, 0 = white,
  /// pad bits past the row width zero); [PngEncode.deflatePacked]
  /// applies the DeviceGray inversion.
  ///
  /// This is the single bit-layout implementation: [buildGrid] unpacks
  /// these bytes into a matrix, so the two can never drift — the
  /// golden-hash tests on [buildGrid] prove this path bit-identical.
  static ({Uint8List bytes, int width, int height}) packGrid(
    Uint8List payload, {
    double aspect = qrAspect,
  }) {
    final blob = BytesBuilder()
      ..add(
        (ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
      )
      ..add(payload);
    final bytes = blob.toBytes();
    final (w, h) = chooseGridSize(payload.length, aspect: aspect);
    final (centreStartRow, centreStartCol, centreTileW, centreTileH) =
        centreTile(w, h);
    final stride = (w + 7) ~/ 8;
    final packed = Uint8List(h * stride);

    // Set one black module bit. Only ever called for 1-bits: packed
    // defaults to zero, so white modules (and the centre tile, which
    // stays blank for the logo) need no write.
    void setBit(int r, int c) {
      packed[r * stride + c ~/ 8] |= 1 << (7 - c % 8);
    }

    // Finder patterns: 7x7, outer ring black, middle ring white, 3x3 core.
    for (final (r0, c0) in [(0, 0), (0, w - 7), (h - 7, 0)]) {
      for (var dr = 0; dr < 7; dr++) {
        for (var dc = 0; dc < 7; dc++) {
          final onRing = dr == 0 || dr == 6 || dc == 0 || dc == 6;
          final inCore = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
          if (onRing || inCore) setBit(r0 + dr, c0 + dc);
        }
      }
    }
    // Timing row/column 6, alternating starting black (even indices).
    for (var i = 8; i < w - 8; i += 2) {
      setBit(6, i);
    }
    for (var i = 8; i < h - 8; i += 2) {
      setBit(i, 6);
    }

    // Data bits, row-major over the placeable cells, MSB first. The
    // bit math is inlined (not a per-cell closure call): a 77 MB
    // frame walks ~640M cells, and the closure call would dominate.
    var bitIndex = 0;
    final totalBits = bytes.length * 8;
    outer:
    for (var r = 0; r < h; r++) {
      final rowBase = r * stride;
      for (var c = 0; c < w; c++) {
        if (isReserved(
          r,
          c,
          w,
          h,
          centreStartRow,
          centreStartCol,
          centreTileW,
          centreTileH,
        )) {
          continue;
        }
        if (bitIndex >= totalBits) break outer;
        if ((bytes[bitIndex ~/ 8] >> (7 - bitIndex % 8)) & 1 == 1) {
          packed[rowBase + c ~/ 8] |= 1 << (7 - c % 8);
        }
        bitIndex++;
      }
    }
    return (bytes: packed, width: w, height: h);
  }

  /// Packs the frame grid for [payload]: the bar-grid when [barcode],
  /// the QR grid otherwise. The streaming counterpart of
  /// [buildFrameGrid], used by the PDF builder.
  static ({Uint8List bytes, int width, int height}) packFrameGrid(
    Uint8List payload, {
    required bool barcode,
  }) =>
      packGrid(payload, aspect: barcode ? barcodeAspect : qrAspect);

  /// Renders [payload] into a w x h module matrix at the given [aspect]
  /// (default the QR page aspect). Square grids (aspect 1.0) use the
  /// same layout rules, so old square grids are the same format, not a
  /// special case.
  ///
  /// Unpacks [packGrid]: the matrix is only a view of the packed bits,
  /// kept for previews, tests and the legacy stacked-row tooling. The
  /// PDF builder never calls this — it streams [packGrid] straight
  /// into [PngEncode.deflatePacked].
  static List<Uint8List> buildGrid(
    Uint8List payload, {
    double aspect = qrAspect,
  }) {
    final packed = packGrid(payload, aspect: aspect);
    final w = packed.width;
    final h = packed.height;
    final stride = (w + 7) ~/ 8;
    final bytes = packed.bytes;
    return List<Uint8List>.generate(h, (r) {
      final row = Uint8List(w);
      final rowBase = r * stride;
      for (var c = 0; c < w; c++) {
        row[c] = (bytes[rowBase + c ~/ 8] >> (7 - c % 8)) & 1;
      }
      return row;
    });
  }

  /// Builds the frame grid for [payload]: the bar-grid when [barcode],
  /// the QR grid otherwise. The one place that maps the format toggle
  /// to a grid aspect, shared by the PDF builder and the previews.
  static List<Uint8List> buildFrameGrid(
    Uint8List payload, {
    required bool barcode,
  }) =>
      buildGrid(payload, aspect: barcode ? barcodeAspect : qrAspect);

  /// Inverse of [buildGrid]: reads the length prefix, then the payload.
  /// Works for any rectangular grid, including old square ones — the
  /// dimensions come from the matrix itself. Streams the bits instead
  /// of materialising them all: a full frame's grid holds ~524k bits,
  /// and the old all-bits list cost ~4 MB per parse.
  static Uint8List parseGrid(List<Uint8List> grid) {
    final h = grid.length;
    if (h == 0) {
      throw const CodecException('grid too small to hold a length prefix');
    }
    final w = grid[0].length;
    final (centreStartRow, centreStartCol, centreTileW, centreTileH) =
        centreTile(w, h);
    var length = 0;
    var bitsSeen = 0;
    Uint8List? out;
    var byteIndex = 0;
    var bitInByte = 0;
    var current = 0;
    outer:
    for (var r = 0; r < h; r++) {
      for (var c = 0; c < w; c++) {
        if (isReserved(
          r,
          c,
          w,
          h,
          centreStartRow,
          centreStartCol,
          centreTileW,
          centreTileH,
        )) {
          continue;
        }
        final bit = grid[r][c];
        if (bitsSeen < 32) {
          length = (length << 1) | bit;
          bitsSeen++;
          if (bitsSeen == 32) {
            if (length * 8 + 32 > gridCapacityBits(w, h)) {
              throw const CodecException(
                'grid length prefix exceeds grid capacity',
              );
            }
            out = Uint8List(length);
          }
        } else {
          if (byteIndex >= length) break outer;
          current = (current << 1) | bit;
          bitInByte++;
          if (bitInByte == 8) {
            out![byteIndex++] = current;
            current = 0;
            bitInByte = 0;
          }
        }
      }
    }
    if (bitsSeen < 32) {
      throw const CodecException('grid too small to hold a length prefix');
    }
    return out!;
  }

  // --- Stacked-row barcode (legacy: decode old PDFs only) -----------------

  /// Row layout (bars, 1 = black): [4 start guard][8 row index]
  /// [512 data][4 stop guard] = 528 bars per row.
  static const int barcodeRowBars = 4 + 8 + barcodeRowBytes * 8 + 4;

  /// Renders [payload] into stacked barcode rows of [barcodeRowBars] bars.
  ///
  /// Legacy: new barcode PDFs use the bar-grid ([buildGrid] with
  /// [barcodeAspect]). Kept so the extractor's stacked-row path and its
  /// tests still have a builder, and so old-format fixtures can be
  /// regenerated.
  static List<Uint8List> buildBarcodeRows(Uint8List payload) {
    final blob = BytesBuilder()
      ..add(
        (ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
      )
      ..add(payload);
    final bytes = blob.toBytes();
    final rowCount =
        (bytes.length + barcodeRowBytes - 1) ~/ barcodeRowBytes;
    final rows = <Uint8List>[];
    for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      final chunk = Uint8List(barcodeRowBytes);
      final start = rowIndex * barcodeRowBytes;
      final end = (start + barcodeRowBytes).clamp(0, bytes.length);
      chunk.setAll(0, bytes.sublist(start, end));
      final bars = Uint8List(barcodeRowBars);
      bars[0] = 1;
      bars[1] = 1;
      bars[2] = 1;
      bars[3] = 1;
      for (var k = 0; k < 8; k++) {
        bars[4 + k] = (rowIndex >> (7 - k)) & 1;
      }
      for (var i = 0; i < barcodeRowBytes; i++) {
        for (var k = 0; k < 8; k++) {
          bars[12 + i * 8 + k] = (chunk[i] >> (7 - k)) & 1;
        }
      }
      bars[barcodeRowBars - 4] = 1;
      bars[barcodeRowBars - 3] = 1;
      bars[barcodeRowBars - 2] = 1;
      bars[barcodeRowBars - 1] = 1;
      rows.add(bars);
    }
    return rows;
  }

  /// Inverse of [buildBarcodeRows]. Rows are reassembled by their index,
  /// so a scan that reads them out of order still decodes.
  ///
  /// The row index is 8 bits, so a frame needing more than 256 rows
  /// (payload above ~16 KiB — every full 64 KiB frame needs 1,026 rows)
  /// wraps: rows 256+ reuse indices 0+. When indices collide the index
  /// cannot order the rows, so they are reassembled in list order
  /// instead — PDF extraction and camera scans both read top-to-bottom,
  /// so list order is the row order. Unique indices keep the old
  /// index-ordered behaviour.
  static Uint8List parseBarcodeRows(List<Uint8List> rows) {
    if (rows.isEmpty) {
      throw const CodecException('no barcode rows');
    }
    if (rows.first.length != barcodeRowBars) {
      throw CodecException(
        'unexpected barcode row width ${rows.first.length}',
      );
    }
    final chunks = <int, Uint8List>{};
    final ordered = <Uint8List>[];
    for (final bars in rows) {
      if (bars[0] != 1 ||
          bars[1] != 1 ||
          bars[2] != 1 ||
          bars[3] != 1 ||
          bars[barcodeRowBars - 4] != 1 ||
          bars[barcodeRowBars - 3] != 1 ||
          bars[barcodeRowBars - 2] != 1 ||
          bars[barcodeRowBars - 1] != 1) {
        throw const CodecException('barcode row guard pattern missing');
      }
      var index = 0;
      for (var k = 0; k < 8; k++) {
        index = (index << 1) | bars[4 + k];
      }
      final data = Uint8List(barcodeRowBytes);
      for (var i = 0; i < barcodeRowBytes; i++) {
        var byte = 0;
        for (var k = 0; k < 8; k++) {
          byte = (byte << 1) | bars[12 + i * 8 + k];
        }
        data[i] = byte;
      }
      chunks[index] = data;
      ordered.add(data);
    }
    final blob = BytesBuilder();
    if (chunks.length == rows.length) {
      // No index collision: reassemble by index (out-of-order scans OK).
      final sorted = chunks.keys.toList()..sort();
      for (final index in sorted) {
        blob.add(chunks[index]!);
      }
    } else {
      // Indices wrapped past 256 rows: reassemble in list order.
      for (final data in ordered) {
        blob.add(data);
      }
    }
    final bytes = blob.toBytes();
    final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
    if (length + 4 > bytes.length) {
      throw const CodecException('barcode length prefix exceeds payload');
    }
    return Uint8List.sublistView(bytes, 4, 4 + length);
  }
}
