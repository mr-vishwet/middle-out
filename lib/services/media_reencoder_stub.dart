import 'dart:typed_data';

import '../codec/reencode.dart';

/// Stub media re-encoder: re-encoding is not available on this
/// platform. The encode flow treats it honestly — a re-encode proposal
/// can never be confirmed against this stub, because [reencode] throws
/// instead of pretending to work. Worker C replaces the web file
/// (`media_reencoder_web.dart`) with the real WebCodecs encoder.
class StubMediaReencoder implements MediaReencoder {
  @override
  bool get isAvailable => false;

  @override
  String get encoderName => '';

  @override
  Future<ReencodePlan?> plan(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
  }) async =>
      null;

  @override
  Future<ReencodedMedia?> reencode(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
    ReencodeProgress? onProgress,
  }) async {
    throw const ReencodeException(
      'Re-encoding is not available on this device.',
    );
  }
}

/// Creates the platform media re-encoder (the stub on this platform).
MediaReencoder createMediaReencoder() => StubMediaReencoder();
