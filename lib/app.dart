import 'package:flutter/material.dart';

import 'core/routes.dart';
import 'core/theme.dart';
import 'core/theme_scope.dart';
import 'screens/auth_flow.dart';
import 'screens/batch_screen.dart';
import 'screens/decode_flow.dart';
import 'screens/decode_screen.dart';
import 'screens/encode_screen.dart';
import 'screens/frames_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/payoff_screen.dart';
import 'screens/pdf_preview_screen.dart';
import 'screens/result_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/share_screen.dart';
import 'screens/shell_screen.dart';
import 'state/app_scope.dart';

/// Middle Out app shell.
///
/// Dark is the primary theme (what the V7 screens were designed in); the
/// light theme is the alternative built alongside it in v0.1. The toggle
/// in the home AppBar flips the whole app via [AppThemeScope]. (A fuller
/// theme system is phase 2; phase 1 keeps the v0.1 toggle as-is.)
/// All shared state lives in [AppState], provided by [AppScope]; every
/// screen reads it with `AppScope.of(context)`.
class MiddleOutApp extends StatefulWidget {
  /// Creates the Middle Out app.
  const MiddleOutApp({super.key});

  @override
  State<MiddleOutApp> createState() => _MiddleOutAppState();
}

class _MiddleOutAppState extends State<MiddleOutApp> {
  final _themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  final _appState = AppState();

  @override
  void initState() {
    super.initState();
    _appState.init();
  }

  @override
  void dispose() {
    _themeMode.dispose();
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      themeMode: _themeMode,
      child: AppScope(
        state: _appState,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: _themeMode,
          builder: (context, mode, _) {
            return MaterialApp(
              title: 'Middle Out',
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: mode,
              initialRoute: AppRoutes.home,
              onGenerateRoute: generateAppRoute,
              onUnknownRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const ShellScreen(),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Builds the route for [settings]. One route per V7 screen concept;
/// each screen renders its mobile layout below 800 px and its web layout
/// above it, so these routes cover all 60 V7 screens.
///
/// Unknown names fall back to the shell (home).
Route<dynamic>? generateAppRoute(RouteSettings settings) {
  Widget page;
  switch (settings.name) {
    case AppRoutes.home:
      page = const ShellScreen();
    case AppRoutes.encodePick:
      page = const PickerScreen();
    case AppRoutes.encodePre:
      page = const PreEncodeScreen();
    case AppRoutes.encodeProgress:
      page = const EncodingScreen();
    case AppRoutes.encodeResult:
      page = const ResultScreen();
    case AppRoutes.frames:
      page = const FramesScreen();
    case AppRoutes.frameDetail:
      final index = settings.arguments;
      page = FrameDetailScreen(frameIndex: index is int ? index : 0);
    case AppRoutes.pdfPreview:
      page = const PdfPreviewScreen();
    case AppRoutes.share:
      page = const ShareScreen();
    case AppRoutes.batch:
      page = const BatchScreen();
    case AppRoutes.history:
      page = const HistoryScreen();
    case AppRoutes.historyDetail:
      final id = settings.arguments;
      page = id is String
          ? HistoryDetailScreen(recordId: id)
          : const HistoryScreen();
    case AppRoutes.decode:
      page = const DecodeScreen();
    case AppRoutes.decodeImport:
      page = const DecodeImportScreen();
    case AppRoutes.decodeProgress:
      page = const DecodingScreen();
    case AppRoutes.decodeVerify:
      page = const VerifyScreen();
    case AppRoutes.decoded:
      page = const DecodedScreen();
    case AppRoutes.decodeDamaged:
      page = const DamagedFrameScreen();
    case AppRoutes.decodeScan:
      page = const ScanScreen();
    case AppRoutes.settings:
      page = const SettingsScreen();
    case AppRoutes.payoff:
      page = const PayoffScreen();
    case AppRoutes.authWelcome:
      page = const WelcomeScreen();
    case AppRoutes.authGuest:
      page = const GuestExplainerScreen();
    case AppRoutes.authSignIn:
      page = const SignInScreen();
    case AppRoutes.authCreate:
      final email = settings.arguments;
      page = CreateAccountScreen(email: email is String ? email : null);
    case AppRoutes.authVerify:
      page = const VerifyCodeScreen();
    case AppRoutes.authUpgrade:
      final size = settings.arguments;
      page = UpgradePromptScreen(fileSize: size is int ? size : null);
    case AppRoutes.authMigrate:
      page = const MigrateScreen();
    case AppRoutes.account:
      page = const AccountHomeScreen();
    case AppRoutes.accountConnected:
      page = const ConnectedScreen();
    case AppRoutes.accountData:
      page = const DataControlsScreen();
    default:
      page = const ShellScreen();
  }
  return MaterialPageRoute<void>(
    builder: (_) => page,
    settings: settings,
  );
}
