import 'package:material_ui/material_ui.dart';

import '../codec/code_grid.dart';
import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../state/app_scope.dart';
import '../widgets/frame_grid.dart';

/// The encoded PDF (m08/w08): 1 cover page + 1 full-page code page per
/// frame — and page 1 carries the decoder manifest.
class PdfPreviewScreen extends StatelessWidget {
  /// Creates the PDF preview screen.
  const PdfPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'The PDF',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final result = controller.result;
          final stats = controller.pdfStats;
          if (result == null || stats == null) {
            return EmptyState(
              icon: Icons.picture_as_pdf_outlined,
              headline: 'No PDF yet',
              body: 'Encode a file and the PDF — cover page plus one '
                  'full-page code per frame — shows up here.',
              actionLabel: 'Encode a file',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.encodePick),
            );
          }
          final encodeStats = result.stats;
          final firstRaw = result.frames.first.toBytes();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${stats.pages} pages · ${formatBytes(stats.sizeBytes)}',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '1 cover page + ${result.frames.length} code page(s)',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TwoPane(
                  first: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cover — the decoder manifest',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          _line(theme, 'File', controller.file!.name),
                          _line(
                            theme,
                            'Original size',
                            '${encodeStats.originalSize} bytes',
                          ),
                          _line(
                            theme,
                            'Encoded payload',
                            '${encodeStats.compressedSize} bytes',
                          ),
                          _line(
                            theme,
                            'Ratio',
                            '${encodeStats.ratio.toStringAsFixed(1)}x',
                          ),
                          _line(theme, 'SHA-256', encodeStats.sha256Hex),
                          _line(
                            theme,
                            'Frames',
                            '${encodeStats.frameCount} '
                            '(${encodeStats.groupCount} group(s) of '
                            '6 DATA + 2 PARITY)',
                          ),
                          _line(
                            theme,
                            'Format',
                            result.barcode
                                ? 'Barcode'
                                : 'QR-style grid',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Page 1 carries everything a reader needs: '
                            'scan it with the Middle Out app to verify '
                            'this file.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  second: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'First code page',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      FrameCodeView(
                        grid: result.barcode
                            ? null
                            : CodeGrid.buildGrid(firstRaw),
                        barcodeRows: result.barcode
                            ? CodeGrid.buildBarcodeRows(firstRaw)
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Frame 1 of ${encodeStats.frameCount} · '
                        '${result.frames.first.isData ? 'DATA' : 'PARITY'} · '
                        'Group 1 · '
                        '${formatBytes(result.frames.first.payload.length)}',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                if (controller.savedPath != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Saved: ${controller.savedPath}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: controller.saveResultPdf,
                  icon: const Icon(Icons.save),
                  label: const Text('Save PDF'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
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
                  child: const Text('View all frames'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _line(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}
