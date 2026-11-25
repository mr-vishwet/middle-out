/// The real web media re-encoder (WebCodecs + canvas).
///
/// Video: demux the MP4 ([mp4_demuxer.dart]), decode every frame
/// with [VideoDecoder] (the presentation-order, as-fast-as-CPU
/// path — `requestVideoFrameCallback` is lossy in headless Chrome
/// and seek-loop decode is unusable on long-GOP clips), downscale on
/// a canvas, encode with [VideoEncoder] iterating a bitrate ladder
/// down to the quality floor, force a keyframe every 2 s, and mux
/// the result to a playable MP4 ([mp4_muxer.dart]).
///
/// Audio: when the source has an AAC track and [AudioEncoder]
/// supports AAC-LC at a bitrate the budget affords, the audio is
/// re-encoded at that low bitrate inside the same [targetBytes]
/// budget (the video bitrate is reduced accordingly). When it does
/// not fit, the audio is dropped and the settings label says so
/// plainly — audio is never the reason to fail the encode.
///
/// Images: canvas re-encode — downscale + a JPEG quality ladder
/// (q70 down to the q35 / 640 px floor). PNG inputs become JPEG.
///
/// Non-MP4 video (WebM, MOV, MKV, ...) throws [ReencodeException]
/// with a plain reason instead of returning the input or a corrupt
/// file. Non-media returns null, per the [MediaReencoder] contract.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../codec/reencode.dart';
import 'audio_webcodecs.dart';
import 'mp4_demuxer.dart';
import 'mp4_muxer.dart';

/// Audio bitrates to try, lowest first — the first one the browser
/// supports AND the budget affords wins. 12 kbps AAC is thin, but it
/// is the only rate that keeps a 240p @ 75 kbps video inside the
/// 10:1 budget on the Sintel fixture (16 kbps audio pushes the video
/// below its floor).
const List<int> kAudioBitrateLadder = [12000, 16000, 24000, 32000];

/// Conservative mux overhead allowance (moov tables + ftyp), bytes.
const int kMuxOverheadBytes = 8192;

/// One encoded video chunk, copied out of the encoder callback.
class _VideoChunk {
  _VideoChunk(this.data, this.timestampUs, this.durationUs, this.isKey);

  final Uint8List data;
  final int timestampUs;
  final int durationUs;
  final bool isKey;
}

/// A [VideoEncoder] plus everything it emitted.
class _EncoderSink {
  _EncoderSink(this.encoder);

  final web.VideoEncoder encoder;
  final List<_VideoChunk> chunks = [];

  /// avcC extradata from the first chunk's decoderConfig.
  Uint8List? description;
  final List<String> errors = [];

  int get totalBytes => chunks.fold(0, (s, c) => s + c.data.length);
  int get keyframes => chunks.where((c) => c.isKey).length;
}

/// One rung of the video bitrate ladder.
class _VideoRung {
  const _VideoRung({
    required this.width,
    required this.height,
    required this.bitrate,
  });

  final int width;
  final int height;

  /// Requested bitrate, bits per second.
  final int bitrate;

  /// Human-readable label, e.g. `426x240 @ 75 kbps`.
  String get label => '${width}x$height @ ${bitrate ~/ 1000} kbps';
}

/// Encoder floors measured by the spike
/// (test/reencode_spike_test.dart): below these the encoder emits
/// the floor anyway, so a rung requesting less is pointless. 720p
/// has a ~280 kbps floor; 360p tracks ~110 kbps; 240p and below
/// track the request accurately down to the 50 kbps quality floor
/// (240p@75k emitted 187,804 B ≈ 75 kbps, 240p@100k ≈ 94 kbps).
int _encoderFloorBps(int width) {
  if (width >= 1280) return 280000;
  if (width >= 640) return 110000;
  return ReencodeQualityFloor.minVideoBitrate;
}

