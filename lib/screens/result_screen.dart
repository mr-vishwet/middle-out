import 'package:material_ui/material_ui.dart';

import '../codec/code_grid.dart';
import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../state/app_scope.dart';
import '../state/encode_controller.dart';
import '../widgets/frame_grid.dart';
import 'shell_screen.dart';

/// Encode result (m05/w05): ratio, frames, hash, PDF size — and Save,
/// Share, Frames, PDF.
///
/// Shows the 5–20 MB-per-GB band warning when a pathological input
/// (already compressed or random data) pushed the PDF over the band.
class ResultScreen extends StatelessWidget {
  /// Creates the encode result screen.
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Encoded',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final result = controller.result;
          if (result == null) {
            return EmptyState(
              icon: Icons.compress,
              headline: 'Nothing encoded yet',
              body: 'Encode a file and the result — ratio, frames, hash, '
                  'PDF size — shows up here.',
              actionLabel: 'Encode a file',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.encodePick),
            );
          }
          final stats = result.stats;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${formatBytes(stats.originalSize)} → '
                  '${formatBytes(stats.compressedSize)}',
                  style: theme.textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '${formatRatio(stats.ratio)} compression · '
                  '${stats.frameCount} frames in ${stats.groupCount} '
                  'group(s) · ${controller.pdfStats!.pages} PDF pages',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TwoPane(
                  first: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row(theme, 'File', controller.file!.name),
                          _row(
                            theme,
                            'Format',
                            controller.barcode ? 'Barcode' : 'QR grid',
                          ),
                          _row(
                            theme,
                            'Encrypted',
                            controller.encrypted ? 'Yes' : 'No — plain',
                          ),
                          _row(
                            theme,
                            'PDF size',
                            formatBytes(controller.pdfStats!.sizeBytes),
                          ),
                          _row(
                            theme,
                            stats.reencode != null
                                ? 'SHA-256 (re-encoded)'
                                : 'SHA-256',
                            shortHash(stats.sha256Hex, groups: 4),
                          ),
                          if (controller.streamed)
                            _row(theme, 'Encoded', 'Streamed off disk'),
                        ],
                      ),
                    ),
                  ),
                  second: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'First frame',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _FirstFramePreview(controller: controller),
                    ],
                  ),
                ),
                if (controller.pdfBandWarning != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    controller.pdfBandWarning!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (stats.reencode != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Re-encoded',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Re-encoded to fit 10:1 — the decoded file '
                            'is a lower-quality copy, not the original.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          _row(
                            theme,
                            'Original',
                            '${stats.reencode!.originalName} · '
                            '${formatBytes(stats.reencode!.originalSizeBytes)}',
                          ),
                          _row(
                            theme,
                            'Re-encoded',
                            '${formatBytes(stats.reencode!.reencodedSizeBytes)} '
                            'with ${stats.reencode!.encoder}',
                          ),
                          _row(
                            theme,
                            'Quality',
                            stats.reencode!.settingsLabel,
                          ),
                          _row(
                            theme,
                            'Original SHA-256',
                            shortHash(
                              stats.reencode!.originalSha256Hex,
                              groups: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (controller.savedPath != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Saved: ${controller.savedPath}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                if (controller.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    controller.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: controller.saveResultPdf,
                  icon: const Icon(Icons.save),
                  label: const Text('Save PDF'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.share,
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.frames,
                  ),
                  child: const Text('View frames'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.pdfPreview,
                  ),
                  child: const Text('View PDF'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    controller.reset();
                    popToShell(context);
                  },
                  child: const Text('Encode another file'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Live preview of the first encoded frame's code.
class _FirstFramePreview extends StatelessWidget {
  /// Creates a first-frame preview.
  const _FirstFramePreview({required this.controller});

  /// Encode controller.
  final EncodeController controller;

  @override
  Widget build(BuildContext context) {
    final result = controller.result!;
    final raw = result.frames.first.toBytes();
    return FrameCodeView(
      grid: CodeGrid.buildFrameGrid(raw, barcode: result.barcode),
    );
  }
}
