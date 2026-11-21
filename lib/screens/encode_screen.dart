import 'package:flutter/material.dart';

import '../codec/code_grid.dart';
import '../core/format.dart';
import '../state/encode_controller.dart';
import '../widgets/encryption_toggle.dart';
import '../widgets/format_toggle.dart';
import '../widgets/frame_grid.dart';
import '../widgets/limit_banner.dart';
import 'result_screen.dart';

/// Encode flow: pick a file (limit-gated) -> format + encryption toggles
/// -> encode with progress -> result screen.
///
/// Mirrors the V7 encode screens: file row, mode/limit banner, QR-vs-
/// barcode toggle, encryption toggle (default ON), progress, and a live
/// preview of the first frame's code.
class EncodeScreen extends StatefulWidget {
  const EncodeScreen({super.key});

  @override
  State<EncodeScreen> createState() => _EncodeScreenState();
}

class _EncodeScreenState extends State<EncodeScreen> {
  late final EncodeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = EncodeController();
    _controller.addListener(_onPhaseChange);
  }

  void _onPhaseChange() {
    if (_controller.phase == EncodePhase.done && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ResultScreen(controller: _controller),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onPhaseChange);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Encode')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final encoding =
              _controller.phase == EncodePhase.encoding ||
              _controller.phase == EncodePhase.picking;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LimitBanner(
                  mode: _controller.mode,
                  onModeChanged: _controller.setMode,
                  fileSize: _controller.file?.size,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _controller.file == null
                        ? Column(
                            children: [
                              const Icon(Icons.folder_open, size: 40),
                              const SizedBox(height: 8),
                              const Text('No file picked yet'),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed: encoding
                                    ? null
                                    : _controller.pickFile,
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
                                      _controller.file!.name,
                                      style: theme.textTheme.titleMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: encoding
                                        ? null
                                        : _controller.pickFile,
                                    child: const Text('Change'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                formatBytes(_controller.file!.size),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                FormatToggle(
                  barcode: _controller.barcode,
                  onChanged: _controller.setBarcode,
                ),
                const SizedBox(height: 16),
                EncryptionToggle(
                  encrypted: _controller.encrypted,
                  passphrase: _controller.passphrase,
                  onEncryptedChanged: _controller.setEncrypted,
                  onPassphraseChanged: _controller.setPassphrase,
                ),
                if (_controller.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _controller.error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_controller.phase == EncodePhase.encoding) ...[
                  const SizedBox(height: 24),
                  LinearProgressIndicator(value: _controller.progress),
                  const SizedBox(height: 8),
                  Text(
                    _controller.progressLabel,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (_controller.result != null) ...[
                  const SizedBox(height: 24),
                  Text('First frame', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _FirstFramePreview(controller: _controller),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _controller.file == null || encoding
                      ? null
                      : _controller.encode,
                  child: Text(
                    _controller.phase == EncodePhase.encoding
                        ? 'Encoding…'
                        : 'Encode to PDF',
                  ),
                ),
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
  const _FirstFramePreview({required this.controller});
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
