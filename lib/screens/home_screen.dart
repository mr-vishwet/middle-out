import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/format.dart';
import '../core/theme_scope.dart';
import 'decode_screen.dart';
import 'encode_screen.dart';

/// Home: the pitch, the two flows, and the seeded demo card.
///
/// The demo card shows the product's demo story (1.04 GB podcast master
/// -> 14.2 MB PDF) and is labelled DEMO wherever it appears — it is a
/// seeded example from the V7 design, never a measured encode.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MIDDLE OUT'),
        actions: [
          IconButton(
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
            tooltip: 'Switch theme (dark / light)',
            onPressed: () => AppThemeScope.of(context)?.toggle(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'A gigabyte,\nprinted as code.',
              style: theme.textTheme.displaySmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Middle Out compresses any file into visual frames and packs '
              'them into a PDF. Decode the PDF and the original comes back '
              'bit-for-bit — verified by SHA-256.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const EncodeScreen(),
                ),
              ),
              icon: const Icon(Icons.compress),
              label: const Text('Encode a file'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DecodeScreen(),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Decode frames'),
            ),
            const SizedBox(height: 24),
            _DemoCard(theme: theme),
            const SizedBox(height: 24),
            _LimitsCard(theme: theme),
          ],
        ),
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'DEMO',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Seeded example',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(DemoFixture.fileName, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(
              '${formatBytes(DemoFixture.originalBytes)} → '
              '${formatBytes(DemoFixture.encodedBytes)} '
              '(${DemoFixture.ratioLabel})',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${DemoFixture.dataFrames} DATA + ${DemoFixture.parityFrames} '
              'PARITY frames · SHA-256 ${DemoFixture.sha256Prefix} …',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Real ratios depend on the file: silence compresses far, '
              'random data barely at all. This card shows the idea, not a '
              'measurement.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _LimitsCard extends StatelessWidget {
  const _LimitsCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Limits', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _limitRow(theme, 'Native app', '100 GB per file · streaming, local'),
            _limitRow(theme, 'Web · Local', '10 GB · in-browser, no upload'),
            _limitRow(theme, 'Web · Cloud', '50 GB · resumable upload'),
            const SizedBox(height: 8),
            Text(
              'The picker shows your platform limit and routes over-limit '
              'files to the mode that can hold them.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitRow(ThemeData theme, String mode, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(mode, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(detail, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
