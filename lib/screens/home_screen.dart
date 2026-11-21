import 'package:material_ui/material_ui.dart';

import '../core/adaptive.dart';
import '../core/constants.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../core/theme_scope.dart';
import '../state/app_scope.dart';
import '../state/batch_controller.dart';
import '../state/history_store.dart';
import '../widgets/app_logo.dart';

/// Home dashboard (m01/w01): the pitch, the two flows, the batch queue,
/// real stats, recent encodes, and the seeded demo card.
///
/// The demo card shows the product's demo story (1.04 GB podcast master
/// -> 14.2 MB PDF) and is labelled DEMO wherever it appears — it is a
/// seeded example from the V7 design, never a measured encode. The stats
/// row counts real encodes only.
class HomeScreen extends StatelessWidget {
  /// Creates the home dashboard.
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'MIDDLE OUT',
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
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () =>
              Navigator.of(context).pushNamed(AppRoutes.settings),
        ),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const AppLogo(variant: LogoVariant.appIcon, width: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'A gigabyte,\nprinted as code.',
                    style: theme.textTheme.displaySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Middle Out compresses any file into visual frames and packs '
              'them into a PDF. Decode the PDF and the original comes back '
              'bit-for-bit — verified by SHA-256.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            TwoPane(
              first: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.encodePick),
                    icon: const Icon(Icons.compress),
                    label: const Text('Encode a file'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.decode),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Decode a PDF'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.batch),
                    icon: const Icon(Icons.queue),
                    label: const Text('Batch queue'),
                  ),
                  const SizedBox(height: 24),
                  ListenableBuilder(
                    listenable: state.batch,
                    builder: (context, _) {
                      if (state.batch.items.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return _BatchCard(state: state);
                    },
                  ),
                  ListenableBuilder(
                    listenable: state.settings,
                    builder: (context, _) {
                      if (!state.settings.showDemo) {
                        return const SizedBox.shrink();
                      }
                      return _DemoCard(theme: theme);
                    },
                  ),
                ],
              ),
              second: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListenableBuilder(
                    listenable: state.history,
                    builder: (context, _) => _StatsCard(state: state),
                  ),
                  const SizedBox(height: 16),
                  ListenableBuilder(
                    listenable: state.history,
                    builder: (context, _) => _RecentCard(state: state),
                  ),
                  const SizedBox(height: 16),
                  _LimitsCard(theme: theme),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(AppRoutes.payoff),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Send small, open big'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live batch queue summary card.
class _BatchCard extends StatelessWidget {
  /// Creates a batch summary card.
  const _BatchCard({required this.state});

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batch = state.batch;
    final running = batch.items.where(
      (item) => item.status == BatchStatus.encoding,
    );
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () =>
            Navigator.of(context).pushNamed(AppRoutes.batch),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Batch queue', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    '${batch.doneCount} of ${batch.items.length} done',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${batch.items.length} file(s) · '
                '${formatBytes(batch.totalBytes)}',
                style: theme.textTheme.bodyMedium,
              ),
              if (running.isNotEmpty) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: running.first.progress),
                const SizedBox(height: 4),
                Text(
                  '${running.first.name} — ${running.first.progressLabel}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Real stats: encodes, bytes saved, average ratio (demo excluded).
class _StatsCard extends StatelessWidget {
  /// Creates a stats card.
  const _StatsCard({required this.state});

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = state.history;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saved on this device', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat(theme, '${history.encodeCount}', 'encodes'),
                _stat(theme, formatBytes(history.totalSaved), 'saved'),
                _stat(
                  theme,
                  history.encodeCount == 0
                      ? '—'
                      : formatRatio(history.averageRatio),
                  'average',
                ),
              ],
            ),
            if (history.encodeCount == 0) ...[
              const SizedBox(height: 8),
              Text(
                'Encode your first file and the real numbers show up here.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String value, String label) {
    return Column(
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// Recent encodes list (real + demo, demo flagged).
class _RecentCard extends StatelessWidget {
  /// Creates a recent-encodes card.
  const _RecentCard({required this.state});

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = state.history.records.take(5).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Recent', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(AppRoutes.history),
                  child: const Text('See all'),
                ),
              ],
            ),
            if (recent.isEmpty)
              Text(
                'Nothing yet — encodes and decodes land here.',
                style: theme.textTheme.bodySmall,
              ),
            for (final record in recent)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  record.kind == HistoryKind.encode
                      ? Icons.compress
                      : Icons.qr_code_scanner,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.fileName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (record.isDemo) ...[
                      const SizedBox(width: 8),
                      const DemoChip(),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${formatBytes(record.originalBytes)} → '
                  '${formatBytes(record.encodedBytes)} '
                  '(${formatRatio(record.ratio)})',
                ),
                onTap: () => Navigator.of(context).pushNamed(
                  AppRoutes.historyDetail,
                  arguments: record.id,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Seeded demo card — labelled DEMO, never a measurement.
class _DemoCard extends StatelessWidget {
  /// Creates the demo card.
  const _DemoCard({required this.theme});

  /// Theme.
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                DemoChip(),
                SizedBox(width: 8),
                Text('Seeded example'),
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

/// Platform limits card.
class _LimitsCard extends StatelessWidget {
  /// Creates a limits card.
  const _LimitsCard({required this.theme});

  /// Theme.
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
            _limitRow('Native app', '100 GB per file · streaming, local'),
            _limitRow('Web · Local', '10 GB · in-browser, no upload'),
            _limitRow('Web · Cloud', '50 GB · resumable upload'),
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

  Widget _limitRow(String mode, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(mode),
          const Spacer(),
          Flexible(
            child: Text(
              detail,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
