/// Streaming encode: the same pipeline as [Encoder], run chunk-by-chunk
/// off disk so a large native file is never loaded whole.
///
/// The real implementation lives in `streaming_encoder_io.dart` (native
/// platforms, via dart:io); the stub throws on web, where files have no
/// paths and the in-memory path is used instead.
export 'streaming_encoder_stub.dart'
    if (dart.library.io) 'streaming_encoder_io.dart';
