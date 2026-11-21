import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../codec/code_grid.dart';

/// Paints a Middle Out Code grid (or barcode rows) with the logo tile in
/// the centre — the same visual the encoded PDF carries.
///
/// The centre tile is reserved white space in the grid itself; this widget
/// draws the Middle Out mark over it (a lime rounded square with the
/// "M" cut — the Play Store app-icon tile in the real app).
class FrameCodeView extends StatelessWidget {
  const FrameCodeView({
    required this.grid,
    this.barcodeRows,
    super.key,
  });

  /// 2D module matrix (1 = black). Used when [barcodeRows] is null.
  final List<Uint8List>? grid;

  /// Stacked barcode rows. When set, the barcode is painted instead.
  final List<Uint8List>? barcodeRows;

  @override
  Widget build(BuildContext context) {
    final isBarcode = barcodeRows != null;
    return AspectRatio(
      aspectRatio: isBarcode ? 2.2 : 1,
      child: CustomPaint(
        painter: _CodePainter(
          grid: grid,
          barcodeRows: barcodeRows,
          foreground: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _CodePainter extends CustomPainter {
  _CodePainter({
    required this.grid,
    required this.barcodeRows,
    required this.foreground,
  });

  final List<Uint8List>? grid;
  final List<Uint8List>? barcodeRows;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = foreground;
    if (barcodeRows != null) {
      _paintBarcode(canvas, size, paint);
    } else if (grid != null) {
      _paintGrid(canvas, size, paint);
    }
  }

  void _paintGrid(Canvas canvas, Size size, Paint paint) {
    final matrix = grid!;
    final n = matrix.length;
    final quiet = CodeGrid.quietModules;
    final total = n + 2 * quiet;
    final module = size.width / total;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (matrix[r][c] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(
              (c + quiet) * module,
              (r + quiet) * module,
              module,
              module,
            ),
            paint,
          );
        }
      }
    }
    // Centre logo tile.
    final (r0, c0, side) = CodeGrid.centreTile(n);
    final tileRect = Rect.fromLTWH(
      (c0 + quiet) * module,
      (r0 + quiet) * module,
      side * module,
      side * module,
    );
    final tilePaint = Paint()..color = const Color(0xFFBEF264);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tileRect, Radius.circular(module * 2)),
      tilePaint,
    );
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          color: const Color(0xFF14200A),
          fontSize: side * module * 0.6,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        tileRect.center.dx - textPainter.width / 2,
        tileRect.center.dy - textPainter.height / 2,
      ),
    );
  }

  void _paintBarcode(Canvas canvas, Size size, Paint paint) {
    final rows = barcodeRows!;
    final barWidth = size.width / CodeGrid.barcodeRowBars;
    final rowHeight = size.height / rows.length;
    for (var ri = 0; ri < rows.length; ri++) {
      for (var bi = 0; bi < rows[ri].length; bi++) {
        if (rows[ri][bi] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(
              bi * barWidth,
              ri * rowHeight,
              barWidth,
              rowHeight * 0.8,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CodePainter oldDelegate) =>
      oldDelegate.grid != grid || oldDelegate.barcodeRows != barcodeRows;
}
