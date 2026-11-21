import 'package:material_ui/material_ui.dart';

/// Holds the app-wide [ThemeMode] so any screen can flip dark/light.
/// Lives in its own file so screens don't import `app.dart` (which would
/// create an import cycle: app -> screens -> app).
class AppThemeScope extends InheritedWidget {
  /// Creates a theme scope holding [themeMode] above [child].
  const AppThemeScope({
    required this.themeMode,
    required super.child,
    super.key,
  });

  /// The app-wide theme mode notifier.
  final ValueNotifier<ThemeMode> themeMode;

  /// The nearest [AppThemeScope] above [context], if any.
  static AppThemeScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>();

  /// Flips between dark and light theme mode.
  void toggle() {
    themeMode.value =
        themeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) =>
      themeMode != oldWidget.themeMode;
}
