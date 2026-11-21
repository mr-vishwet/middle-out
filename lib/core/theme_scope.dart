import 'package:flutter/material.dart';

/// Holds the app-wide [ThemeMode] so any screen can flip dark/light.
/// Lives in its own file so screens don't import `app.dart` (which would
/// create an import cycle: app -> screens -> app).
class AppThemeScope extends InheritedWidget {
  const AppThemeScope({
    required this.themeMode,
    required super.child,
    super.key,
  });

  final ValueNotifier<ThemeMode> themeMode;

  static AppThemeScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>();

  void toggle() {
    themeMode.value =
        themeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) =>
      themeMode != oldWidget.themeMode;
}
