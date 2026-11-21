import '../core/constants.dart';
import 'encoder.dart';

/// Progress callback for streaming encodes: [fraction] 0..1 and a
/// human-readable stage label.
typedef StreamingProgress = void Function(double fraction, String label);

/// Streaming encode is unavailable on this platform (web): files have no
/// paths, so the in-memory path is used instead.
class StreamingEncoder {
  /// False on platforms without file access.
  static bool get isSupported => false;

  /// Always throws [UnsupportedError] on this platform.
  static Future<EncodeResult> encodeFile({
    required String path,
    String? passphrase,
    int maxPayload = kDefaultMaxPayload,
    bool barcode = false,
    StreamingProgress? onProgress,
  }) async {
    throw UnsupportedError(
      'Streaming encode needs file access (native platforms); '
      'this platform encodes in memory.',
    );
  }
}
