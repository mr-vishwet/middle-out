import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/routes.dart';

/// Camera scan: live preview + capture for decoding printed or on-screen
/// frames.
///
/// Phase 1 ships the capture UI: the preview runs, a photo is captured
/// and shown. Sampling code modules out of a photo (perspective
/// correction + finder detection) is the phase-2 milestone — the screen
/// says so and routes to the working paths (import the PDF, or import
/// frame files) instead of pretending the photo decoded.
class ScanScreen extends StatefulWidget {
  /// Creates the camera scan screen.
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _camera;
  XFile? _captured;
  String? _error;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _error = 'No camera found on this device.';
          _initializing = false;
        });
        return;
      }
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open the camera: $e';
        _initializing = false;
      });
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    try {
      final file = await camera.takePicture();
      setState(() => _captured = file);
    } catch (e) {
      setState(() => _error = 'Could not capture a photo: $e');
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AdaptiveScaffold(
      title: 'Scan frames',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_initializing) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              Text(
                'Opening the camera…',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ] else if (_error != null && _camera == null) ...[
              EmptyState(
                icon: Icons.camera_alt_outlined,
                headline: 'Camera unavailable',
                body: _error!,
                actionLabel: 'Import a PDF instead',
                onAction: () =>
                    Navigator.of(context).pop(),
              ),
            ] else if (_captured != null) ...[
              _CapturedPhoto(file: _captured!),
              const SizedBox(height: 16),
              Text(
                'Photo captured. Sampling frames out of a photo — '
                'perspective correction plus finder detection — ships in '
                'phase 2. To decode today, import the PDF itself.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Import the PDF instead'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => setState(() => _captured = null),
                child: const Text('Take another photo'),
              ),
            ] else ...[
              AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: CameraPreview(_camera!),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Point the camera at a code page. Frame it straight, '
                'fill the view, and keep it steady.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _capture,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Capture frame'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).popAndPushNamed(AppRoutes.decode),
                child: const Text('Import a PDF instead'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The captured photo, shown after capture (bytes, so it works on web
/// and native alike).
class _CapturedPhoto extends StatelessWidget {
  /// Creates a captured-photo view.
  const _CapturedPhoto({required this.file});

  /// The captured image file.
  final XFile file;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: FutureBuilder(
          future: file.readAsBytes(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return Image.memory(snapshot.data!, fit: BoxFit.cover);
          },
        ),
      ),
    );
  }
}
