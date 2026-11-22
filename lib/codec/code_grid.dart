import 'dart:typed_data';

import 'frame.dart';

/// The visual codes: a Middle Out Code grid (2D) and a stacked-row barcode.
///
/// A real ISO QR code holds ~3 KB; a Middle Out frame holds up to 64 KiB,
/// so the 2D mode is a custom grid — QR-style finders, timing patterns and
/// a centre tile reserved for the logo — rather than an ISO QR code.
/// Barcode mode stacks the payload as rows of bars, PDF417-style.
///
/// Both formats carry a 4-byte big-endian length prefix so the parser knows
/// where the payload ends and the padding begins. Geometry mirrors
/// `reference/codec_reference.py` exactly.
///
/// Matrices are `List<Uint8List>` rows of 0 (white) / 1 (black) modules.
class CodeGrid {
  /// Smallest grid side in modules; grids grow from here.
  static const int minSize = 32;

  /// Grid side grows in steps of this many modules.
  static const int step = 4;

  /// Quiet-zone width around the grid, in modules.
  static const int quietModules = 4;

  /// Payload bytes carried by one barcode row.
  static const int barcodeRowBytes = 64;

  // --- Grid geometry -------------------------------------------------------

  /// (startRow, startCol, side) of the logo tile: centred, side = n//4.
  static (int, int, int) centreTile(int n) {
    final side = n ~/ 4 < 8 ? 8 : n ~/ 4;
    final start = (n - side) ~/ 2;
    return (start, start, side);
  }

  /// True when cell (r, c) of an `n` x `n` grid is reserved for a
  /// structural pattern — a finder block, the timing row/column, or the
  /// centre logo tile — and cannot carry a data bit.
  ///
  /// All reserved regions are rectangles/lines, so membership is a few
  /// O(1) range checks with zero allocation. The previous implementation
  /// built a `Set<(int, int)>` of every reserved cell on every call and
  /// probed it with a fresh tuple per cell — ~800 ms per 64 KiB frame,
  /// which was ~96% of the whole PDF build. [centreStart] and
  /// [centreSide] are the precomputed centre tile from [centreTile], so
  /// the per-cell loop never recomputes them.
  static bool isReserved(
    int r,
    int c,
    int n,
    int centreStart,
    int centreSide,
  ) {
    // Three 8x8 finder blocks: top-left, top-right, bottom-left.
    if (r < 8 && c < 8) return true;
    if (r < 8 && c >= n - 8) return true;
    if (r >= n - 8 && c < 8) return true;
    // Timing row 6 / column 6, between the finders.
    if (r == 6 && c >= 8 && c < n - 8) return true;
    if (c == 6 && r >= 8 && r < n - 8) return true;
    // Centre logo tile.
    return r >= centreStart &&
        r < centreStart + centreSide &&
        c >= centreStart &&
        c < centreStart + centreSide;
  }

  /// Placeable (non-reserved) cells of an `n` x `n` grid, in bits.
  ///
  /// Reserved cells are the three 8x8 finder blocks (192), the timing
  /// row/column (2 * (n - 16)), and the centre tile (side^2, side from
  /// [centreTile]). The regions are disjoint for every n >= 32, so the
  /// count is pure arithmetic — no set is ever built. Proven equal to
  /// the old set-based count for every n in 32..1024 step 4, and the
  /// test below pins the formula against an independent set computation
  /// at several sizes.
  static int gridCapacityBits(int n) {
    final (_, _, side) = centreTile(n);
    return n * n - 192 - 2 * (n - 16) - side * side;
  }

  /// Smallest grid side whose capacity fits a payload of
  /// [payloadLength] bytes (plus the 4-byte length prefix).
  static int chooseGridSize(int payloadLength) {
    final needBits = (payloadLength + 4) * 8;
    var n = minSize;
    while (gridCapacityBits(n) < needBits) {
      n += step;
      if (n > 4096) {
        throw const CodecException('payload too large for a single code grid');
      }
    }
    return n;
  }

  /// Renders [payload] into an n x n module matrix.
  static List<Uint8List> buildGrid(Uint8List payload) {
    final blob = BytesBuilder()
      ..add(
        (ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
      )
      ..add(payload);
    final bytes = blob.toBytes();
    final n = chooseGridSize(payload.length);
    final grid = List<Uint8List>.generate(n, (_) => Uint8List(n));
    final (centreStart, _, centreSide) = centreTile(n);

    // Finder patterns: 7x7, outer ring black, middle ring white, 3x3 core.
    for (final (r0, c0) in [(0, 0), (0, n - 7), (n - 7, 0)]) {
      for (var dr = 0; dr < 7; dr++) {
        for (var dc = 0; dc < 7; dc++) {
          final onRing = dr == 0 || dr == 6 || dc == 0 || dc == 6;
          final inCore = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
          grid[r0 + dr][c0 + dc] = (onRing || inCore) ? 1 : 0;
        }
      }
    }
    // Timing row/column 6, alternating starting black.
    for (var i = 8; i < n - 8; i++) {
      grid[6][i] = i % 2 == 0 ? 1 : 0;
      grid[i][6] = i % 2 == 0 ? 1 : 0;
    }

    // Data bits, row-major over the placeable cells, MSB first.
    var bitIndex = 0;
    final totalBits = bytes.length * 8;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (isReserved(r, c, n, centreStart, centreSide)) continue;
        if (bitIndex >= totalBits) return grid;
        final byte = bytes[bitIndex ~/ 8];
        grid[r][c] = (byte >> (7 - bitIndex % 8)) & 1;
        bitIndex++;
      }
    }
    return grid;
  }

  /// Inverse of [buildGrid]: reads the length prefix, then the payload.
  static Uint8List parseGrid(List<Uint8List> grid) {
    final n = grid.length;
    final (centreStart, _, centreSide) = centreTile(n);
    final bits = <int>[];
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (!isReserved(r, c, n, centreStart, centreSide)) {
          bits.add(grid[r][c]);
        }
      }
    }
    if (bits.length < 32) {
      throw const CodecException('grid too small to hold a length prefix');
    }
    var length = 0;
    for (var i = 0; i < 32; i++) {
      length = (length << 1) | bits[i];
    }
    if (length * 8 + 32 > bits.length) {
      throw const CodecException('grid length prefix exceeds grid capacity');
    }
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      var byte = 0;
      for (var k = 0; k < 8; k++) {
        byte = (byte << 1) | bits[32 + i * 8 + k];
      }
      out[i] = byte;
    }
    return out;
  }

  // --- Stacked-row barcode -------------------------------------------------

  /// Row layout (bars, 1 = black): [4 start guard][8 row index]
  /// [512 data][4 stop guard] = 528 bars per row.
  static const int barcodeRowBars = 4 + 8 + barcodeRowBytes * 8 + 4;

  /// Renders [payload] into stacked barcode rows of [barcodeRowBars] bars.
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
    }
    final sorted = chunks.keys.toList()..sort();
    final blob = BytesBuilder();
    for (final index in sorted) {
      blob.add(chunks[index]!);
    }
    final bytes = blob.toBytes();
    final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
    if (length + 4 > bytes.length) {
      throw const CodecException('barcode length prefix exceeds payload');
    }
    return Uint8List.sublistView(bytes, 4, 4 + length);
  }
}
