import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Middle Out theme — the V7 recoloured palette.
///
/// Lime on deep green: the V7 redesign moved Middle Out off the shared
/// violet into a palette that fits the idea (a living codec, a file that
/// grows back). Dark is the primary theme; light is the alternative.
/// Both themes share the same lime accent ramp.
class AppTheme {
  AppTheme._();

  // Lime ramp.
  /// Lightest lime — primary accent on dark surfaces.
  static const Color lime300 = Color(0xFFBEF264);

  /// Mid lime — secondary accent.
  static const Color lime400 = Color(0xFFA3E635);

  /// Deep lime — accents on light surfaces.
  static const Color lime600 = Color(0xFF65A30D);

  /// Darkest lime — text/icons on light surfaces.
  static const Color lime700 = Color(0xFF4D7C0F);

  // Deep greens (dark theme surfaces).
  /// Near-black green — scaffold background.
  static const Color ink = Color(0xFF0F1410);

  /// Warm dark brown-green — secondary surface.
  static const Color bark = Color(0xFF14120E);

  /// Deep moss green — primary button text / dark surface.
  static const Color moss = Color(0xFF14200A);

  /// Dark pine green — elevated surface.
  static const Color pine = Color(0xFF1A2E1A);

  /// Dark fern green — card surface.
  static const Color fern = Color(0xFF15211A);

  // Neutrals.
  /// Warm off-white — primary text on dark surfaces.
  static const Color cream = Color(0xFFFDFCF9);

  /// Muted warm grey — secondary text.
  static const Color stone = Color(0xFF8F887B);

  /// Dark warm grey — borders and disabled text.
  static const Color clay = Color(0xFF5C584E);

  // Semantic.
  /// Error / danger red.
  static const Color danger = Color(0xFFF87171);

  /// Deep error red for light surfaces.
  static const Color dangerDeep = Color(0xFFB42318);

  /// Warning amber.
  static const Color amber = Color(0xFFFBBF24);

  /// Success teal.
  static const Color teal = Color(0xFF34D399);

  /// Informational cyan.
  static const Color cyan = Color(0xFF67E8F9);

  /// Decorative pink accent.
  static const Color pink = Color(0xFFF472B6);

  /// Primary dark theme — what the V7 screens were designed in.
  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: lime300,
      onPrimary: moss,
      secondary: lime400,
      surface: fern,
      onSurface: cream,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: ink,
      appBarTheme: const AppBarTheme(
        backgroundColor: ink,
        foregroundColor: cream,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: fern,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: pine),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: lime300,
          foregroundColor: moss,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? moss : stone,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? lime300
              : clay.withValues(alpha: 0.5),
        ),
      ),
      textTheme: GoogleFonts.interTextTheme(const TextTheme(
        displaySmall: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: cream,
          height: 1.1,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: cream,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: cream,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: cream),
        bodyMedium: TextStyle(fontSize: 14, color: cream),
        bodySmall: TextStyle(fontSize: 12, color: stone),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: moss,
        ),
      )),
    );
  }

  /// Light alternative — same lime accent, cream paper background.
  static ThemeData get light {
    const scheme = ColorScheme.light(
      primary: lime600,
      onPrimary: cream,
      secondary: lime700,
      surface: cream,
      onSurface: bark,
      error: dangerDeep,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: cream,
      appBarTheme: const AppBarTheme(
        backgroundColor: cream,
        foregroundColor: bark,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFE7E5E0)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: lime600,
          foregroundColor: cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: GoogleFonts.interTextTheme(const TextTheme(
        displaySmall: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: bark,
          height: 1.1,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: bark,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: bark,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: bark),
        bodyMedium: TextStyle(fontSize: 14, color: bark),
        bodySmall: TextStyle(fontSize: 12, color: clay),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: cream,
        ),
      )),
    );
  }
}
