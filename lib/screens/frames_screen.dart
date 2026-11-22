import 'package:material_ui/material_ui.dart';

import '../codec/code_grid.dart';
import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../state/app_scope.dart';
import '../widgets/frame_grid.dart';

/// Frames view (m06/w06): the current encode's frames — six hold the
/// file, two hold the parity, per group.
class FramesScreen extends StatelessWidget {
  /// Creates the frames view.
  const FramesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Frames',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final result = controller.result;
          if (result == null) {
            return EmptyState(
              icon: Icons.grid_view,
              headline: 'No frames yet',
              body: 'Encode a file and its frames — data frames plus the '
                  'parity frames that protect them — show up here.',
              actionLabel: 'Encode a file',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.encodePick),
            );
          }
          final dataCount =
              result.frames.where((f) => f.isData).length;
          final parityCount = result.frames.length - dataCount;
          return ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: result.frames.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '$dataCount DATA + $parityCount PARITY frames · '
                    '${result.stats.groupCount} group(s) · '
                    '${formatBytes(result.stats.compressedSize)} of stream',
                    style: theme.textTheme.bodyLarge,
                  ),
                );
              }
              final frame = result.frames[index - 1];
              return Card(
                child: ListTile(
                  leading: Icon(
                    frame.isData ? Icons.grid_view : Icons.shield_outlined,
                    color: frame.isData
                        ? null
                        : theme.colorScheme.primary,
                  ),
                  title: Text(
                    'F${frame.frameIndex + 1} · '
                    '${frame.isData ? 'DATA' : 'PARITY'}',
                  ),
                  subtitle: Text(
                    'Group ${frame.groupIndex + 1} · slot ${frame.slot} · '
                    '${formatBytes(frame.payload.length)} · '
                    'page ${frame.frameIndex + 2} of '
                    '${result.frames.length + 1}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushNamed(
                    AppRoutes.frameDetail,
                    arguments: index - 1,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Frame detail (m07/w07): one frame at full size — density, parity,
/// checksum, and its place in the stream.
class FrameDetailScreen extends StatelessWidget {
  /// Creates a frame detail screen for [frameIndex].
  const FrameDetailScreen({required this.frameIndex, super.key});

  /// Index into the current encode's frame list.
  final int frameIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).encode;
    return AdaptiveScaffold(
      title: 'Frame ${frameIndex + 1}',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final result = controller.result;
          if (result == null ||
              frameIndex < 0 ||
              frameIndex >= result.frames.length) {
            return EmptyState(
              icon: Icons.grid_view,
              headline: 'Frame not found',
              body: 'The encode this frame belonged to is gone — encode a '
                  'file to see its frames.',
              actionLabel: 'Encode a file',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.encodePick),
            );
          }
          final frame = result.frames[frameIndex];
          final raw = frame.toBytes();
          // Stream byte range covered by this DATA frame's payload.
          var streamStart = 0;
          for (var i = 0; i < frameIndex; i++) {
            if (result.frames[i].isData) {
              streamStart += result.frames[i].payload.length;
            }
          }
          final streamEnd = streamStart + frame.payload.length;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TwoPane(
                  first: FrameCodeView(
                    grid: CodeGrid.buildFrameGrid(
                      raw,
                      barcode: result.barcode,
                    ),
                  ),
                  second: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row(
                            theme,
                            'Kind',
                            frame.isData ? 'DATA' : 'PARITY',
                          ),
                          _row(theme, 'Group', '${frame.groupIndex + 1}'),
                          _row(theme, 'Slot', '${frame.slot}'),
                          _row(
                            theme,
                            'Payload',
                            formatBytes(frame.payload.length),
                          ),
                          if (frame.isData)
                            _row(
                              theme,
                              'Stream bytes',
                              '${streamStart + 1}–$streamEnd of '
                              '${result.stats.compressedSize}',
                            ),
                          if (frame.isParity)
                            _row(
                              theme,
                              'Protects',
                              frame.slot == 6
                                  ? 'data slots 0, 1, 2'
                                  : 'data slots 3, 4, 5',
                            ),
                          _row(
                            theme,
                            'PDF page',
                            '${frameIndex + 2} of ${result.frames.length + 1}',
                          ),
                          _row(
                            theme,
                            'Checksum',
                            'Header + payload CRC32 — valid',
                          ),
                          _row(
                            theme,
                            'Encrypted',
                            frame.isEncrypted ? 'Yes' : 'No — plain',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  frame.isData
                      ? 'This frame holds part of the compressed stream. '
                          'Lose it and parity rebuilds it — one lost frame '
                          'per trio.'
                      : 'This frame holds the XOR of its trio. It carries '
                          'no file bytes itself — it rebuilds any one lost '
                          'frame in its trio.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: frameIndex <= 0
                            ? null
                            : () => Navigator.of(context).pushReplacementNamed(
                                  AppRoutes.frameDetail,
                                  arguments: frameIndex - 1,
                                ),
                        child: const Text('Previous frame'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            frameIndex >= result.frames.length - 1
                                ? null
                                : () => Navigator.of(context).pushReplacementNamed(
                                      AppRoutes.frameDetail,
                                      arguments: frameIndex + 1,
                                    ),
                        child: const Text('Next frame'),
                      ),
                    ),
                  ],
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
            width: 110,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
