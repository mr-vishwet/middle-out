import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../state/app_scope.dart';
import '../state/batch_controller.dart';
import '../widgets/encryption_toggle.dart';
import '../widgets/format_toggle.dart';

/// Batch queue (m10/w10): several files, each with its own settings,
/// encoded in order.
class BatchScreen extends StatelessWidget {
  /// Creates the batch queue screen.
  const BatchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final batch = state.batch;
    return AdaptiveScaffold(
      title: 'Batch queue',
      body: ListenableBuilder(
        listenable: batch,
        builder: (context, _) {
          if (batch.items.isEmpty) {
            return EmptyState(
              icon: Icons.queue,
              headline: 'Queue is empty',
              body: 'Add files and they encode one after another, each '
                  'with its own format and encryption settings.',
              actionLabel: 'Add files',
              onAction: () => _addFiles(context, state),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${batch.items.length} file(s) · '
                        '${formatBytes(batch.totalBytes)}',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${batch.doneCount} of ${batch.items.length} done',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: batch.running ||
                                      batch.queued.isEmpty
                                  ? null
                                  : batch.runAll,
                              icon: const Icon(Icons.play_arrow),
                              label: Text(
                                batch.running ? 'Running…' : 'Run all',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: batch.running
                                  ? batch.cancel
                                  : () => _addFiles(context, state),
                              icon: Icon(
                                batch.running ? Icons.stop : Icons.add,
                              ),
                              label: Text(
                                batch.running ? 'Stop' : 'Add files',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (batch.doneCount > 0) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: batch.clearDone,
                          child: const Text('Clear finished'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              for (final item in batch.items)
                _BatchItemCard(item: item, state: state),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addFiles(BuildContext context, AppState state) async {
    final rejected =
        await state.batch.addFromPicker(state.encode.mode);
    if (rejected.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rejected.join('\n'))),
      );
    }
  }
}

/// One queue item: status, progress, per-item settings, actions.
class _BatchItemCard extends StatelessWidget {
  /// Creates a batch item card.
  const _BatchItemCard({required this.item, required this.state});

  /// The item.
  final BatchItem item;

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batch = state.batch;
    return Card(
      child: ExpansionTile(
        leading: Icon(
          switch (item.status) {
            BatchStatus.queued => Icons.schedule,
            BatchStatus.encoding => Icons.compress,
            BatchStatus.done => Icons.check_circle,
            BatchStatus.error => Icons.error_outline,
            BatchStatus.cancelled => Icons.cancel_outlined,
          },
          color: switch (item.status) {
            BatchStatus.done => theme.colorScheme.primary,
            BatchStatus.error => theme.colorScheme.error,
            _ => null,
          },
        ),
        title: Text(item.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${formatBytes(item.size)} · '
          '${item.barcode ? 'Barcode' : 'QR grid'} · '
          '${item.encrypted ? 'Encrypted' : 'Plain'}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (item.status == BatchStatus.encoding) ...[
                  LinearProgressIndicator(value: item.progress),
                  const SizedBox(height: 4),
                  Text(
                    item.progressLabel,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                ],
                if (item.status == BatchStatus.done &&
                    item.result != null) ...[
                  Text(
                    '${formatBytes(item.result!.stats.originalSize)} → '
                    '${formatBytes(item.result!.stats.compressedSize)} '
                    '(${formatRatio(item.result!.stats.ratio)}) · '
                    '${item.result!.stats.frameCount} frames',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => batch.shareItemPdf(item.id),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Share PDF'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (item.error != null) ...[
                  Text(
                    item.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (item.status == BatchStatus.queued ||
                    item.status == BatchStatus.error) ...[
                  FormatToggle(
                    barcode: item.barcode,
                    onChanged: (value) => batch.updateOptions(
                      item.id,
                      barcode: value,
                    ),
                  ),
                  const SizedBox(height: 8),
                  EncryptionToggle(
                    encrypted: item.encrypted,
                    passphrase: item.passphrase,
                    onEncryptedChanged: (value) => batch.updateOptions(
                      item.id,
                      encrypted: value,
                    ),
                    onPassphraseChanged: (value) => batch.updateOptions(
                      item.id,
                      passphrase: value,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: batch.running
                              ? null
                              : () => batch.runOne(item.id),
                          child: const Text('Encode now'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => batch.remove(item.id),
                          child: const Text('Remove'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (item.status == BatchStatus.done)
                  TextButton(
                    onPressed: () => batch.remove(item.id),
                    child: const Text('Remove from queue'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
