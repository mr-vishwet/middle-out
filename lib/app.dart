import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'core/theme_scope.dart';
import 'screens/home_screen.dart';

/// Middle Out app shell.
///
/// Dark is the primary theme (what the V7 screens were designed in); the
/// light theme is the alternative built alongside it. The toggle in the
/// home AppBar flips the whole app via [AppThemeScope].
class MiddleOutApp extends StatefulWidget {
  const MiddleOutApp({super.key});

  @override
  State<MiddleOutApp> createState() => _MiddleOutAppState();
}

class _MiddleOutAppState extends State<MiddleOutApp> {
  final _themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      themeMode: _themeMode,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: _themeMode,
        builder: (context, mode, _) {
          return MaterialApp(
            title: 'Middle Out',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: mode,
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
