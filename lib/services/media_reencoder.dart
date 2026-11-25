/// The platform media re-encoder: the stub everywhere except web,
/// where Worker C lands the real WebCodecs encoder in
/// `media_reencoder_web.dart`.
library;
export 'media_reencoder_stub.dart'
    if (dart.library.js_interop) 'media_reencoder_web.dart';
