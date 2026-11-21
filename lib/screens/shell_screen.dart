import 'package:material_ui/material_ui.dart';

import '../core/adaptive.dart';
import '../state/app_scope.dart';
import 'auth_flow.dart';
import 'decode_screen.dart';
import 'encode_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';

/// The app shell: five tabs with bottom navigation on mobile and a
/// navigation rail on web.
///
/// Tabs: Home (m01/w01), Encode (m02/w02 picker), Decode (m13/w13
/// entry), History (m11/w11), Account (m21/w21 welcome when guest,
/// m28/w28 account home when signed in). Deeper screens push on top of
/// the shell via the named routes in `AppRoutes`.
class ShellScreen extends StatefulWidget {
  /// Creates the app shell.
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.compress_outlined, Icons.compress, 'Encode'),
    (Icons.qr_code_scanner_outlined, Icons.qr_code_scanner, 'Decode'),
    (Icons.history_outlined, Icons.history, 'History'),
    (Icons.person_outlined, Icons.person, 'Account'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = Adaptive.isWide(context);
    final state = AppScope.of(context);
    final body = IndexedStack(
      index: _index,
      children: [
        const HomeScreen(),
        const PickerScreen(),
        const DecodeScreen(),
        const HistoryScreen(),
        ListenableBuilder(
          listenable: state.auth,
          builder: (context, _) => state.auth.isSignedIn
              ? const AccountHomeScreen()
              : const WelcomeScreen(),
        ),
      ],
    );
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final (icon, selectedIcon, label) in _destinations)
                  NavigationRailDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selectedIcon),
                    label: Text(label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, selectedIcon, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selectedIcon),
              label: label,
            ),
        ],
      ),
    );
  }
}

/// Navigates to a tab of the shell (used by deep screens that finish a
/// flow: encode-another, decode-another). Pops back to the shell first.
void popToShell(BuildContext context) {
  Navigator.of(context).popUntil((route) => route.isFirst);
}