/// The rung ladder for [sourceW]x[sourceH] at a video budget of
/// [budgetBps] (bits per second), best quality first. Pinned by the
/// coordinator against the TRUE budget (the spike's 240p@75k at
/// 187,804 B is already 1.32x over the 142,519 B media budget for
/// the Sintel clip, so the ladder must reach 240p@50k and the
/// 320x180 floor). Rungs whose effective bitrate (requested, or the
/// encoder floor, whichever is higher) exceeds the budget by more
/// than 5% are skipped — except the quality-floor rung, which is
/// always tried last so the encode fails honestly instead of
/// skipping straight to the error.
List<_VideoRung> _videoRungs(int sourceW, int sourceH, int budgetBps) {
  const ladder = <(int, int, List<int>)>[
    (1280, 720, [800000, 400000]),
    (640, 360, [200000, 100000]),
    (426, 240, [100000, 75000, 50000]),
    (320, 180, [50000]),
  ];
  final rungs = <_VideoRung>[];
  for (final (maxW, maxH, bitrates) in ladder) {
    // Scale the rung box to the source aspect (never upscale), and
    // keep dimensions even (H.264 requires it).
    final scale = (maxW / sourceW < maxH / sourceH)
        ? maxW / sourceW
        : maxH / sourceH;
    if (scale > 1) continue; // rung bigger than the source: skip
    var w = ((sourceW * scale).round() ~/ 2) * 2;
    var h = ((sourceH * scale).round() ~/ 2) * 2;
    if (w < ReencodeQualityFloor.minVideoWidth ||
        h < ReencodeQualityFloor.minVideoHeight) {
      w = ReencodeQualityFloor.minVideoWidth;
      h = ReencodeQualityFloor.minVideoHeight;
    }
    for (final bitrate in bitrates) {
      final effective =
          bitrate > _encoderFloorBps(w) ? bitrate : _encoderFloorBps(w);
      if (effective > budgetBps * 1.05) continue;
      rungs.add(_VideoRung(width: w, height: h, bitrate: bitrate));
    }
  }
  // The floor rung is always the last resort.
  const floor = _VideoRung(
    width: ReencodeQualityFloor.minVideoWidth,
    height: ReencodeQualityFloor.minVideoHeight,
    bitrate: ReencodeQualityFloor.minVideoBitrate,
  );
  if (rungs.isEmpty ||
      rungs.last.width != floor.width ||
      rungs.last.bitrate != floor.bitrate) {
    rungs.add(floor);
  }
  // De-duplicate identical (size, bitrate) rungs.
  final seen = <String>{};
  return rungs.where((r) {
    final key = '${r.width}x${r.height}@${r.bitrate}';
    return seen.add(key);
  }).toList();
}

/// Codec candidates for a rung of [width] px, best first. H.264
/// level caps frame size: level 3.0 (avc1.42001E) is unsupported at
/// 720p but fine at 360p and below.
List<String> _codecCandidates(int width) => width >= 720
    ? const ['avc1.64001f', 'avc1.4d001f', 'avc1.640028']
    : const ['avc1.42001E', 'avc1.64001f', 'avc1.4d001f'];

Future<String> _pickCodec(int width, int height, int bitrate) async {
  for (final codec in _codecCandidates(width)) {
    try {
      final support = await web.VideoEncoder.isConfigSupported(
        web.VideoEncoderConfig(
          codec: codec,
          width: width,
          height: height,
          bitrate: bitrate,
          framerate: 24,
        ),
      ).toDart;
      if (support.supported) return codec;
    } catch (_) {
      // Probe failure is not fatal; try the next candidate.
    }
  }
  return _codecCandidates(width).first;
}

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

bool _hasVideoEncoder() {
  try {
    final value = web.window.getProperty('VideoEncoder'.toJS);
    return value != null && !value.isUndefinedOrNull;
  } catch (_) {
    return false;
  }
}

/// The result of one rung encode.
class _RungResult {
  _RungResult({
    required this.chunks,
    required this.avcC,
    required this.derivedCodec,
    required this.wall,
    required this.keyframes,
  });

  final List<_VideoChunk> chunks;
  final Uint8List avcC;
  final String derivedCodec;
  final Duration wall;
  final int keyframes;

  int get totalBytes => chunks.fold(0, (s, c) => s + c.data.length);
}

