import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Which logo version to show.
///
/// The marks are light (#f2f5f1 on transparent, except the app icon,
/// which carries its own dark tile) — use them on dark surfaces, or on
/// the lime tile the code preview paints.
enum LogoVariant {
  /// Icon only, no text.
  icon,

  /// Horizontal lockup: icon + wordmark.
  horizontal,

  /// Stacked lockup (branding version).
  stacked,

  /// Rounded-square app-icon tile (dark tile, works anywhere).
  appIcon,
}

/// Asset path for a logo variant.
extension LogoVariantAsset on LogoVariant {
  /// Flutter asset path for this variant.
  String get asset => switch (this) {
        LogoVariant.icon => 'assets/logos/icon.svg',
        LogoVariant.horizontal => 'assets/logos/horizontal.svg',
        LogoVariant.stacked => 'assets/logos/stacked.svg',
        LogoVariant.appIcon => 'assets/logos/app-icon.svg',
      };
}

/// The Middle Out logo, from the bundled SVG assets.
class AppLogo extends StatelessWidget {
  /// Creates a logo widget.
  const AppLogo({
    required this.variant,
    this.width,
    this.height,
    super.key,
  });

  /// Which logo version to show.
  final LogoVariant variant;

  /// Display width.
  final double? width;

  /// Display height.
  final double? height;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      variant.asset,
      width: width,
      height: height,
      semanticsLabel: 'Middle Out logo',
    );
  }
}
