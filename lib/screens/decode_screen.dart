import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../services/file_reader.dart';
import '../state/encode_controller.dart';

/// Decode flow: import frame files -> passphrase (if encrypted) -> rebuild
/// the original, SHA-256 verified.
///
/// v0.1 decodes from exported frame files (`.bin`, one per frame, any
/// order — the frame header carries the index). Scanning frames straight
/// from a printed or on-screen PDF via the camera is the v0.2 milestone;
/// the decoder it feeds on is already complete.
class DecodeScreen extends StatefulWidget {
  const DecodeScreen({super.key});

  @override
  State<DecodeScreen> createState() => _DecodeScreenState();
}

class _DecodeScreenState extends State<DecodeScreen> {
  late final DecodeController _controller;
  List<Uint8List> _blobs = [];
  int _frameCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = DecodeController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickFrames() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bin'],
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final blobs = <Uint8List>[];
    for (final file in result.files) {
      if (file.bytes != null) {
        blobs.add(file.bytes!);
      } else if (file.path != null) {
        blobs.add(await readPickedFile(file.path!));
      }
    }
    setState(() {
      _blobs = blobs;
      _frameCount = blobs.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Decode')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final decoding = _controller.phase == DecodePhase.decoding;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Rebuild the original file from its frames.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Icon(Icons.qr_code_2, size: 40),
                        const SizedBox(height: 8),
                        Text(
                          _frameCount == 0
                              ? 'No frames imported yet'
                              : '$_frameCount frame file(s) imported',
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: decoding ? null : _pickFrames,
                          child: const Text('Import frame files (.bin)'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Passphrase (if the frames are encrypted)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _controller.setPassphrase,
                ),
                const SizedBox(height: 16),
                Text(
                  'Frames can arrive in any order, and up to one lost frame '
                  'per parity trio is rebuilt automatically. The result is '
                  'verified against the SHA-256 in the frame headers before '
                  'anything is shown as decoded.',
                  style: theme.textTheme.bodySmall,
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
                if (decoding) ...[
                  const SizedBox(height: 24),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    'Rebuilding… parity recovery, decrypt, verify.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (_controller.phase == DecodePhase.done) ...[
                  const SizedBox(height: 24),
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.verified),
                              const SizedBox(width: 8),
                              Text(
                                'Verified bit-for-bit',
                                style: theme.textTheme.titleMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${_controller.decodedName} · '
                            '${formatBytes(_controller.decoded!.length)}',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'SHA-256 matched the frame headers. '
                            'Saving the rebuilt file to storage ships in v0.2.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _blobs.isEmpty || decoding
                      ? null
                      : () => _controller.decodeFrames(_blobs),
                  child: Text(decoding ? 'Decoding…' : 'Decode'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
