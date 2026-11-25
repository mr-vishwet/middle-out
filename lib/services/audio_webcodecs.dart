/// Minimal `dart:js_interop` bindings for the WebCodecs AUDIO API
/// ([AudioEncoder], [AudioDecoder], [AudioData],
/// [EncodedAudioChunk]).
///
/// `package:web` 1.1.x only binds the VIDEO WebCodecs classes, so the
/// audio side is hand-rolled here as thin extension types over
/// `JSObject`. Only the surface the re-encoder needs is bound:
/// configure / encode / decode / flush / close, the output + error
/// callbacks, `isConfigSupported`, and the chunk fields the muxer
/// needs (`byteLength`, `timestamp`, `duration`, `copyTo`).
///
/// All audio data is passed through as opaque `JSObject`s — no
/// per-sample Dart copies — except encoded chunks, which are copied
/// out with `copyTo` exactly like the video path.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Builds a plain JS object from [values]. There is no `Map.toJS`
/// in `dart:js_interop` — objects are built with `JSObject()` +
/// `setProperty`, and every value must already be a [JSAny]
/// (strings via `'x'.toJS`, numbers via `(n).toJS`, byte arrays via
/// `bytes.toJS`, callbacks via `(closure).toJS`).
JSObject _jsObject(Map<String, JSAny?> values) {
  final obj = JSObject();
  values.forEach((key, value) {
    if (value != null) obj.setProperty(key.toJS, value);
  });
  return obj;
}

/// True when the `AudioEncoder` global exists in this browser.
bool get hasAudioEncoder =>
    _globalOrNull('AudioEncoder') != null &&
    _globalOrNull('AudioDecoder') != null;

JSAny? _globalOrNull(String name) {
  try {
    final value = globalContext.getProperty(name.toJS);
    if (value == null || value.isUndefinedOrNull) return null;
    return value;
  } catch (_) {
    return null;
  }
}

/// Probes `AudioEncoder.isConfigSupported` for AAC-LC at the given
/// parameters. Returns false when the API is absent or the config is
/// rejected — never throws.
Future<bool> probeAudioEncoder({
  required int sampleRate,
  required int channels,
  required int bitrate,
}) async {
  try {
    if (!hasAudioEncoder) return false;
    final config = _jsObject({
      'codec': 'mp4a.40.2'.toJS,
      'sampleRate': sampleRate.toJS,
      'numberOfChannels': channels.toJS,
      'bitrate': bitrate.toJS,
    });
    final support = await JsAudioEncoder.isConfigSupported(config).toDart;
    final supported = support.getProperty('supported'.toJS);
    return supported is JSBoolean && supported.toDart;
  } catch (_) {
    return false;
  }
}

/// One encoded audio chunk, copied out of the encoder callback.
class JsAudioChunk {
  /// Creates an encoded audio chunk.
  JsAudioChunk(this.data, this.timestampUs, this.durationUs);

  /// The raw AAC frame bytes.
  final Uint8List data;

  /// Presentation timestamp, microseconds.
  final int timestampUs;

  /// Presentation duration, microseconds.
  final int durationUs;
}

/// An [AudioEncoder] plus everything it emitted.
class JsAudioEncoderSink {
  /// Creates a sink around an [AudioEncoder] with its callbacks wired.
  JsAudioEncoderSink({required this.encoder});

  /// The underlying encoder.
  final JsAudioEncoder encoder;

  /// Encoded chunks, in output order.
  final List<JsAudioChunk> chunks = [];

  /// AudioSpecificConfig from the first chunk's `decoderConfig`,
  /// needed for the `esds` box in the muxer.
  Uint8List? description;

  /// Encoder errors (empty on success).
  final List<String> errors = [];

  /// Total encoded bytes.
  int get totalBytes => chunks.fold(0, (s, c) => s + c.data.length);
}

/// Creates an AAC [AudioEncoder] wired to [sink], configured at
/// [sampleRate]/[channels]/[bitrate]. The caller must [close] it
/// (via [JsAudioEncoder.close]) after flushing.
JsAudioEncoderSink makeAacEncoder({
  required int sampleRate,
  required int channels,
  required int bitrate,
}) {
  late final JsAudioEncoderSink sink;
  final encoder = JsAudioEncoder(
    _jsObject({
      'output': ((JSObject chunk, JSObject metadata) {
        final c = chunk as JsEncodedAudioChunk;
        final buf = JSUint8Array.withLength(c.byteLength);
        c.copyTo(buf);
        sink.chunks.add(
          JsAudioChunk(
            buf.toDart,
            c.timestamp,
            c.duration ?? 0,
          ),
        );
        if (sink.description == null) {
          try {
            final dc = metadata.getProperty('decoderConfig'.toJS);
            if (dc is JSObject) {
              final desc = dc.getProperty('description'.toJS);
              if (desc is JSArrayBuffer) {
                sink.description = Uint8List.view(desc.toDart);
              }
            }
          } catch (_) {
            // Best-effort; the mux step reports a missing ASC.
          }
        }
      }).toJS,
      'error': ((JSObject e) {
        sink.errors.add(_jsErrorString(e));
      }).toJS,
    }),
  );
  sink = JsAudioEncoderSink(encoder: encoder);
  encoder.configure(
    _jsObject({
      'codec': 'mp4a.40.2'.toJS,
      'sampleRate': sampleRate.toJS,
      'numberOfChannels': channels.toJS,
      'bitrate': bitrate.toJS,
    }),
  );
  return sink;
}