/// Decodes [demuxed] with VideoDecoder and encodes every frame at
/// [rung], forcing a keyframe every 2 s. Frames flow in
/// presentation order, as fast as the CPU allows — no presentation
/// clock, no <video> element.
Future<_RungResult> _encodeVideoRung(
  DemuxedMp4 demuxed,
  _VideoRung rung,
  ReencodeProgress? onProgress,
  double progressBase,
  double progressSpan,
) async {
  final codec = await _pickCodec(rung.width, rung.height, rung.bitrate);
  final fps = demuxed.fps <= 0 ? 24.0 : demuxed.fps;
  final frameDurationUs = (1000000 / fps).round();
  final keyframeEvery = (fps * 2).round().clamp(1, 1 << 30);
  final sw = Stopwatch()..start();

  late final _EncoderSink sink;
  final encoder = web.VideoEncoder(
    web.VideoEncoderInit(
      output: ((web.EncodedVideoChunk chunk, JSObject metadata) {
        final buf = JSUint8Array.withLength(chunk.byteLength);
        chunk.copyTo(buf);
        sink.chunks.add(
          _VideoChunk(
            buf.toDart,
            chunk.timestamp,
            chunk.duration ?? 0,
            chunk.type == 'key',
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
            // Best-effort; a missing description fails loudly below.
          }
        }
      }).toJS,
      error: ((JSObject e) {
        sink.errors.add(_jsErrorString(e));
      }).toJS,
    ),
  );
  sink = _EncoderSink(encoder);
  encoder.configure(
    web.VideoEncoderConfig(
      codec: codec,
      width: rung.width,
      height: rung.height,
      bitrate: rung.bitrate,
      framerate: fps.round(),
      bitrateMode: 'variable',
    ),
  );

  final canvas =
      web.document.createElement('canvas') as web.HTMLCanvasElement;
  canvas.width = rung.width;
  canvas.height = rung.height;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;

  final pending = Queue<web.VideoFrame>();
  final errors = <String>[];
  var decodeFinished = false;
  var consumed = 0;
  late final web.VideoDecoder decoder;
  decoder = web.VideoDecoder(
    web.VideoDecoderInit(
      output: ((web.VideoFrame frame) {
        pending.add(frame);
      }).toJS,
      error: ((JSObject e) {
        errors.add(_jsErrorString(e));
      }).toJS,
    ),
  );
  decoder.configure(
    web.VideoDecoderConfig(
      codec: demuxed.codec,
      description: demuxed.avcC.toJS,
      codedWidth: demuxed.width,
      codedHeight: demuxed.height,
    ),
  );

  Future<void> submit() async {
    for (final s in demuxed.samples) {
      while (pending.length > 8 || decoder.decodeQueueSize > 16) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      decoder.decode(
        web.EncodedVideoChunk(
          web.EncodedVideoChunkInit(
            type: s.isKey ? 'key' : 'delta',
            timestamp: s.timestampUs,
            duration: s.durationUs,
            data: s.data.toJS,
          ),
        ),
      );
    }
    await decoder.flush().toDart;
    decodeFinished = true;
  }

  Future<void> pump() async {
    while (!decodeFinished || pending.isNotEmpty) {
      if (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        continue;
      }
      final frame = pending.removeFirst();
      final index = consumed++;
      final tsUs = frame.timestamp;
      final durUs = frame.duration ?? frameDurationUs;
      ctx.drawImage(frame, 0, 0, rung.width, rung.height);
      final out = web.VideoFrame(
        canvas,
        web.VideoFrameInit(timestamp: tsUs, duration: durUs),
      );
      encoder.encode(
        out,
        web.VideoEncoderEncodeOptions(keyFrame: index % keyframeEvery == 0),
      );
      out.close();
      frame.close();
      while (encoder.encodeQueueSize > 24) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (index % 24 == 0) {
        onProgress?.call(
          progressBase + progressSpan * index / demuxed.samples.length,
          'Re-encoding video: ${rung.label}',
        );
      }
    }
  }

  await Future.wait([submit(), pump()]);
  await encoder.flush().toDart;
  encoder.close();
  decoder.close();
  sw.stop();
  if (errors.isNotEmpty) {
    throw const ReencodeException(
      "This video couldn't be decoded in the browser — "
      'encode it losslessly instead.',
    );
  }
  if (sink.errors.isNotEmpty) {
    throw ReencodeException(
      'The video encoder failed (${sink.errors.first}) — '
      'encode this file losslessly instead.',
    );
  }
  if (sink.chunks.isEmpty || sink.description == null) {
    throw const ReencodeException(
      'The video encoder produced no output — '
      'encode this file losslessly instead.',
    );
  }
  return _RungResult(
    chunks: sink.chunks,
    avcC: sink.description!,
    derivedCodec: codecStringFromAvcC(sink.description!),
    wall: sw.elapsed,
    keyframes: sink.keyframes,
  );
}

