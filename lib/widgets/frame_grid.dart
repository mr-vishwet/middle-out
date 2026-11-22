import 'dart:math' show min;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../codec/code_grid.dart';
import 'app_logo.dart';

/// Paints a Middle Out Code grid — rectangular QR grid or bar-grid —
/// with the app-icon tile in the centre, the same visual the encoded
/// PDF carries: full-bleed, no quiet zone, flat black-and-white.
///
/// The centre tile is reserved white space in the grid itself; this
/// widget overlays the Play Store app-icon tile on it. The tile is square
/// as drawn in both formats (the tile rule sizes it that way), so the
/// logo fills it exactly, exactly as the PDF writer draws it. Codes stay
/// flat black-and-white on white — the codes are functional, never
/// recolored.
class FrameCodeView extends StatelessWidget {
  /// Creates a code view for a [grid] matrix (h rows x w columns).
  const FrameCodeView({required this.grid, super.key});

  /// 2D module matrix (1 = black), h rows of w modules.
  final List<Uint8List> grid;

  @override
  Widget build(BuildContext context) {
    final h = grid.length;
    final w = grid[0].length;
    return AspectRatio(
      aspectRatio: w / h,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            children: [
              CustomPaint(
                size: size,
                painter: _CodePainter(
                  grid: grid,
                  foreground: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              _GridCentreTile(grid: grid, size: size),
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
    final h = grid.length;
    final w = grid[0].length;
    final (r0, c0, tileW, tileH) = CodeGrid.centreTile(w, h);
    final tileWPt = tileW / w * size.width;
    final tileHPt = tileH / h * size.height;
    final logoSide = min(tileWPt, tileHPt);
    final left = c0 / w * size.width + (tileWPt - logoSide) / 2;
    final top = r0 / h * size.height + (tileHPt - logoSide) / 2;
    return Positioned(
      left: left,
      top: top,
      width: logoSide,
      height: logoSide,
      child: const AppLogo(variant: LogoVariant.appIcon),
    );
  }
}

/// Paints the modules of a code grid.
class _CodePainter extends CustomPainter {
  /// Creates a code painter.
  _CodePainter({required this.grid, required this.foreground});

  /// 2D module matrix (1 = black).
  final List<Uint8List> grid;

  /// Module colour.
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = foreground;
    final h = grid.length;
    final w = grid[0].length;
    final moduleW = size.width / w;
    final moduleH = size.height / h;
    for (var r = 0; r < h; r++) {
      for (var c = 0; c < w; c++) {
        if (grid[r][c] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(
              c * moduleW,
              r * moduleH,
              moduleW,
              moduleH,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CodePainter oldDelegate) => oldDelegate.grid != grid;
}
