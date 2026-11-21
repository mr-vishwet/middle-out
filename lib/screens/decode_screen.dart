import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/routes.dart';
import '../services/file_reader.dart';
import '../state/app_scope.dart';
import '../state/encode_controller.dart';

/// Decode entry (m13/w13): drop any Middle Out PDF — no account needed.
///
/// Three ways in: scan with the camera, import a PDF (frames are
/// recovered from its code images), or import exported `.bin` frame
/// files. The three-step explainer sits beside the actions on web.
class DecodeScreen extends StatelessWidget {
  /// Creates the decode entry screen.
  const DecodeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Decode',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final importing = controller.phase == DecodePhase.importing;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Rebuild the original file from its frames.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'No account needed. Frames can arrive in any order, '
                  'and up to one lost frame per parity trio is rebuilt '
                  'automatically.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                TwoPane(
                  first: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: importing
                            ? null
                            : () => Navigator.of(context)
                                .pushNamed(AppRoutes.decodeScan),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan with camera'),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: importing
                            ? null
                            : () => _importPdf(context, controller),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Import a Middle Out PDF'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: importing
                            ? null
                            : () => _importFrames(context, controller),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Import frame files (.bin)'),
                      ),
                      if (importing) ...[
                        const SizedBox(height: 24),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(
                          'Reading frames…',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
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
                      if (controller.phase == DecodePhase.ready &&
                          controller.inspection != null) ...[
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ready: ${controller.sourceName}',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${controller.inspection!.readableFrames} '
                                  'of ${controller.inspection!.totalFrames} '
                                  'frames readable',
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pushNamed(
                                    AppRoutes.decodeImport,
                                  ),
                                  child: const Text('Continue to import'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  second: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Three steps',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          const _Step(
                            number: '1',
                            title: 'Import',
                            text: 'The PDF is verified and its frames '
                                'read before decode starts.',
                          ),
                          const _Step(
                            number: '2',
                            title: 'Rebuild',
                            text: 'Parity rebuilds damaged frames, then '
                                'the stream is decrypted and decompressed.',
                          ),
                          const _Step(
                            number: '3',
                            title: 'Verify',
                            text: 'The rebuilt file must match the '
                                'SHA-256 in the frame headers — 0 bytes '
                                'differ, or the decode fails.',
                          ),
                        ],
                      ),
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

  Future<void> _importPdf(
    BuildContext context,
    DecodeController controller,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes ??
        (file.path != null ? await readPickedFile(file.path!) : null);
    if (bytes == null) return;
    await controller.importPdf(bytes, file.name);
    if (context.mounted && controller.phase == DecodePhase.ready) {
      Navigator.of(context).pushNamed(AppRoutes.decodeImport);
    }
  }

  Future<void> _importFrames(
    BuildContext context,
    DecodeController controller,
  ) async {
    await controller.importFrameFiles();
    if (context.mounted && controller.phase == DecodePhase.ready) {
      Navigator.of(context).pushNamed(AppRoutes.decodeImport);
    }
  }
}

/// One numbered explainer step.
class _Step extends StatelessWidget {
  /// Creates an explainer step.
  const _Step({
    required this.number,
    required this.title,
    required this.text,
  });

  /// Step number.
  final String number;

  /// Step title.
  final String title;

  /// Step text.
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text(number, style: theme.textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(text, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