/// Re-encodes the demuxed AAC track at [bitrate] bps. Returns the
/// encoded chunks plus the AudioSpecificConfig, or null when the
/// track cannot be decoded (the caller then drops the audio).
Future<({List<Mp4Sample> samples, Uint8List asc})?> _encodeAudio(
  DemuxedAudioTrack track,
  int bitrate,
) async {
  final pending = Queue<JSObject>();
  final errors = <String>[];
  var decodeFinished = false;
  late final JsAudioDecoder decoder;
  final sink = makeAacEncoder(
    sampleRate: track.sampleRate,
    channels: track.channels,
    bitrate: bitrate,
  );
  decoder = makeAacDecoder(
    sampleRate: track.sampleRate,
    channels: track.channels,
    asc: track.asc,
    onData: (audioData) {
      pending.add(audioData);
    },
    onError: (e) {
      errors.add(e);
    },
  );

  Future<void> submit() async {
    for (final s in track.samples) {
      while (pending.length > 16 || decoder.decodeQueueSize > 32) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      decoder.decode(
        JsEncodedAudioChunk(makeAudioChunkInit(s.data, s.timestampUs, s.durationUs)),
      );
    }
    await decoder.flush().toDart;
    decodeFinished = true;
  }

  Future<void> pump() async {
    while (!decodeFinished || pending.isNotEmpty) {
      if (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        continue;
      }
      final data = pending.removeFirst();
      sink.encoder.encode(data);
      (data as JsAudioData).close();
      while (sink.encoder.encodeQueueSize > 32) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  await Future.wait([submit(), pump()]);
  await sink.encoder.flush().toDart;
  sink.encoder.close();
  decoder.close();
  if (errors.isNotEmpty || sink.errors.isNotEmpty || sink.chunks.isEmpty) {
    return null;
  }
  return (
    samples: sink.chunks
        .map(
          (c) => Mp4Sample(
            data: c.data,
            timestampUs: c.timestampUs,
            durationUs: c.durationUs,
            isKey: true,
          ),
        )
        .toList(),
    asc: sink.description ?? track.asc,
  );
}

/// Converts a canvas to a [Blob] of [type] at [quality].
Future<web.Blob?> _canvasToBlob(
  web.HTMLCanvasElement canvas,
  String type,
  double quality,
) {
  final completer = Completer<web.Blob?>();
  canvas.toBlob(
    ((web.Blob? b) {
      completer.complete(b);
    }).toJS,
    type,
    quality.toJS,
  );
  return completer.future;
}

/// Reads a [Blob]'s bytes.
Future<Uint8List> _blobBytes(web.Blob blob) async {
  final buf = await blob.arrayBuffer().toDart;
  final dartBuf = buf.toDart;
  return Uint8List.view(dartBuf, 0, dartBuf.lengthInBytes);
}

/// The web media re-encoder: WebCodecs video + canvas images.
class WebMediaReencoder implements MediaReencoder {
  @override
  bool get isAvailable => _hasVideoEncoder();

  @override
  String get encoderName => isAvailable ? 'WebCodecs avc1' : '';

  @override
  Future<ReencodePlan?> plan(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
  }) async {
    try {
      final kind = detectMediaKind(fileName, bytes);
      if (kind == MediaKind.video) {
        if (!isMp4Container(bytes)) return null;
        final demuxed = demuxMp4(bytes);
        final durationSec = demuxed.durationUs / 1000000;
        final audioBitrate = await _affordableAudioBitrate(
          demuxed,
          targetBytes,
          durationSec,
        );
        final reserve = audioBitrate == null
            ? 0
            : (audioBitrate * durationSec / 8).round();
        final videoTarget = targetBytes - reserve - kMuxOverheadBytes;
        final budgetBps = (videoTarget * 8 / durationSec).round();
        final rungs = _videoRungs(demuxed.width, demuxed.height, budgetBps);
        final rung = rungs.first;
        final audioNote = audioBitrate == null
            ? 'audio dropped to fit 10:1'
            : 'AAC ${audioBitrate ~/ 1000} kbps audio';
        // The encode steps down the ladder until the output fits, so
        // the proposal must show the RANGE (first rung down to the
        // floor), not just the first rung — otherwise the user
        // confirms one quality and gets a lower one (Sintel: the plan
        // said 426x240 @ 50 kbps, the encode landed on 320x180 @
        // 50 kbps). The floor rung is always last in the ladder.
        final last = rungs.last;
        final stepDown = last.label == rung.label
            ? ''
            : ' — stepping down to ${last.label} if needed';
        return ReencodePlan(
          encoder: 'WebCodecs avc1',
          settingsLabel:
              '${rung.label}, ${demuxed.fps.round()} fps, $audioNote$stepDown',
        );
      }
      if (kind == MediaKind.image) {
        final bitmap = await _decodeImage(bytes, fileName);
        if (bitmap == null) return null;
        final longest = bitmap.width > bitmap.height
            ? bitmap.width
            : bitmap.height;
        final edge = longest < 2048 ? longest : 2048;
        bitmap.close();
        return ReencodePlan(
          encoder: 'canvas JPEG',
          settingsLabel: 'JPEG q70, longest edge $edge px (PNG → JPEG)',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ReencodedMedia?> reencode(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
    ReencodeProgress? onProgress,
  }) async {
    final kind = detectMediaKind(fileName, bytes);
    if (kind == MediaKind.video) {
      return _reencodeVideo(bytes, fileName, targetBytes, onProgress);
    }
    if (kind == MediaKind.image) {
      return _reencodeImage(bytes, fileName, targetBytes, onProgress);
    }
    // Audio-only and non-media are not re-encodable here.
    return null;
  }

  /// Picks the audio bitrate to use: the lowest supported rate whose
  /// reserve still leaves the video at or above its quality floor.
  /// Returns null when audio must be dropped.
  Future<int?> _affordableAudioBitrate(
    DemuxedMp4 demuxed,
    int targetBytes,
    double durationSec,
  ) async {
    final track = demuxed.audio;
    if (track == null || track.samples.isEmpty) return null;
    for (final bitrate in kAudioBitrateLadder) {
      final supported = await probeAudioEncoder(
        sampleRate: track.sampleRate,
        channels: track.channels,
        bitrate: bitrate,
      );
      if (!supported) continue;
      final reserve = (bitrate * durationSec / 8).round();
      final videoTarget = targetBytes - reserve - kMuxOverheadBytes;
      final budgetBps = (videoTarget * 8 / durationSec).round();
      if (budgetBps >= ReencodeQualityFloor.minVideoBitrate) {
        return bitrate;
      }
      // A higher bitrate only reserves more; stop at the first
      // supported rate that does not fit.
      return null;
    }
    return null;
  }

  Future<ReencodedMedia> _reencodeVideo(
    Uint8List bytes,
    String fileName,
    int targetBytes,
    ReencodeProgress? onProgress,
  ) async {
    if (!isAvailable) {
      throw const ReencodeException(
        'Re-encoding is not available on this device.',
      );
    }
    if (!isMp4Container(bytes)) {
      throw const ReencodeException(
        "This video format can't be re-encoded in the browser yet — "
        'encode it losslessly instead.',
      );
    }
    late final DemuxedMp4 demuxed;
    try {
      demuxed = demuxMp4(bytes);
    } on FormatException {
      throw const ReencodeException(
        "This MP4 file couldn't be read for re-encoding — "
        'encode it losslessly instead.',
      );
    }
    final durationSec = demuxed.durationUs / 1000000;
    final audioBitrate = await _affordableAudioBitrate(
      demuxed,
      targetBytes,
      durationSec,
    );
    final audioReserved = audioBitrate == null
        ? 0
        : (audioBitrate * durationSec / 8).round();
    final videoTarget = targetBytes - audioReserved - kMuxOverheadBytes;
    final budgetBps = (videoTarget * 8 / durationSec).round();
    final rungs = _videoRungs(demuxed.width, demuxed.height, budgetBps);

    // The audio is encoded once and reused across rungs (its size
    // does not depend on the video rung).
    ({List<Mp4Sample> samples, Uint8List asc})? audioEncoded;
    DemuxedAudioTrack? audioTrack;
    if (audioBitrate != null && demuxed.audio != null) {
      onProgress?.call(0.02, 'Re-encoding audio: AAC ${audioBitrate ~/ 1000} kbps');
      audioEncoded = await _encodeAudio(demuxed.audio!, audioBitrate);
      if (audioEncoded != null) {
        audioTrack = DemuxedAudioTrack(
          samples: audioEncoded.samples,
          asc: audioEncoded.asc,
          sampleRate: demuxed.audio!.sampleRate,
          channels: demuxed.audio!.channels,
        );
      }
    }
    var audioDropped = audioBitrate == null || audioTrack == null;

    for (var i = 0; i < rungs.length; i++) {
      final rung = rungs[i];
      final base = 0.05 + 0.9 * i / rungs.length;
      final span = 0.9 / rungs.length;
      onProgress?.call(
        base,
        'Re-encoding video: ${rung.label} (attempt ${i + 1} of ${rungs.length})',
      );
      final result = await _encodeVideoRung(
        demuxed,
        rung,
        onProgress,
        base,
        span,
      );
      final samples = result.chunks
          .map(
            (c) => Mp4Sample(
              data: c.data,
              timestampUs: c.timestampUs,
              durationUs: c.durationUs,
              isKey: c.isKey,
            ),
          )
          .toList();
      // With audio first: the video was budgeted for it, so try the
      // combined file before giving up the audio.
      if (audioTrack != null) {
        final withAudio = muxMp4(
          videoSamples: samples,
          avcC: result.avcC,
          width: rung.width,
          height: rung.height,
          audio: audioTrack,
          audioBitrate: audioBitrate!,
        );
        if (withAudio.length <= targetBytes) {
          onProgress?.call(1.0, 'Re-encode complete');
          return ReencodedMedia(
            bytes: withAudio,
            kind: MediaKind.video,
            encoder: 'WebCodecs ${result.derivedCodec}',
            settingsLabel:
                '${rung.label}, ${demuxed.fps.round()} fps, '
                'AAC ${audioBitrate ~/ 1000} kbps audio '
                '(${result.keyframes} keyframes)',
          );
        }
        // Audio does not fit at this rung: drop it and keep the
        // video-only file if IT fits — audio is never the reason
        // to step down a rung.
        audioDropped = true;
        audioTrack = null;
      }
      final videoOnly = audioTrack == null
          ? muxMp4(
              videoSamples: samples,
              avcC: result.avcC,
              width: rung.width,
              height: rung.height,
            )
          : null;
      if (videoOnly != null && videoOnly.length <= targetBytes) {
        onProgress?.call(1.0, 'Re-encode complete');
        final audioNote = audioDropped
            ? 'audio dropped to fit 10:1'
            : 'no audio track';
        return ReencodedMedia(
          bytes: videoOnly,
          kind: MediaKind.video,
          encoder: 'WebCodecs ${result.derivedCodec}',
          settingsLabel:
              '${rung.label}, ${demuxed.fps.round()} fps, $audioNote '
              '(${result.keyframes} keyframes)',
        );
      }
      // Otherwise step down to the next rung. The last rung is the
      // quality floor — falling through it is an honest failure.
    }
    final floor = rungs.last;
    throw ReencodeException(
      'Even the lowest quality (${floor.label}) is too big for 10:1 — '
      'encode this file losslessly instead.',
    );
  }

  /// Decodes an image's bytes to a bitmap (or null when the browser
  /// cannot decode the format).
  Future<web.ImageBitmap?> _decodeImage(Uint8List bytes, String fileName) async {
    try {
      final lower = fileName.toLowerCase();
      final mime = lower.endsWith('.png')
          ? 'image/png'
          : lower.endsWith('.webp')
              ? 'image/webp'
              : lower.endsWith('.gif')
                  ? 'image/gif'
                  : 'image/jpeg';
      final blob = web.Blob(
        [bytes.toJS as JSAny].toJS,
        web.BlobPropertyBag(type: mime),
      );
      return await web.window.createImageBitmap(blob).toDart;
    } catch (_) {
      return null;
    }
  }

  Future<ReencodedMedia> _reencodeImage(
    Uint8List bytes,
    String fileName,
    int targetBytes,
    ReencodeProgress? onProgress,
  ) async {
    final bitmap = await _decodeImage(bytes, fileName);
    if (bitmap == null) {
      throw const ReencodeException(
        "This image format can't be re-encoded in the browser yet — "
        'encode it losslessly instead.',
      );
    }
    final srcW = bitmap.width;
    final srcH = bitmap.height;
    final longest = srcW > srcH ? srcW : srcH;
    final wasPng = fileName.toLowerCase().endsWith('.png');
    final wasGif = fileName.toLowerCase().endsWith('.gif');
    if (bytes.length <= targetBytes && !wasPng && !wasGif) {
      bitmap.close();
      return ReencodedMedia(
        bytes: bytes,
        kind: MediaKind.image,
        encoder: 'original',
        settingsLabel:
            'kept original ${srcW}x$srcH (already fits 10:1)',
      );
    }
    // Ladder: longest edge down, JPEG quality down, floor 640 px /
    // q35. Each step is one canvas draw + toBlob (fast).
    final edges = <int>{};
    for (final e in [2048, 1600, 1280, 1024, 800, 640]) {
      if (e <= longest) edges.add(e);
    }
    edges.add(640);
    final sortedEdges = edges.toList()..sort((a, b) => b.compareTo(a));
    const qualities = [70, 60, 50, 40, 35];
    var attempt = 0;
    final totalAttempts = sortedEdges.length * qualities.length;
    for (final edge in sortedEdges) {
      final scale = edge / longest;
      final w = (srcW * scale).round().clamp(1, srcW);
      final h = (srcH * scale).round().clamp(1, srcH);
      final canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas.width = w;
      canvas.height = h;
      final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      ctx.drawImage(bitmap, 0, 0, w, h);
      for (final q in qualities) {
        attempt++;
        onProgress?.call(
          attempt / totalAttempts,
          'Re-encoding image: JPEG q$q, ${w}x$h',
        );
        final blob = await _canvasToBlob(canvas, 'image/jpeg', q / 100);
        if (blob == null) continue;
        final out = await _blobBytes(blob);
        if (out.length <= targetBytes) {
          bitmap.close();
          final conversion = wasPng
              ? ' (PNG → JPEG)'
              : wasGif
                  ? ' (animated GIF → still JPEG)'
                  : '';
          return ReencodedMedia(
            bytes: out,
            kind: MediaKind.image,
            encoder: 'canvas JPEG',
            settingsLabel: 'JPEG q$q, ${w}x$h$conversion',
          );
        }
      }
    }
    bitmap.close();
    throw const ReencodeException(
      'Even the smallest JPEG (640 px, quality 35) is too big for '
      '10:1 — encode this file losslessly instead.',
    );
  }
}

/// Creates the platform media re-encoder (WebCodecs on the web).
MediaReencoder createMediaReencoder() => WebMediaReencoder();
