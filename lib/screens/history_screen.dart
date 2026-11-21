import 'package:flutter/foundation.dart' hide shortHash;
import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../services/file_reader.dart';
import '../services/share_service.dart';
import '../state/app_scope.dart';
import '../state/history_store.dart';

/// History (m11/w11): the stats row and the recent-encodes table.
///
/// Stats cover real records only. Demo records show with a DEMO chip
/// and can be hidden from Settings.
class HistoryScreen extends StatefulWidget {
  /// Creates the history screen.
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryKind? _filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'History',
      body: ListenableBuilder(
        listenable: state.history,
        builder: (context, _) {
          final showDemo = state.settings.showDemo;
          final records = [
            for (final record in state.history.records)
              if ((showDemo || !record.isDemo) &&
                  (_filter == null || record.kind == _filter))
                record,
          ];
          final history = state.history;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _stat(theme, '${history.encodeCount}', 'encodes'),
                      _stat(
                        theme,
                        formatBytes(history.totalSaved),
                        'saved',
                      ),
                      _stat(
                        theme,
                        history.encodeCount == 0
                            ? '—'
                            : formatRatio(history.averageRatio),
                        'average',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  ChoiceChip(
                    label: const Text('Encodes'),
                    selected: _filter == HistoryKind.encode,
                    onSelected: (_) =>
                        setState(() => _filter = HistoryKind.encode),
                  ),
                  ChoiceChip(
                    label: const Text('Decodes'),
                    selected: _filter == HistoryKind.decode,
                    onSelected: (_) =>
                        setState(() => _filter = HistoryKind.decode),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (records.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Text(
                    'Nothing here yet — encodes and decodes land here.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final record in records)
                Card(
                  child: ListTile(
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
                      '(${formatRatio(record.ratio)}) · '
                      '${record.frameCount} frames · '
                      '${_dateLabel(record.createdAt)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pushNamed(
                      AppRoutes.historyDetail,
                      arguments: record.id,
                    ),
                  ),
                ),
            ],
          );
        },
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

  String _dateLabel(DateTime date) =>
      '${date.day}/${date.month}/${date.year}';
}

/// History detail (m12/w12): one record, full width.
class HistoryDetailScreen extends StatelessWidget {
  /// Creates a history detail screen for [recordId].
  const HistoryDetailScreen({required this.recordId, super.key});

  /// Id of the record to show.
  final String recordId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'History detail',
      body: ListenableBuilder(
        listenable: state.history,
        builder: (context, _) {
          final record = state.history.byId(recordId);
          if (record == null) {
            return EmptyState(
              icon: Icons.history,
              headline: 'Record not found',
              body: 'It may have been deleted.',
              actionLabel: 'Back to history',
              onAction: () => Navigator.of(context).pop(),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.fileName,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (record.isDemo) const DemoChip(),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${formatBytes(record.originalBytes)} → '
                  '${formatBytes(record.encodedBytes)}',
                  style: theme.textTheme.displaySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${formatRatio(record.ratio)} compression · '
                  '${record.frameCount} frames in ${record.groupCount} '
                  'group(s)',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row(
                          theme,
                          'Type',
                          record.kind == HistoryKind.encode
                              ? 'Encode'
                              : 'Decode',
                        ),
                        _row(
                          theme,
                          'Format',
                          record.barcode ? 'Barcode' : 'QR grid',
                        ),
                        _row(
                          theme,
                          'Encrypted',
                          record.encrypted ? 'Yes' : 'No — plain',
                        ),
                        _row(
                          theme,
                          'SHA-256',
                          shortHash(record.sha256Hex, groups: 4),
                        ),
                        _row(
                          theme,
                          'Date',
                          '${record.createdAt.day}/${record.createdAt.month}/'
                          '${record.createdAt.year}',
                        ),
                        _row(
                          theme,
                          'Decoded',
                          record.decodeCount == 0
                              ? 'Not decoded back yet'
                              : '${record.decodeCount} time(s), byte-exact',
                        ),
                        if (record.savedPath != null)
                          _row(theme, 'Saved PDF', record.savedPath!),
                        if (record.migrated)
                          _row(theme, 'Account', 'Migrated'),
                      ],
                    ),
                  ),
                ),
                if (record.isDemo) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Seeded example from the design — not a measurement. '
                    'Hide demo records from Settings.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                if (record.savedPath != null && !kIsWeb) ...[
                  FilledButton.icon(
                    onPressed: () => _shareSavedPdf(context, record),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share saved PDF'),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed: () async {
                    await state.history.remove(record.id);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete record'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _shareSavedPdf(
    BuildContext context,
    HistoryRecord record,
  ) async {
    final path = record.savedPath;
    if (path == null) return;
    try {
      final bytes = await readPickedFile(path);
      await ShareService.sharePdf(
        bytes,
        '${record.fileName}.middleout.pdf',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the saved PDF: $e')),
        );
      }
    }
  }

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
