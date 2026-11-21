import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../codec/code_grid.dart';
import 'app_logo.dart';

/// Paints a Middle Out Code grid (or barcode rows) with the app-icon tile
/// in the centre — the same visual the encoded PDF carries.
///
/// The centre tile is reserved white space in the grid itself; this widget
/// overlays the Play Store app-icon tile SVG on it (per the V7 spec: the
/// QR centre carries the app icon, and the barcode carries it in a white
/// centre block). Codes stay flat black-and-white on white — the codes
/// are functional, never recolored.
class FrameCodeView extends StatelessWidget {
  /// Creates a code view for a grid, or for [barcodeRows] when set.
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            children: [
              CustomPaint(
                size: size,
                painter: _CodePainter(
                  grid: grid,
                  barcodeRows: barcodeRows,
                  foreground: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (!isBarcode && grid != null)
                _GridCentreTile(grid: grid!, size: size),
              if (isBarcode)
                const Center(
                  child: _BarcodeCentreTile(),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The app-icon tile over the grid's reserved centre.
class _GridCentreTile extends StatelessWidget {
  /// Creates a centre tile positioned over the grid's reserved cells.
  const _GridCentreTile({required this.grid, required this.size});

  /// The module matrix.
  final List<Uint8List> grid;

  /// The painted size.
  final Size size;

  @override
  Widget build(BuildContext context) {
    final n = grid.length;
    const quiet = CodeGrid.quietModules;
    final total = n + 2 * quiet;
    final (r0, c0, side) = CodeGrid.centreTile(n);
    final left = (c0 + quiet) / total * size.width;
    final top = (r0 + quiet) / total * size.height;
    final tileSize = side / total * size.width;
    return Positioned(
      left: left,
      top: top,
      width: tileSize,
      height: tileSize,
      child: const AppLogo(variant: LogoVariant.appIcon),
    );
  }
}

/// The app-icon tile in a white centre block over the barcode.
class _BarcodeCentreTile extends StatelessWidget {
  /// Creates the barcode centre tile.
  const _BarcodeCentreTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const SizedBox(
        width: 44,
        height: 44,
        child: AppLogo(variant: LogoVariant.appIcon),
      ),
    );
  }
}

/// Paints the modules (grid) or bars (barcode) of a code.
class _CodePainter extends CustomPainter {
  /// Creates a code painter.
  _CodePainter({
    required this.grid,
    required this.barcodeRows,
    required this.foreground,
  });

  /// 2D module matrix (1 = black).
  final List<Uint8List>? grid;

  /// Stacked barcode rows.
  final List<Uint8List>? barcodeRows;

  /// Module/bar colour.
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
    const quiet = CodeGrid.quietModules;
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
