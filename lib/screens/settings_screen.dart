import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/routes.dart';
import '../core/theme_scope.dart';
import '../state/app_scope.dart';

/// Settings (m19/w19): the limits by platform, in plain words — plus
/// defaults, display, and data controls.
class SettingsScreen extends StatelessWidget {
  /// Creates the settings screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final settings = state.settings;
    return AdaptiveScaffold(
      title: 'Settings',
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Limits', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _limitRow(
                          theme,
                          'Native app',
                          '100 GB per file',
                          'Streaming, local — nothing leaves your device.',
                        ),
                        const Divider(),
                        _limitRow(
                          theme,
                          'Web · Local',
                          '10 GB per file',
                          'In-browser, no upload — nothing leaves this tab.',
                        ),
                        const Divider(),
                        _limitRow(
                          theme,
                          'Web · Cloud',
                          '50 GB per file',
                          'Resumable chunked upload. Account needed — '
                          'cloud upload ships in phase 2.',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'The picker shows your platform limit and routes '
                          'over-limit files to the mode that can hold them.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Encode defaults', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        title: const Text('Barcode by default'),
                        subtitle: const Text(
                          'Off: QR-style grid. On: stacked-row barcode.',
                        ),
                        value: settings.defaultBarcode,
                        onChanged: settings.setDefaultBarcode,
                      ),
                      SwitchListTile.adaptive(
                        title: const Text('Encrypt by default'),
                        subtitle: const Text(
                          'Encrypted payload is not human-readable when '
                          'scanned.',
                        ),
                        value: settings.defaultEncrypted,
                        onChanged: settings.setDefaultEncrypted,
                      ),
                      SwitchListTile.adaptive(
                        title: const Text('Verify after decode'),
                        subtitle: const Text(
                          'Compare the rebuilt file against the SHA-256 '
                          'in the frame headers.',
                        ),
                        value: settings.autoVerify,
                        onChanged: settings.setAutoVerify,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('Display', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Theme'),
                        subtitle: Text(
                          Theme.of(context).brightness == Brightness.dark
                              ? 'Dark (primary)'
                              : 'Light',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => AppThemeScope.of(context)?.toggle(),
                      ),
                      SwitchListTile.adaptive(
                        title: const Text('Show demo content'),
                        subtitle: const Text(
                          'Seeded examples, labelled DEMO — never '
                          'measurements.',
                        ),
                        value: settings.showDemo,
                        onChanged: settings.setShowDemo,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('Data', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Data controls'),
                        subtitle: const Text(
                          'Export everything, sign out, or delete the '
                          'account.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).pushNamed(
                          AppRoutes.accountData,
                        ),
                      ),
                      ListTile(
                        title: const Text('Clear history'),
                        subtitle: const Text(
                          'Removes real records; demo examples stay.',
                        ),
                        trailing: const Icon(Icons.delete_outline),
                        onTap: () async {
                          await state.history.clearAll();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('History cleared'),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('About', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Middle Out v0.1 — phase 1 build.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Lossless file compression into visual frames. '
                          'A file encodes into QR-like frames packaged as '
                          'a PDF; decoding reconstructs the original '
                          'bit-for-bit, verified by SHA-256.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _limitRow(
    ThemeData theme,
    String mode,
    String limit,
    String detail,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mode, style: theme.textTheme.bodyMedium),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Text(
            limit,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
