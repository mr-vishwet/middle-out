import 'package:flutter/material.dart';

import '../core/format.dart';
import '../state/encode_controller.dart';

/// Encode result: ratio, frames, hash, PDF size — and Save.
///
/// Shows the 5–20 MB-per-GB band warning when a pathological input (already
/// compressed or random data) pushed the PDF over the band.
class ResultScreen extends StatelessWidget {
  const ResultScreen({required this.controller, super.key});

  final EncodeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = controller.result!;
    final stats = result.stats;
    return Scaffold(
      appBar: AppBar(title: const Text('Encoded')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
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
                Card(
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
                          'SHA-256',
                          shortHash(stats.sha256Hex, groups: 4),
                        ),
                      ],
                    ),
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
                OutlinedButton(
                  onPressed: () {
                    controller.reset();
                    Navigator.of(context).popUntil((route) => route.isFirst);
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
