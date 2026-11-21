import 'package:flutter/material.dart';

import '../codec/code_grid.dart';
import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../services/platform_limits.dart';
import '../state/app_scope.dart';
import '../state/encode_controller.dart';
import '../widgets/encryption_toggle.dart';
import '../widgets/format_toggle.dart';
import '../widgets/frame_grid.dart';
import '../widgets/limit_banner.dart';

/// File picker (m02/w02): the platform limit is printed on the picker,
/// and over-limit files route to the mode that can hold them.
class PickerScreen extends StatelessWidget {
  /// Creates the file picker screen.
  const PickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Encode',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final picking = controller.phase == EncodePhase.picking;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LimitBanner(
                  mode: controller.mode,
                  onModeChanged: controller.setMode,
                  fileSize: controller.file?.size,
                ),
                const SizedBox(height: 16),
                TwoPane(
                  first: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: controller.file == null
                          ? Column(
                              children: [
                                const Icon(Icons.folder_open, size: 40),
                                const SizedBox(height: 8),
                                const Text('No file picked yet'),
                                const SizedBox(height: 4),
                                Text(
                                  'Up to ${formatBytes(controller.mode.maxBytes)} '
                                  'in ${controller.mode.label} mode.',
                                  style: theme.textTheme.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed:
                                      picking ? null : controller.pickFile,
                                  child: const Text('Pick a file'),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.insert_drive_file),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        controller.file!.name,
                                        style: theme.textTheme.titleMedium,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: picking
                                          ? null
                                          : controller.pickFile,
                                      child: const Text('Change'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  formatBytes(controller.file!.size),
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pushNamed(
                                    AppRoutes.encodePre,
                                  ),
                                  child: const Text('Continue'),
                                ),
                              ],
                            ),
                    ),
                  ),
                  second: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'How it works',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const _Step(
                            number: '1',
                            text: 'Pick a file. The limit for your '
                                'platform is printed above.',
                          ),
                          const _Step(
                            number: '2',
                            text: 'Choose QR grid or barcode, and whether '
                                'to encrypt (on by default).',
                          ),
                          const _Step(
                            number: '3',
                            text: 'Middle Out compresses, encrypts, '
                                'frames and builds the PDF — 1 cover page '
                                'plus 1 page per frame.',
                          ),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: () => Navigator.of(context)
                                .pushNamed(AppRoutes.batch),
                            icon: const Icon(Icons.queue),
                            label: const Text(
                              'Encoding several files? Use the batch queue',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (controller.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    controller.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  if (controller.file != null &&
                      !PlatformLimitsService.fits(
                        controller.file!.size,
                        controller.mode,
                      ))
                    TextButton(
                      onPressed: () => Navigator.of(context).pushNamed(
                        AppRoutes.authUpgrade,
                        arguments: controller.file!.size,
                      ),
                      child: const Text('What are my options?'),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One numbered explainer step.
class _Step extends StatelessWidget {
  /// Creates an explainer step.
  const _Step({required this.number, required this.text});

  /// Step number.
  final String number;

  /// Step text.
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text(number, style: theme.textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Pre-encode (m03/w03): the estimate, the format toggle, the encryption
/// toggle — then Encode.
class PreEncodeScreen extends StatelessWidget {
  /// Creates the pre-encode screen.
  const PreEncodeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Pre-encode',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final file = controller.file;
          if (file == null) {
            return EmptyState(
              icon: Icons.folder_open,
              headline: 'No file picked',
              body: 'Pick a file first, then come back for the estimate '
                  'and the encode options.',
              actionLabel: 'Pick a file',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.encodePick),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TwoPane(
                  first: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                file.name,
                                style: theme.textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${formatBytes(file.size)} · '
                                '${controller.mode.label} mode',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (controller.estimate != null) ...[
                                const SizedBox(height: 12),
                                const Divider(),
                                const SizedBox(height: 12),
                                _EstimateRows(controller: controller),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FormatToggle(
                        barcode: controller.barcode,
                        onChanged: controller.setBarcode,
                      ),
                    ],
                  ),
                  second: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      EncryptionToggle(
                        encrypted: controller.encrypted,
                        passphrase: controller.passphrase,
                        onEncryptedChanged: controller.setEncrypted,
                        onPassphraseChanged: controller.setPassphrase,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Verify is always on: the decoded file must match '
                        'the SHA-256 in the frame headers, or the decode '
                        'fails loudly.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
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
                FilledButton(
                  onPressed: () {
                    Navigator.of(context)
                        .pushNamed(AppRoutes.encodeProgress);
                  },
                  child: const Text('Encode to PDF'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Estimate rows: ratio, frames, PDF size, time.
class _EstimateRows extends StatelessWidget {
  /// Creates estimate rows.
  const _EstimateRows({required this.controller});

  /// Encode controller.
  final EncodeController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final estimate = controller.estimate!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Estimate', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _row(theme, 'Ratio', formatRatio(estimate.ratio)),
        _row(theme, 'Frames', '${estimate.estimatedFrames}'),
        _row(
          theme,
          'PDF size',
          'about ${formatBytes(estimate.estimatedPdfBytes)}',
        ),
        _row(
          theme,
          'Time',
          'about ${formatDuration(estimate.estimatedSeconds)}',
        ),
        const SizedBox(height: 4),
        Text(
          'Measured on a ${formatBytes(estimate.sampleBytes)} sample and '
          'extrapolated — real ratios depend on the file.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const Spacer(),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Encoding progress (m04/w04): progress, stage, and the frame strip.
///
/// Starts the encode on entry (when the flow is ready) and moves to the
/// result screen on success.
class EncodingScreen extends StatefulWidget {
  /// Creates the encoding progress screen.
  const EncodingScreen({super.key});

  @override
  State<EncodingScreen> createState() => _EncodingScreenState();
}

class _EncodingScreenState extends State<EncodingScreen> {
  EncodeController? _controller;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= AppScope.of(context).encode;
    final controller = _controller!;
    controller.removeListener(_onPhaseChange);
    controller.addListener(_onPhaseChange);
    if (!_started && controller.phase == EncodePhase.ready) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.encode();
      });
    }
  }

  void _onPhaseChange() {
    if (!mounted) return;
    if (_controller!.phase == EncodePhase.done) {
      Navigator.of(context)
          .pushReplacementNamed(AppRoutes.encodeResult);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPhaseChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Encoding',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final encoding = controller.phase == EncodePhase.encoding;
          final percent = (controller.progress * 100).round();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.file != null) ...[
                  Text(
                    controller.file!.name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatBytes(controller.file!.size),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                ],
                Text(
                  '$percent%',
                  style: theme.textTheme.displaySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: controller.progress),
                const SizedBox(height: 8),
                Text(
                  controller.progressLabel,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                if (controller.streamed) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Streaming off disk — the file is never loaded whole.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (controller.estimate != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    'About ${controller.estimate!.estimatedFrames} frames · '
                    'about ${formatBytes(controller.estimate!.estimatedPdfBytes)}',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (controller.result != null) ...[
                  const SizedBox(height: 24),
                  Text('First frame', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _FirstFramePreview(controller: controller),
                ],
                if (controller.error != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    controller.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back to pre-encode'),
                  ),
                ],
                if (encoding) ...[
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: () {
                      controller.reset();
                      Navigator.of(context).pop();
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),
          );
        },
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
    if (result.barcode) {
      return FrameCodeView(
        grid: null,
        barcodeRows: CodeGrid.buildBarcodeRows(raw),
      );
    }
    return FrameCodeView(grid: CodeGrid.buildGrid(raw));
  }
}