/// Creates an AAC [AudioDecoder] that hands each decoded [AudioData]
/// to [onData]. The caller must [close] it after flushing.
JsAudioDecoder makeAacDecoder({
  required int sampleRate,
  required int channels,
  required Uint8List asc,
  required void Function(JSObject audioData) onData,
  required void Function(String error) onError,
}) {
  final decoder = JsAudioDecoder(
    _jsObject({
      'output': ((JSObject audioData) {
        onData(audioData);
      }).toJS,
      'error': ((JSObject e) {
        onError(_jsErrorString(e));
      }).toJS,
    }),
  );
  decoder.configure(
    _jsObject({
      'codec': 'mp4a.40.2'.toJS,
      'sampleRate': sampleRate.toJS,
      'numberOfChannels': channels.toJS,
      'description': asc.toJS,
    }),
  );
  return decoder;
}

/// Builds an [EncodedAudioChunk] init object for [data] at
/// [timestampUs]/[durationUs] (all audio chunks are keyframes).
JSObject makeAudioChunkInit(
  Uint8List data,
  int timestampUs,
  int durationUs,
) =>
    _jsObject({
      'type': 'key'.toJS,
      'timestamp': timestampUs.toJS,
      'duration': durationUs.toJS,
      'data': data.toJS,
    });

String _jsErrorString(JSObject e) {
  var name = '?';
  var msg = '?';
  try {
    final n = e.getProperty('name'.toJS);
    if (n is JSString) name = n.toDart;
    final m = e.getProperty('message'.toJS);
    if (m is JSString) msg = m.toDart;
  } catch (_) {}
  return '$name: $msg';
}

/// JS `AudioEncoder` (WebCodecs).
@JS('AudioEncoder')
extension type JsAudioEncoder._(JSObject _) implements JSObject {
  /// Creates an encoder with [init] (`output` + `error` callbacks).
  external factory JsAudioEncoder(JSObject init);

  /// Configures the encoder (AAC-LC config object).
  external void configure(JSObject config);

  /// Encodes one [AudioData] frame.
  external void encode(JSObject data);

  /// Flushes pending encodes.
  external JSPromise<JSAny?> flush();

  /// Closes the encoder.
  external void close();

  /// Number of encodes queued.
  external int get encodeQueueSize;

  /// Encoder state (`configured`, `closed`, ...).
  external String get state;

  /// Probes whether [config] is supported.
  external static JSPromise<JSObject> isConfigSupported(JSObject config);
}

/// JS `AudioDecoder` (WebCodecs).
@JS('AudioDecoder')
extension type JsAudioDecoder._(JSObject _) implements JSObject {
  /// Creates a decoder with [init] (`output` + `error` callbacks).
  external factory JsAudioDecoder(JSObject init);

  /// Configures the decoder (AAC-LC config object + ASC description).
  external void configure(JSObject config);

  /// Decodes one [EncodedAudioChunk].
  external void decode(JSObject chunk);

  /// Flushes pending decodes.
  external JSPromise<JSAny?> flush();

  /// Closes the decoder.
  external void close();

  /// Number of decodes queued.
  external int get decodeQueueSize;
}

/// JS `EncodedAudioChunk` (WebCodecs).
@JS('EncodedAudioChunk')
extension type JsEncodedAudioChunk._(JSObject _) implements JSObject {
  /// Creates a chunk from [init] (`type`, `timestamp`, `duration`,
  /// `data`).
  external factory JsEncodedAudioChunk(JSObject init);

  /// Chunk byte length.
  external int get byteLength;

  /// Presentation timestamp, microseconds.
  external int get timestamp;

  /// Presentation duration, microseconds (may be 0 when unknown).
  external int? get duration;

  /// Copies the chunk bytes into [destination].
  external void copyTo(JSUint8Array destination);
}

/// JS `AudioData` (WebCodecs) — passed opaquely from decoder output
/// to encoder input; only [close] is needed on the Dart side.
@JS('AudioData')
extension type JsAudioData._(JSObject _) implements JSObject {
  /// Presentation timestamp, microseconds.
  external int get timestamp;

  /// Closes (frees) the audio data.
  external void close();
}
