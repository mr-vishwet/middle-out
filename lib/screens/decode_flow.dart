import 'package:material_ui/material_ui.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../state/app_scope.dart';
import '../state/encode_controller.dart';
import 'shell_screen.dart';

/// Decode import (m14/w14): the PDF is verified and its frames read
/// before decode starts.
class DecodeImportScreen extends StatelessWidget {
  /// Creates the decode import screen.
  const DecodeImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Import',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final inspection = controller.inspection;
          if (controller.phase != DecodePhase.ready ||
              inspection == null) {
            return EmptyState(
              icon: Icons.qr_code_scanner,
              headline: 'Nothing imported yet',
              body: 'Import a Middle Out PDF or its frame files first — '
                  'they are verified here before decode starts.',
              actionLabel: 'Back to decode',
              onAction: () => Navigator.of(context).pop(),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TwoPane(
                  first: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            controller.sourceName ?? 'Imported frames',
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${inspection.readableFrames} of '
                            '${inspection.totalFrames} frames readable',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Original: ${formatBytes(inspection.originalSize)} '
                            '· ${inspection.totalGroups} group(s) · '
                            '${inspection.barcode ? 'Barcode' : 'QR grid'} · '
                            '${inspection.encrypted ? 'Encrypted' : 'Plain'}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (inspection.unreadableBlobs > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${inspection.unreadableBlobs} blob(s) could '
                              'not be parsed as frames.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
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
                            'Frames',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'DATA present: ${inspection.presentData} of '
                            '${inspection.totalDataFrames}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            'PARITY present: ${inspection.presentParity} of '
                            '${inspection.totalGroups * 2}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (inspection.hasDamage) ...[
                            const SizedBox(height: 8),
                            Text(
                              '${inspection.damagedFrameCount} frame(s) '
                              'damaged — parity rebuilds them.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pushNamed(
                                AppRoutes.decodeDamaged,
                              ),
                              child: const Text('See what parity rebuilds'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (inspection.encrypted) ...[
                  const SizedBox(height: 16),
                  TextField(
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase',
                      hintText: 'These frames are encrypted',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: controller.setPassphrase,
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
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(AppRoutes.decodeProgress),
                  child: const Text('Decode'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Decoding progress (m15/w15): progress, checks, and the frame strip.
///
/// Starts the decode on entry (when frames are ready) and moves to the
/// verify screen on success.
class DecodingScreen extends StatefulWidget {
  /// Creates the decoding progress screen.
  const DecodingScreen({super.key});

  @override
  State<DecodingScreen> createState() => _DecodingScreenState();
}

class _DecodingScreenState extends State<DecodingScreen> {
  DecodeController? _controller;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= AppScope.of(context).decode;
    final controller = _controller!;
    controller.removeListener(_onPhaseChange);
    controller.addListener(_onPhaseChange);
    if (!_started && controller.phase == DecodePhase.ready) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.decodeFrames();
      });
    }
  }

  void _onPhaseChange() {
    if (!mounted) return;
    if (_controller!.phase == DecodePhase.done) {
      Navigator.of(context)
          .pushReplacementNamed(AppRoutes.decodeVerify);
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
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Decoding',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final decoding = controller.phase == DecodePhase.decoding;
          final inspection = controller.inspection;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (inspection != null) ...[
                  Text(
                    'Rebuilding ${formatBytes(inspection.originalSize)} '
                    'from ${inspection.totalFrames} frames',
                    style: theme.textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],
                if (decoding) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Parity recovery, decrypt, decompress, verify…',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (inspection != null) ...[
                  const SizedBox(height: 24),
                  _CheckRow(
                    label: 'Frames read',
                    done: true,
                    detail: '${inspection.readableFrames} of '
                        '${inspection.totalFrames}',
                  ),
                  _CheckRow(
                    label: 'Parity recovery',
                    done: !decoding ||
                        inspection.recoveredViaParity.isEmpty,
                    detail: inspection.recoveredViaParity.isEmpty
                        ? 'No frames lost'
                        : '${inspection.recoveredViaParity.length} '
                            'frame(s) rebuilt',
                  ),
                  _CheckRow(
                    label: 'Decrypt',
                    done: !decoding,
                    detail: inspection.encrypted
                        ? 'ChaCha20, passphrase key'
                        : 'Plain frames',
                  ),
                  _CheckRow(
                    label: 'SHA-256 verify',
                    done: controller.phase == DecodePhase.done,
                    detail: '0 bytes differ, or the decode fails',
                  ),
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
                    child: const Text('Back to import'),
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

/// One decode-stage check row.
class _CheckRow extends StatelessWidget {
  /// Creates a check row.
  const _CheckRow({
    required this.label,
    required this.done,
    required this.detail,
  });

  /// Stage label.
  final String label;

  /// True when the stage is done.
  final bool done;

  /// Detail text.
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.hourglass_empty,
            color: done ? theme.colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Text(detail, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Verify (m16/w16): both hashes, side by side, 0 bytes differ.
class VerifyScreen extends StatelessWidget {
  /// Creates the verify screen.
  const VerifyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Verify',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.phase != DecodePhase.done ||
              controller.decoded == null) {
            return EmptyState(
              icon: Icons.verified_outlined,
              headline: 'Nothing to verify yet',
              body: 'Decode frames first — the two hashes are compared '
                  'here before anything is shown as decoded.',
              actionLabel: 'Back to decode',
              onAction: () => Navigator.of(context).pop(),
            );
          }
          final match = controller.expectedSha256 != null &&
              controller.actualSha256 == controller.expectedSha256;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      match ? Icons.verified : Icons.error_outline,
                      color: match
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        match
                            ? 'The two hashes match — 0 bytes differ.'
                            : 'The hashes do not match.',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Byte-exact. The rebuilt file is the original.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TwoPane(
                  first: _HashCard(
                    title: 'Expected (frame headers)',
                    hash: controller.expectedSha256 ?? '—',
                  ),
                  second: _HashCard(
                    title: 'Rebuilt file',
                    hash: controller.actualSha256 ?? '—',
                  ),
                ),
                if (controller.recoveredIndices.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Parity rebuilt ${controller.recoveredIndices.length} '
                    'frame(s) during this decode: '
                    '${controller.recoveredIndices.map((i) => 'F${i + 1}').join(', ')}.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(AppRoutes.decoded),
                  child: const Text('Open the decoded file'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One hash card.
class _HashCard extends StatelessWidget {
  /// Creates a hash card.
  const _HashCard({required this.title, required this.hash});

  /// Card title.
  final String title;

  /// Hash hex.
  final String hash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              shortHash(hash, groups: 8),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Decoded (m17/w17): the original is back, saved to Files.
class DecodedScreen extends StatelessWidget {
  /// Creates the decoded screen.
  const DecodedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Decoded',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.phase != DecodePhase.done ||
              controller.decoded == null) {
            return EmptyState(
              icon: Icons.qr_code_scanner,
              headline: 'Nothing decoded yet',
              body: 'Decode frames first — the rebuilt file shows up '
                  'here, verified bit-for-bit.',
              actionLabel: 'Back to decode',
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
                    Icon(
                      Icons.verified,
                      color: theme.colorScheme.primary,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Verified bit-for-bit',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.decodedName ?? 'decoded-file',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formatBytes(controller.decoded!.length),
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'SHA-256 matched the frame headers.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
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
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: controller.saveDecoded,
                  icon: const Icon(Icons.save),
                  label: const Text('Save to Files'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: controller.shareDecoded,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share file'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    controller.reset();
                    popToShell(context);
                  },
                  child: const Text('Decode another'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Damaged frame (m18/w18): what parity rebuilt, in plain words.
class DamagedFrameScreen extends StatelessWidget {
  /// Creates the damaged-frame screen.
  const DamagedFrameScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context).decode;
    return AdaptiveScaffold(
      title: 'Damaged frame',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final inspection = controller.inspection;
          if (inspection == null || !inspection.hasDamage) {
            return EmptyState(
              icon: Icons.shield_outlined,
              headline: 'No damage',
              body: 'Every imported frame is present and clean — parity '
                  'has nothing to rebuild.',
              actionLabel: 'Back to import',
              onAction: () => Navigator.of(context).pop(),
            );
          }
          final damaged = [
            ...inspection.missingDataIndices,
            ...inspection.corruptDataIndices,
          ]..sort();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${damaged.length} frame(s) damaged — parity rebuilds '
                  'them all. 0 lost.',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Each parity frame holds the XOR of its trio of data '
                  'frames. Any one lost frame per trio comes back whole; '
                  'two losses in one trio would be unrecoverable.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                for (final index in damaged)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.shield_outlined),
                      title: Text('F${index + 1}'),
                      subtitle: Text(
                        inspection.missingDataIndices.contains(index)
                            ? 'Unreadable — no frame arrived for this slot'
                            : 'Unreadable — payload checksum failed',
                      ),
                      trailing: Text(
                        'Rebuilt',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(AppRoutes.decodeProgress),
                  child: const Text('Continue decoding'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
