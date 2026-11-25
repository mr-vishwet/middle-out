// SPIKE ONLY — evidence for the Middle Out 10:1 re-encode decision.
// NOT production code. Do not import anything from here into lib/.
//
// Proves (or disproves) in a REAL Chrome, with measured numbers, that
// the app can re-encode video in-browser to hit a size target, using
// WebCodecs VideoEncoder (browser-native, no big download), with
// MediaRecorder and canvas JPEG as controls.
//
// Test clip: Sintel clean clip, test/fixtures/sintel-720p.mp4
// (copied from frame-police demo assets, CC-BY, 3,105,557 bytes,
// 20.08 s, 1280x720/24, AAC).
//
// Targets (exact, not guessed):
//   input            3,105,557 B
//   PDF target       input / 10            = 310,555 B
//   media budget     input / 13.3 (~33% parity + framing overhead)
//                                  = 233,501 B
//   => max avg video bitrate for the 20.08 s clip = ~93,000 bps.
// The re-encode quality floor in lib/codec/reencode.dart is
// 426x240 @ 150 kbps, which alone is ~376 KB for this clip — already
// over budget. The ladder below measures whether ANY bitrate/res
// reaches the budget, and what the encoder actually emits vs the
// requested bitrate.
//
// Codec note (measured, test 1): H.264 level caps frame size —
// level 3.0 (avc1.42001E / avc1.4d001e) is UNSUPPORTED at 1280x720
// (MaxFS 1620 MBs < 720p's 3600 MBs) but fine at 640x360. 720p
// needs level 3.1+ (avc1.64001f High 3.1 works).
//
// Decode-path findings (measured, tests 1–2):
// - requestVideoFrameCallback is LOSSY in this headless Chrome:
//   154/483 frames delivered, playback at 0.55x realtime.
// - Seek-loop decode is UNUSABLE for long-GOP clips: this clip has
//   only 3 keyframes (GOP ~9 s), so 482 seeks blew past the 6-min
//   test timeout (each seek re-decodes ~160 frames on average).
// - Demux + VideoDecoder (this file's _demuxMp4 + _transcode) is the
//   working decode path: every frame decoded exactly once, as fast
//   as the CPU allows, no presentation clock. ctts is REQUIRED —
//   all 482 frames have pts != dts (B-frames).
// Run: flutter test --platform chrome test/reencode_spike_test.dart
// (NEVER -d chrome: silently ignored, Chrome tests skip.)
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'fixture_loader.dart';

const String kFixture = 'sintel-720p.mp4';
const int kInputBytes = 3105557;
const double kClipSeconds = 20.08;
const int kFps = 24;

/// PDF must land at or below input / 10.
int get kPdfTargetBytes => kInputBytes ~/ 10;

/// Media budget: input / 13.3 (leaves ~33% for parity + framing).
int get kMediaBudgetBytes => (kInputBytes / 13.3).round();

/// Max average video bitrate that fits the media budget over the clip.
int get kMaxAvgBitrateBps => (kMediaBudgetBytes * 8 / kClipSeconds).round();

const Duration kTestTimeout = Duration(minutes: 6);

Future<void> _pollUntil(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 90),
  Duration interval = const Duration(milliseconds: 50),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('timed out waiting for $what after $timeout');
    }
    await Future<void>.delayed(interval);
  }
}

/// One encoded chunk, copied out of the encoder callback.
class _Chunk {
  _Chunk(this.data, this.timestampUs, this.durationUs, this.isKey);

  final Uint8List data;
  final int timestampUs;
  final int durationUs;
  final bool isKey;
}

/// A VideoEncoder plus everything it emitted.
class _EncoderSink {
  _EncoderSink(this.label, this.encoder);

  final String label;
  final web.VideoEncoder encoder;
  final List<_Chunk> chunks = [];

  /// avcC extradata from the first chunk's decoderConfig, if any.
  Uint8List? description;
  final List<String> errors = [];

  int get totalBytes => chunks.fold(0, (s, c) => s + c.data.length);
  int get keyframes => chunks.where((c) => c.isKey).length;
  double get effectiveBitrateKbps =>
      chunks.isEmpty ? 0 : totalBytes * 8 / kClipSeconds / 1000;
}

_EncoderSink _makeAvcSink(
  String label,
  int width,
  int height,
  int bitrate, {
  String codec = 'avc1.64001f',
  String bitrateMode = 'variable',
}) {
  late final _EncoderSink sink;
  final encoder = web.VideoEncoder(
    web.VideoEncoderInit(
      output: ((web.EncodedVideoChunk chunk, JSObject metadata) {
        final buf = JSUint8Array.withLength(chunk.byteLength);
        chunk.copyTo(buf);
        sink.chunks.add(
          _Chunk(
            buf.toDart,
            chunk.timestamp,
            chunk.duration ?? 0,
            chunk.type == 'key',
          ),
        );
        // Capture the avcC extradata once (needed for the mp4 muxer).
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
            // Description capture is best-effort; the mux test reports it.
          }
        }
      }).toJS,
      error: ((JSObject e) {
        sink.errors.add(_jsErrorString(e));
      }).toJS,
    ),
  );
  sink = _EncoderSink(label, encoder);
  encoder.configure(
    web.VideoEncoderConfig(
      codec: codec,
      width: width,
      height: height,
      bitrate: bitrate,
      framerate: 24,
      bitrateMode: bitrateMode,
    ),
  );
  return sink;
}

/// Loads the fixture over HTTP, puts it in a <video> element in the
/// DOM (muted, playsInline) and waits for metadata.
Future<web.HTMLVideoElement> _makeVideo() async {
  final bytes = await loadFixture(kFixture);
  expect(bytes.length, kInputBytes, reason: 'fixture size mismatch');
  final blob = web.Blob(
    [bytes.toJS as JSAny].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  final url = web.URL.createObjectURL(blob);
  final video = web.document.createElement('video') as web.HTMLVideoElement;
  video.muted = true;
  video.playsInline = true;
  video.preload = 'auto';
  video.src = url;
  web.document.body!.appendChild(video);
  await _pollUntil(
    () => video.readyState >= 1,
    timeout: const Duration(seconds: 30),
    what: 'video loadedmetadata',
  );
  return video;
}

void _removeVideo(web.HTMLVideoElement video) {
  try {
    video.pause();
  } catch (_) {}
  video.remove();
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

// ---------------------------------------------------------------------------
// Minimal MP4 demuxer (spike-only): parses moov/stbl of the video track
// and returns samples in decode (file) order with presentation
// timestamps (ctts applied — this clip has B-frames on ALL 482
// frames, so ctts is not optional). 32-bit box reads only.
// ---------------------------------------------------------------------------

class _Mp4Sample {
  _Mp4Sample(this.data, this.timestampUs, this.durationUs, this.isKey);

  final Uint8List data;
  final int timestampUs;
  final int durationUs;
  final bool isKey;
}

class _DemuxedMp4 {
  _DemuxedMp4(this.samples, this.avcC, this.codec, this.width, this.height);

  final List<_Mp4Sample> samples;
  final Uint8List avcC;
  final String codec;
  final int width;
  final int height;
}

Iterable<({String type, int start, int end})> _childBoxes(
  Uint8List bytes,
  int start,
  int end,
) sync* {
  final bd = ByteData.sublistView(bytes);
  var pos = start;
  while (pos + 8 <= end) {
    final size = bd.getUint32(pos);
    if (size < 8 || pos + size > end) break;
    final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
    yield (type: type, start: pos + 8, end: pos + size);
    pos += size;
  }
}

({int start, int end})? _findBox(
  Uint8List bytes,
  int start,
  int end,
  String type,
) {
  for (final b in _childBoxes(bytes, start, end)) {
    if (b.type == type) return (start: b.start, end: b.end);
  }
  return null;
}

_DemuxedMp4 _demuxMp4(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) throw StateError('no moov box');
  for (final trak in _childBoxes(bytes, moov.start, moov.end)) {
    if (trak.type != 'trak') continue;
    final mdia = _findBox(bytes, trak.start, trak.end, 'mdia');
    if (mdia == null) continue;
    final mdhd = _findBox(bytes, mdia.start, mdia.end, 'mdhd');
    final minf = _findBox(bytes, mdia.start, mdia.end, 'minf');
    if (mdhd == null || minf == null) continue;
    final stbl = _findBox(bytes, minf.start, minf.end, 'stbl');
    if (stbl == null) continue;
    final stsd = _findBox(bytes, stbl.start, stbl.end, 'stsd');
    if (stsd == null) continue;
    // First sample entry type decides whether this is the video trak.
    final entry = stsd.start + 8;
    final entryType =
        String.fromCharCodes(bytes.sublist(entry + 4, entry + 8));
    if (entryType != 'avc1') continue; // audio track etc.
    final width = bd.getUint16(entry + 32);
    final height = bd.getUint16(entry + 34);
    // avcC child box lives at entry+86..entry+size.
    final entrySize = bd.getUint32(entry);
    final avcCBox = _findBox(bytes, entry + 86, entry + entrySize, 'avcC');
    if (avcCBox == null) throw StateError('avc1 entry has no avcC');
    final avcC = bytes.sublist(avcCBox.start, avcCBox.end);
    final codec = 'avc1.${avcC[1].toRadixString(16).padLeft(2, '0')}'
        '${avcC[2].toRadixString(16).padLeft(2, '0')}'
        '${avcC[3].toRadixString(16).padLeft(2, '0')}';
    // mdhd timescale (version 0: +12, version 1: +20).
    final mdhdVersion = bytes[mdhd.start];
    final timescale = bd.getUint32(
      mdhd.start + (mdhdVersion == 1 ? 20 : 12),
    );
    List<(int, int)> readRuns(({int start, int end}) box) {
      final count = bd.getUint32(box.start + 4);
      final out = <(int, int)>[];
      for (var i = 0; i < count; i++) {
        final o = box.start + 8 + i * 8;
        out.add((bd.getUint32(o), bd.getUint32(o + 4)));
      }
      return out;
    }

    final sttsBox = _findBox(bytes, stbl.start, stbl.end, 'stts')!;
    final durations = <int>[];
    for (final (count, delta) in readRuns(sttsBox)) {
      durations.addAll(List<int>.filled(count, delta));
    }
    final cttsBox = _findBox(bytes, stbl.start, stbl.end, 'ctts');
    final cttsOffsets = <int>[];
    if (cttsBox != null) {
      final version = bytes[cttsBox.start];
      final count = bd.getUint32(cttsBox.start + 4);
      for (var i = 0; i < count; i++) {
        final o = cttsBox.start + 8 + i * 8;
        final c = bd.getUint32(o);
        final off = version == 1
            ? bd.getInt32(o + 4)
            : bd.getUint32(o + 4);
        cttsOffsets.addAll(List<int>.filled(c, off));
      }
    }
    final stscBox = _findBox(bytes, stbl.start, stbl.end, 'stsc')!;
    final stsc = <(int, int)>[]; // (firstChunk, samplesPerChunk)
    {
      final count = bd.getUint32(stscBox.start + 4);
      for (var i = 0; i < count; i++) {
        final o = stscBox.start + 8 + i * 12;
        stsc.add((bd.getUint32(o), bd.getUint32(o + 4)));
      }
    }
    if (_findBox(bytes, stbl.start, stbl.end, 'co64') != null) {
      throw UnsupportedError('co64 (64-bit chunk offsets) unsupported');
    }
    final stcoBox = _findBox(bytes, stbl.start, stbl.end, 'stco')!;
    final stco = <int>[];
    {
      final count = bd.getUint32(stcoBox.start + 4);
      for (var i = 0; i < count; i++) {
        stco.add(bd.getUint32(stcoBox.start + 8 + i * 4));
      }
    }
    final stszBox = _findBox(bytes, stbl.start, stbl.end, 'stsz')!;
    final sampleSize = bd.getUint32(stszBox.start + 4);
    final sampleCount = bd.getUint32(stszBox.start + 8);
    final sizes = <int>[];
    if (sampleSize != 0) {
      sizes.addAll(List<int>.filled(sampleCount, sampleSize));
    } else {
      for (var i = 0; i < sampleCount; i++) {
        sizes.add(bd.getUint32(stszBox.start + 12 + i * 4));
      }
    }
    final keySet = <int>{};
    final stssBox = _findBox(bytes, stbl.start, stbl.end, 'stss');
    if (stssBox != null) {
      final count = bd.getUint32(stssBox.start + 4);
      for (var i = 0; i < count; i++) {
        keySet.add(bd.getUint32(stssBox.start + 8 + i * 4));
      }
    }
    // Decode timestamps: running sum of stts durations.
    final dts = <int>[];
    var acc = 0;
    for (final d in durations) {
      dts.add(acc);
      acc += d;
    }
    final samples = <_Mp4Sample>[];
    var sampleIndex = 0;
    for (var c = 0; c < stco.length; c++) {
      var spc = stsc.last.$2;
      for (final (firstChunk, perChunk) in stsc) {
        if (firstChunk <= c + 1) {
          spc = perChunk;
        } else {
          break;
        }
      }
      var offset = stco[c];
      for (var j = 0; j < spc && sampleIndex < durations.length; j++) {
        final size = sizes[sampleIndex];
        final data = bytes.sublist(offset, offset + size);
        offset += size;
        final pts = dts[sampleIndex] +
            (cttsOffsets.isEmpty ? 0 : cttsOffsets[sampleIndex]);
        samples.add(
          _Mp4Sample(
            data,
            (pts * 1000000 / timescale).round(),
            (durations[sampleIndex] * 1000000 / timescale).round(),
            keySet.contains(sampleIndex + 1),
          ),
        );
        sampleIndex++;
      }
    }
    return _DemuxedMp4(samples, avcC, codec, width, height);
  }
  throw StateError('no avc1 video track found');
}

/// Decode + feed pipeline: demuxes [mp4Bytes], decodes every frame
/// with VideoDecoder as fast as the CPU allows (NOT realtime), and
/// hands each output [web.VideoFrame] to [onFrame] in presentation
/// order, closing it afterwards. Chunk submission is backpressured
/// on the pending-output queue so memory stays bounded (~8 frames).
/// Returns frame count + wall time. This is the production-shaped
/// decode path: no <video> element, no presentation clock.
Future<({int frames, Duration wall})> _transcode(
  Uint8List mp4Bytes,
  Future<void> Function(web.VideoFrame frame, int timestampUs, int index)
      onFrame,
) async {
  final demuxed = _demuxMp4(mp4Bytes);
  final sw = Stopwatch()..start();
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
      await onFrame(frame, frame.timestamp, consumed);
      consumed++;
      frame.close();
    }
  }

  await Future.wait([submit(), pump()]);
  decoder.close();
  sw.stop();
  if (errors.isNotEmpty) {
    throw StateError('VideoDecoder errors: $errors');
  }
  return (frames: consumed, wall: sw.elapsed);
}

/// Short rVFC sample: play from 0 and count requestVideoFrameCallback
/// deliveries until [sampleSeconds] of media time have elapsed.
/// Measurement only (no assert) — documents whether rVFC is usable.
Future<({int frames, Duration wall, int presented, int dropped})>
    _sampleRvfc(web.HTMLVideoElement video, double sampleSeconds) async {
  var frames = 0;
  final sw = Stopwatch()..start();
  void onRvfc(double now, web.VideoFrameMetadata meta) {
    if (video.ended || video.currentTime >= sampleSeconds) return;
    frames++;
    video.requestVideoFrameCallback(onRvfc.toJS);
  }

  video.currentTime = 0;
  video.requestVideoFrameCallback(onRvfc.toJS);
  await video.play().toDart;
  await _pollUntil(
    () => video.currentTime >= sampleSeconds || video.ended,
    timeout: const Duration(seconds: 60),
    interval: const Duration(milliseconds: 100),
    what: 'rVFC sample $sampleSeconds s',
  );
  video.pause();
  sw.stop();
  final q = video.getVideoPlaybackQuality();
  return (
    frames: frames,
    wall: sw.elapsed,
    presented: q.totalVideoFrames,
    dropped: q.droppedVideoFrames,
  );
}

/// Throttle helper: wait until every sink's encode queue drains.
Future<void> _drainQueues(List<_EncoderSink> sinks) async {
  var guard = 0;
  while (sinks.any((s) => s.encoder.encodeQueueSize > 24)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (++guard > 200) break; // 10 s max; report, don't hang forever.
  }
}

Future<void> _flushAll(List<_EncoderSink> sinks) async {
  for (final s in sinks) {
    await s.encoder.flush().toDart;
    s.encoder.close();
  }
}

void _printSink(_EncoderSink s, {required int requestedKbps}) {
  final firstKey = s.chunks.isEmpty ? 'n/a' : s.chunks.first.isKey.toString();
  // ignore: avoid_print
  print(
    'SPIKE encode ${s.label}: chunks=${s.chunks.length} '
    'keyframes=${s.keyframes} firstIsKey=$firstKey '
    'bytes=${s.totalBytes} '
    'effBitrate=${s.effectiveBitrateKbps.toStringAsFixed(1)} kbps '
    '(requested $requestedKbps) '
    'fitsBudget=${s.totalBytes <= kMediaBudgetBytes} '
    'errors=${s.errors}',
  );
}

void main() {
  // ignore: avoid_print
  print(
    'SPIKE targets: input=$kInputBytes B pdfTarget<=$kPdfTargetBytes B '
    'mediaBudget<=$kMediaBudgetBytes B maxAvgBitrate=$kMaxAvgBitrateBps bps',
  );

  test(
    '1 availability: VideoEncoder + isConfigSupported per codec',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      // Presence check: constructing the probes below throws if the
      // API is missing entirely; each call is wrapped so one codec's
      // failure is reported, not fatal to the others.
      Future<bool?> probe(String codec, int w, int h) async {
        try {
          final support = await web.VideoEncoder.isConfigSupported(
            web.VideoEncoderConfig(
              codec: codec,
              width: w,
              height: h,
              bitrate: 400000,
              framerate: 24,
            ),
          ).toDart;
          return support.supported;
        } catch (e) {
          // ignore: avoid_print
          print('SPIKE availability $codec ${w}x$h threw: $e');
          return null;
        }
      }

      final results = <String, bool?>{};
      // Same codec at 720p AND 360p: H.264 level caps the frame size
      // (level 3.0 MaxFS 1620 MBs < 1280x720's 3600 MBs, so a level-30
      // codec can be false at 720p and true at 360p).
      for (final codec in [
        'avc1.42001E', // H.264 Baseline 3.0 — the planned codec
        'avc1.42e01e', // H.264 Constrained Baseline 3.0
        'avc1.4d001e', // H.264 Main 3.0
        'avc1.4d001f', // H.264 Main 3.1
        'avc1.64001f', // H.264 High 3.1
        'avc1.640028', // H.264 High 4.0
        'vp8', // control
        'vp09.00.10.08', // VP9 profile 0 — control
      ]) {
        results['$codec@720p'] = await probe(codec, 1280, 720);
        results['$codec@360p'] = await probe(codec, 640, 360);
      }
      // Ground truth beyond isConfigSupported: does configure() itself
      // accept the codec? (isConfigSupported is advisory.)
      Future<String> tryConfigure(String codec, int w, int h) async {
        try {
          final enc = web.VideoEncoder(
            web.VideoEncoderInit(
              output: ((web.EncodedVideoChunk c, JSObject m) {}).toJS,
              error: ((JSObject e) {}).toJS,
            ),
          );
          enc.configure(
            web.VideoEncoderConfig(
              codec: codec,
              width: w,
              height: h,
              bitrate: 400000,
              framerate: 24,
            ),
          );
          final state = enc.state;
          enc.close();
          return 'configure OK (state=$state)';
        } catch (e) {
          return 'configure THREW: $e';
        }
      }

      final configure42001E720 =
          await tryConfigure('avc1.42001E', 1280, 720);
      final configure42001E360 =
          await tryConfigure('avc1.42001E', 640, 360);
      final configure64001F720 =
          await tryConfigure('avc1.64001f', 1280, 720);
      final mediaRecorderPresent = () {
        try {
          return web.MediaRecorder.isTypeSupported('video/webm') ||
              web.MediaRecorder.isTypeSupported('video/mp4');
        } catch (_) {
          return false;
        }
      }();
      // ignore: avoid_print
      print(
        'SPIKE availability: VideoEncoder present, '
        'isConfigSupported=$results '
        'configure avc1.42001E@720p: $configure42001E720; '
        'avc1.42001E@360p: $configure42001E360; '
        'avc1.64001f@720p: $configure64001F720; '
        'MediaRecorder usable=$mediaRecorderPresent',
      );
      // Hard assertions only on what the spike needs to proceed;
      // the booleans above ARE the result for the coordinator.
      expect(results['avc1.64001f@720p'], isTrue,
          reason: 'no H.264 High 3.1 support at 720p');
    },
  );

  test(
    '2 decode: <video> element + seek-loop frames + createImageBitmap '
    '+ rVFC sample',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final video = await _makeVideo();
      // ignore: avoid_print
      print(
        'SPIKE decode metadata: duration=${video.duration} s '
        'videoWidth=${video.videoWidth} videoHeight=${video.videoHeight}',
      );
      expect(video.duration, closeTo(kClipSeconds, 0.5));
      expect(video.videoWidth, 1280);
      expect(video.videoHeight, 720);

      // createImageBitmap path (seek-based frame grab, no playback).
      video.currentTime = 5.0;
      await _pollUntil(
        () => !video.seeking,
        timeout: const Duration(seconds: 15),
        what: 'seek to 5 s',
      );
      final bitmap = await web.window.createImageBitmap(video).toDart;
      // ignore: avoid_print
      print(
        'SPIKE decode createImageBitmap @5s: '
        'width=${bitmap.width} height=${bitmap.height}',
      );
      expect(bitmap.width, 1280);
      expect(bitmap.height, 720);
      bitmap.close();

      // Full decode via demux + VideoDecoder (the production-shaped
      // path). Every 48th frame is thumbnailed and checksummed to
      // prove distinct content flows through, not one stuck frame.
      final bytes = await loadFixture(kFixture);
      expect(bytes.length, kInputBytes);
      final demuxed = _demuxMp4(bytes);
      // ignore: avoid_print
      print(
        'SPIKE demux: samples=${demuxed.samples.length} '
        'codec=${demuxed.codec} ${demuxed.width}x${demuxed.height} '
        'avcC=${demuxed.avcC.length} B '
        'keyframes=${demuxed.samples.where((s) => s.isKey).length} '
        'firstTs=${demuxed.samples.first.timestampUs}us '
        'lastTs=${demuxed.samples.last.timestampUs}us',
      );
      expect(demuxed.samples.length, 482);
      expect(demuxed.codec, 'avc1.64001f');
      final thumb =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      thumb.width = 32;
      thumb.height = 18;
      final tctx = thumb.getContext('2d') as web.CanvasRenderingContext2D;
      final checksums = <int>[];
      final timestamps = <int>[];
      var firstW = 0;
      var firstH = 0;
      final decodeResult = await _transcode(bytes, (frame, tsUs, index) async {
        timestamps.add(tsUs);
        if (index == 0) {
          firstW = frame.codedWidth;
          firstH = frame.codedHeight;
        }
        if (index % 48 == 0) {
          tctx.drawImage(frame, 0, 0, 32, 18);
          final img = tctx.getImageData(0, 0, 32, 18);
          final px = img.data.toDart;
          var sum = 0;
          for (var i = 0; i < px.length; i += 997) {
            sum = (sum + px[i]) % 1000003;
          }
          checksums.add(sum);
        }
      });
      var monotonic = true;
      for (var i = 1; i < timestamps.length; i++) {
        if (timestamps[i] <= timestamps[i - 1]) monotonic = false;
      }
      // ignore: avoid_print
      print(
        'SPIKE decode demux+VideoDecoder: frames=${decodeResult.frames} '
        'expected=482 codedSize=${firstW}x$firstH '
        'firstTs=${timestamps.first}us lastTs=${timestamps.last}us '
        'monotonic=$monotonic '
        'wall=${decodeResult.wall.inMilliseconds} ms '
        'thumbChecksums(48-frame stride)=$checksums',
      );
      expect(decodeResult.frames, 482);
      expect(monotonic, isTrue);
      expect(firstW, 1280);
      expect(firstH, 720);
      expect(checksums.toSet().length, greaterThan(1),
          reason: 'thumbnails identical — decode may be stuck');

      // rVFC sample (measurement only): is realtime callback delivery
      // usable in this headless Chrome?
      final rvfc = await _sampleRvfc(video, 5);
      // ignore: avoid_print
      print(
        'SPIKE decode rVFC 5 s sample: callbacks=${rvfc.frames} '
        'expected~${5 * kFps} presentedFrames=${rvfc.presented} '
        'droppedFrames=${rvfc.dropped} '
        'wall=${rvfc.wall.inMilliseconds} ms',
      );
      _removeVideo(video);
    },
  );

  test(
    '3 encode ladder 720p: VideoEncoder size vs bitrate',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final bytes = await loadFixture(kFixture);
      expect(bytes.length, kInputBytes);
      final sinks = <_EncoderSink>[
        // 720p needs level 3.1+ (level 3.0 MaxFS 1620 MBs < 720p's
        // 3600 MBs — see test 1). High 3.1 is the working codec.
        _makeAvcSink('720p@800k-variable', 1280, 720, 800000),
        _makeAvcSink('720p@400k-variable', 1280, 720, 400000),
        _makeAvcSink('720p@200k-variable', 1280, 720, 200000),
        _makeAvcSink('720p@100k-variable', 1280, 720, 100000),
        _makeAvcSink('720p@100k-constant', 1280, 720, 100000,
            bitrateMode: 'constant'),
        _makeAvcSink('720p@100k-main31', 1280, 720, 100000,
            codec: 'avc1.4d001f'),
      ];
      final sw = Stopwatch()..start();
      final result = await _transcode(bytes, (frame, tsUs, index) async {
        // First sink takes the frame; the rest take clones.
        sinks.first.encoder.encode(
          frame,
          web.VideoEncoderEncodeOptions(keyFrame: index == 0),
        );
        for (var i = 1; i < sinks.length; i++) {
          final clone = frame.clone();
          sinks[i].encoder.encode(
            clone,
            web.VideoEncoderEncodeOptions(keyFrame: index == 0),
          );
          clone.close();
        }
        // Real backpressure: wait until every queue drains.
        if (index % 24 == 0) {
          await _drainQueues(sinks);
        }
      });
      await _flushAll(sinks);
      sw.stop();
      // ignore: avoid_print
      print(
        'SPIKE encode 720p ladder: frames=${result.frames} '
        'transcodeWall=${result.wall.inMilliseconds} ms '
        'totalWall=${sw.elapsedMilliseconds} ms',
      );
      for (var i = 0; i < sinks.length; i++) {
        _printSink(sinks[i],
            requestedKbps: [800, 400, 200, 100, 100, 100][i]);
      }
      expect(result.frames, greaterThan(400));
      for (final s in sinks) {
        expect(s.chunks.length, greaterThan(400),
            reason: '${s.label} emitted too few chunks');
        expect(s.errors, isEmpty, reason: '${s.label} encoder errors');
      }
    },
  );

  test(
    '4 encode ladder downscaled: 360p + 240p size vs bitrate',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final bytes = await loadFixture(kFixture);
      expect(bytes.length, kInputBytes);
      final sinks360 = <_EncoderSink>[
        // Baseline 3.0 is valid at these resolutions (see test 1).
        _makeAvcSink('360p@200k-variable', 640, 360, 200000,
            codec: 'avc1.42001E'),
        _makeAvcSink('360p@100k-variable', 640, 360, 100000,
            codec: 'avc1.42001E'),
      ];
      final sinks240 = <_EncoderSink>[
        _makeAvcSink('240p@150k-variable (floor)', 426, 240, 150000,
            codec: 'avc1.42001E'),
        _makeAvcSink('240p@100k-variable', 426, 240, 100000,
            codec: 'avc1.42001E'),
        _makeAvcSink('240p@75k-variable', 426, 240, 75000,
            codec: 'avc1.42001E'),
      ];
      final all = [...sinks360, ...sinks240];
      final canvas360 =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas360.width = 640;
      canvas360.height = 360;
      final ctx360 =
          canvas360.getContext('2d') as web.CanvasRenderingContext2D;
      final canvas240 =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas240.width = 426;
      canvas240.height = 240;
      final ctx240 =
          canvas240.getContext('2d') as web.CanvasRenderingContext2D;

      final sw = Stopwatch()..start();
      final result = await _transcode(bytes, (frame, tsUs, index) async {
        final init = web.VideoFrameInit(
          timestamp: tsUs,
          duration: 1000000 ~/ kFps,
        );
        ctx360.drawImage(frame, 0, 0, 640, 360);
        final f360 = web.VideoFrame(canvas360, init);
        sinks360.first.encoder.encode(
          f360,
          web.VideoEncoderEncodeOptions(keyFrame: index == 0),
        );
        final c360 = f360.clone();
        sinks360[1].encoder.encode(
          c360,
          web.VideoEncoderEncodeOptions(keyFrame: index == 0),
        );
        c360.close();
        f360.close();

        ctx240.drawImage(frame, 0, 0, 426, 240);
        final f240 = web.VideoFrame(canvas240, init);
        sinks240.first.encoder.encode(
          f240,
          web.VideoEncoderEncodeOptions(keyFrame: index == 0),
        );
        for (var i = 1; i < sinks240.length; i++) {
          final clone = f240.clone();
          sinks240[i].encoder.encode(
            clone,
            web.VideoEncoderEncodeOptions(keyFrame: index == 0),
          );
          clone.close();
        }
        f240.close();
        if (index % 24 == 0) {
          await _drainQueues(all);
        }
      });
      await _flushAll(all);
      sw.stop();
      // ignore: avoid_print
      print(
        'SPIKE encode downscaled ladder: frames=${result.frames} '
        'transcodeWall=${result.wall.inMilliseconds} ms '
        'totalWall=${sw.elapsedMilliseconds} ms',
      );
      _printSink(sinks360[0], requestedKbps: 200);
      _printSink(sinks360[1], requestedKbps: 100);
      _printSink(sinks240[0], requestedKbps: 150);
      _printSink(sinks240[1], requestedKbps: 100);
      _printSink(sinks240[2], requestedKbps: 75);
      expect(result.frames, greaterThan(400));
      for (final s in all) {
        expect(s.chunks.length, greaterThan(400),
            reason: '${s.label} emitted too few chunks');
        expect(s.errors, isEmpty, reason: '${s.label} encoder errors');
      }
    },
  );

  test(
    '5 muxing: hand-rolled minimal mp4 from VideoEncoder chunks',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final bytes = await loadFixture(kFixture);
      expect(bytes.length, kInputBytes);
      final sink = _makeAvcSink('720p@200k-mux', 1280, 720, 200000);
      final result = await _transcode(bytes, (frame, tsUs, index) async {
        sink.encoder.encode(
          frame,
          web.VideoEncoderEncodeOptions(keyFrame: index == 0),
        );
      });
      await _flushAll([sink]);
      // ignore: avoid_print
      print(
        'SPIKE mux source: frames=${result.frames} '
        'chunks=${sink.chunks.length} keyframes=${sink.keyframes} '
        'bytes=${sink.totalBytes} '
        'description(avcC)=${sink.description == null ? 'MISSING' : '${sink.description!.length} B hex=${sink.description!.take(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...'} '
        'errors=${sink.errors}',
      );
      expect(sink.chunks.length, greaterThan(400));
      expect(sink.description, isNotNull,
          reason: 'no decoderConfig.description — cannot build avcC');
      expect(sink.chunks.first.isKey, isTrue);

      final mp4 = _muxMp4(sink, 1280, 720);
      // ignore: avoid_print
      print(
        'SPIKE mux result: mp4Bytes=${mp4.length} '
        'chunkBytes=${sink.totalBytes} '
        'muxOverhead=${mp4.length - sink.totalBytes} B '
        'fitsBudget=${mp4.length <= kMediaBudgetBytes}',
      );

      // Playability proof, two independent paths:
      // (a) VideoDecoder: demux the muxed bytes with _demuxMp4 and
      //     decode every frame — proves the file is genuinely
      //     decodable, with real (non-black) content mid-clip.
      // (b) <video> element: metadata + seek + play briefly + draw
      //     to canvas. This path is presentation-dependent in
      //     headless Chrome (a paused seek may draw black even for a
      //     valid file), so it is reported, not asserted on.
      final remuxed = _demuxMp4(mp4);
      // ignore: avoid_print
      print(
        'SPIKE mux re-demux: samples=${remuxed.samples.length} '
        'codec=${remuxed.codec} keyframes='
        '${remuxed.samples.where((s) => s.isKey).length}',
      );
      expect(remuxed.samples.length, 482);
      // NOTE: the encoder's avcC says compatibility 0x0c (SPS also
      // 67 64 0c 1f), so the derived codec string is avc1.640c1f, NOT
      // the requested avc1.64001f. Production must derive the decoder
      // codec string FROM the avcC bytes (as _demuxMp4 does), never
      // reuse the requested string.
      expect(remuxed.codec, 'avc1.640c1f');
      final vthumb =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      vthumb.width = 32;
      vthumb.height = 18;
      final vtctx = vthumb.getContext('2d') as web.CanvasRenderingContext2D;
      var decodedFrames = 0;
      var brightChecks = <int, int>{};
      final verifyResult = await _transcode(mp4, (frame, tsUs, index) async {
        decodedFrames++;
        // NOTE: source frames 0 and 240 are genuinely near-black
        // (ffmpeg mean luma 0.1 / 0.8 — fades/dark scenes), so the
        // content check uses bright frames 100 (73.5) and 400 (119.6).
        if (index == 100 || index == 400) {
          vtctx.drawImage(frame, 0, 0, 32, 18);
          final img = vtctx.getImageData(0, 0, 32, 18);
          final px = img.data.toDart;
          var nb = 0;
          for (var i = 0; i < px.length; i += 4) {
            if (px[i] + px[i + 1] + px[i + 2] > 30) nb++;
          }
          brightChecks[index] = nb;
        }
      });
      // ignore: avoid_print
      print(
        'SPIKE mux verify-decode: frames=$decodedFrames '
        'brightFrames nonBlackPixels=$brightChecks / ${32 * 18} '
        'wall=${verifyResult.wall.inMilliseconds} ms',
      );
      expect(decodedFrames, 482);
      expect(brightChecks[100], greaterThan(100),
          reason: 'decoded frame 100 is (near-)black — mux is corrupt');
      expect(brightChecks[400], greaterThan(100),
          reason: 'decoded frame 400 is (near-)black — mux is corrupt');

      final blob = web.Blob(
        [mp4.toJS as JSAny].toJS,
        web.BlobPropertyBag(type: 'video/mp4'),
      );
      final url = web.URL.createObjectURL(blob);
      final v2 = web.document.createElement('video') as web.HTMLVideoElement;
      v2.muted = true;
      v2.preload = 'auto';
      v2.src = url;
      web.document.body!.appendChild(v2);
      await _pollUntil(
        () => v2.readyState >= 1,
        timeout: const Duration(seconds: 30),
        what: 'muxed video loadedmetadata',
      );
      // ignore: avoid_print
      print(
        'SPIKE mux playback: duration=${v2.duration} s '
        'videoWidth=${v2.videoWidth} videoHeight=${v2.videoHeight}',
      );
      expect(v2.duration, closeTo(kClipSeconds, 1.0));
      expect(v2.videoWidth, 1280);
      // Control: the SOURCE file in the same element — its reported
      // duration should match the mux's (both have a B-frame reorder
      // tail past mvhd duration).
      final srcBlob = web.Blob(
        [bytes.toJS as JSAny].toJS,
        web.BlobPropertyBag(type: 'video/mp4'),
      );
      final srcUrl = web.URL.createObjectURL(srcBlob);
      final vSrc =
          web.document.createElement('video') as web.HTMLVideoElement;
      vSrc.muted = true;
      vSrc.preload = 'auto';
      vSrc.src = srcUrl;
      web.document.body!.appendChild(vSrc);
      await _pollUntil(
        () => vSrc.readyState >= 1,
        timeout: const Duration(seconds: 30),
        what: 'source video loadedmetadata',
      );
      // ignore: avoid_print
      print('SPIKE mux playback control: source duration=${vSrc.duration} s');
      _removeVideo(vSrc);
      v2.currentTime = 10.0;
      await _pollUntil(
        () => !v2.seeking,
        timeout: const Duration(seconds: 15),
        what: 'muxed video seek to 10 s',
      );
      // Play briefly so the compositor actually presents a frame,
      // then draw (headless quirk: a paused seek alone may draw black).
      await v2.play().toDart;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      v2.pause();
      final canvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      canvas.width = 320;
      canvas.height = 180;
      final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      ctx.drawImage(v2, 0, 0, 320, 180);
      final img = ctx.getImageData(0, 0, 320, 180);
      final pixels = img.data.toDart.toList();
      var nonBlack = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] + pixels[i + 1] + pixels[i + 2] > 30) nonBlack++;
      }
      // ignore: avoid_print
      print(
        'SPIKE mux playback: <video> frame @~10s nonBlackPixels='
        '$nonBlack / ${320 * 180} (informational: headless '
        'presentation may draw black for a valid file; the '
        'VideoDecoder check above is the assertion)',
      );
      _removeVideo(v2);
    },
  );

  test(
    '6 fallback probe: MediaRecorder on captureStream',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final mimes = <String, bool>{
        'video/webm;codecs=vp9': false,
        'video/webm;codecs=vp8': false,
        'video/mp4;codecs=avc1.42001E': false,
        'video/mp4': false,
      };
      for (final m in mimes.keys) {
        try {
          mimes[m] = web.MediaRecorder.isTypeSupported(m);
        } catch (e) {
          // ignore: avoid_print
          print('SPIKE mediaRecorder isTypeSupported($m) threw: $e');
        }
      }
      // ignore: avoid_print
      print('SPIKE mediaRecorder mime support: $mimes');

      final video = await _makeVideo();
      final stream = video.captureStream();
      final jobs = <_RecorderJob>[];
      void addJob(String mime, int bps, String label) {
        if (mimes[mime] != true) return;
        final blobs = <web.Blob>[];
        final rec = web.MediaRecorder(
          stream,
          web.MediaRecorderOptions(
            mimeType: mime,
            videoBitsPerSecond: bps,
          ),
        );
        rec.addEventListener(
          'dataavailable',
          ((web.Event e) {
            final data = (e as web.BlobEvent).data;
            if (data.size > 0) blobs.add(data);
          }).toJS,
        );
        jobs.add(_RecorderJob(label, mime, bps, rec, blobs));
      }

      addJob('video/webm;codecs=vp9', 200000, 'webm-vp9@200k');
      addJob('video/webm;codecs=vp9', 100000, 'webm-vp9@100k');
      addJob('video/mp4;codecs=avc1.42001E', 100000, 'mp4-avc@100k');
      if (jobs.isEmpty) {
        // ignore: avoid_print
        print('SPIKE mediaRecorder: NO supported mime — probe skipped');
        _removeVideo(video);
        return;
      }
      final sw = Stopwatch()..start();
      for (final j in jobs) {
        j.recorder.start(1000);
      }
      await video.play().toDart;
      await _pollUntil(
        () => video.ended,
        timeout: const Duration(seconds: 60),
        what: 'video ended (MediaRecorder pass)',
      );
      for (final j in jobs) {
        if (j.recorder.state != 'inactive') j.recorder.stop();
      }
      for (final j in jobs) {
        await _pollUntil(
          () => j.recorder.state == 'inactive',
          timeout: const Duration(seconds: 15),
          what: '${j.label} stop',
        );
      }
      sw.stop();
      for (final j in jobs) {
        final bytes = j.blobs.fold(0, (s, b) => s + b.size);
        // Playability: does the recorded blob load as a video?
        var playable = 'not-checked';
        try {
          final url = web.URL.createObjectURL(
            web.Blob(
              j.blobs.map((b) => b).toList().toJS,
              web.BlobPropertyBag(type: j.mime.split(';').first),
            ),
          );
          final v = web.document.createElement('video')
              as web.HTMLVideoElement;
          v.muted = true;
          v.preload = 'auto';
          v.src = url;
          web.document.body!.appendChild(v);
          await _pollUntil(
            () => v.readyState >= 1,
            timeout: const Duration(seconds: 15),
            what: '${j.label} blob loadedmetadata',
          );
          playable = 'duration=${v.duration.toStringAsFixed(2)}s '
              '${v.videoWidth}x${v.videoHeight}';
          _removeVideo(v);
        } catch (e) {
          playable = 'FAILED: $e';
        }
        // ignore: avoid_print
        print(
          'SPIKE mediaRecorder ${j.label}: bytes=$bytes '
          'effBitrate(media 20.08s)='
          '${(bytes * 8 / kClipSeconds / 1000).toStringAsFixed(1)} kbps '
          'effBitrate(wall ${sw.elapsedMilliseconds}ms)='
          '${(bytes * 8 / (sw.elapsedMilliseconds / 1000) / 1000).toStringAsFixed(1)} kbps '
          'blobs=${j.blobs.length} playable=[$playable] '
          'fitsBudget=${bytes <= kMediaBudgetBytes} '
          '(note: MediaRecorder sizes scale with WALL time; headless '
          'playback runs slower than realtime, so the wall bitrate '
          'is the honest one here)',
        );
      }
      // ignore: avoid_print
      print('SPIKE mediaRecorder wall=${sw.elapsedMilliseconds} ms');
      _removeVideo(video);
    },
  );

  test(
    '7 image probe: canvas JPEG re-encode size vs quality',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      // (a) Synthetic gradient + shapes canvas (photo-like complexity).
      final grad =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      grad.width = 1280;
      grad.height = 720;
      final g = grad.getContext('2d') as web.CanvasRenderingContext2D;
      final lg = g.createLinearGradient(0, 0, 1280, 720);
      lg.addColorStop(0, '#3a1c71');
      lg.addColorStop(0.5, '#d76d77');
      lg.addColorStop(1, '#ffaf7b');
      g.fillStyle = lg as JSAny;
      g.fillRect(0, 0, 1280, 720);
      var seed = 1234567;
      int nextRand(int max) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % max;
      }

      for (var i = 0; i < 240; i++) {
        g.fillStyle =
            'rgb(${nextRand(256)},${nextRand(256)},${nextRand(256)})'.toJS;
        g.fillRect(
          nextRand(1200).toDouble(),
          nextRand(680).toDouble(),
          (20 + nextRand(120)).toDouble(),
          (20 + nextRand(90)).toDouble(),
        );
      }
      // (b) A real frame from the clip at 5 s.
      final video = await _makeVideo();
      video.currentTime = 5.0;
      await _pollUntil(
        () => !video.seeking,
        timeout: const Duration(seconds: 15),
        what: 'seek to 5 s (image probe)',
      );
      final frameCanvas =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      frameCanvas.width = 1280;
      frameCanvas.height = 720;
      final fctx =
          frameCanvas.getContext('2d') as web.CanvasRenderingContext2D;
      fctx.drawImage(video, 0, 0, 1280, 720);
      _removeVideo(video);

      Future<(int, int)> shot(
        web.HTMLCanvasElement c,
        String type, [
        double? quality,
      ]) async {
        final completer = Completer<web.Blob?>();
        final sw = Stopwatch()..start();
        if (quality == null) {
          c.toBlob(((web.Blob? b) {
            completer.complete(b);
          }).toJS, type);
        } else {
          c.toBlob(((web.Blob? b) {
            completer.complete(b);
          }).toJS, type, quality.toJS);
        }
        final blob = await completer.future;
        sw.stop();
        return (blob?.size ?? -1, sw.elapsedMilliseconds);
      }

      web.HTMLCanvasElement scaled(
        web.HTMLCanvasElement src,
        int w,
        int h,
      ) {
        final c = web.document.createElement('canvas') as web.HTMLCanvasElement;
        c.width = w;
        c.height = h;
        final ctx = c.getContext('2d') as web.CanvasRenderingContext2D;
        ctx.drawImage(src, 0, 0, w, h);
        return c;
      }

      final grad640 = scaled(grad, 640, 360);
      final frame640 = scaled(frameCanvas, 640, 360);
      final sizes = <String, int>{};
      Future<void> row(String label, web.HTMLCanvasElement c, String type,
          [double? q]) async {
        final (bytes, ms) = await shot(c, type, q);
        sizes[label] = bytes;
        // ignore: avoid_print
        print('SPIKE image $label: $bytes B in ${ms}ms');
      }

      await row('gradient 1280 PNG', grad, 'image/png');
      await row('gradient 1280 JPEG q60', grad, 'image/jpeg', 0.6);
      await row('gradient 1280 JPEG q35', grad, 'image/jpeg', 0.35);
      await row('gradient 640 JPEG q60', grad640, 'image/jpeg', 0.6);
      await row('gradient 640 JPEG q35 (floor)', grad640, 'image/jpeg', 0.35);
      await row('real-frame 1280 PNG', frameCanvas, 'image/png');
      await row('real-frame 1280 JPEG q60', frameCanvas, 'image/jpeg', 0.6);
      await row('real-frame 1280 JPEG q35', frameCanvas, 'image/jpeg', 0.35);
      await row('real-frame 640 JPEG q60', frame640, 'image/jpeg', 0.6);
      await row(
          'real-frame 640 JPEG q35 (floor)', frame640, 'image/jpeg', 0.35);
      // Sanity: JPEG must beat PNG and q35 must beat q60 on the same
      // source; otherwise the canvas encoder is not behaving.
      expect(sizes['gradient 1280 JPEG q60']!,
          lessThan(sizes['gradient 1280 PNG']!));
      expect(sizes['gradient 1280 JPEG q35']!,
          lessThan(sizes['gradient 1280 JPEG q60']!));
      expect(sizes['real-frame 1280 JPEG q35']!,
          lessThan(sizes['real-frame 1280 JPEG q60']!));
      expect(sizes['real-frame 640 JPEG q35 (floor)']!,
          lessThan(sizes['real-frame 640 JPEG q60']!));
    },
  );
}

class _RecorderJob {
  _RecorderJob(this.label, this.mime, this.bitrate, this.recorder, this.blobs);

  final String label;
  final String mime;
  final int bitrate;
  final web.MediaRecorder recorder;
  final List<web.Blob> blobs;
}

// ---------------------------------------------------------------------------
// Minimal MP4 muxer (spike-only): ftyp + moov + a single mdat chunk.
// Samples are written in encoder-output (decode) order; if presentation
// timestamps are not monotonic in that order a ctts box is emitted.
// Timescale 24000 (24 fps x 1000, so 41.667 ms frames are exact).
// avcC comes from the encoder's decoderConfig.
// ---------------------------------------------------------------------------

void _u32(BytesBuilder b, int v) {
  b.add([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
}

void _u16(BytesBuilder b, int v) {
  b.add([(v >> 8) & 0xFF, v & 0xFF]);
}

Uint8List _box(String type, Uint8List payload) {
  final b = BytesBuilder();
  _u32(b, payload.length + 8);
  b.add(type.codeUnits);
  b.add(payload);
  return b.takeBytes();
}

Uint8List _muxMp4(_EncoderSink sink, int width, int height) {
  // Timescale 24000 (24 fps x 1000): a 41.667 ms frame is exactly
  // 1000 units. Timescale 1000 would round every frame to 42 ms and
  // drift +160 ms over this clip (measured before this fix).
  const timescale = 24000;
  final samples = sink.chunks;
  final n = samples.length;
  // Per-sample presentation time + duration in timescale units.
  final ptsTs = List<int>.generate(
    n,
    (i) => (samples[i].timestampUs * timescale / 1000000).round(),
  );
  final durTs = List<int>.generate(n, (i) {
    var d =
        (samples[i].durationUs * timescale / 1000000).round();
    if (d < 1) d = 1;
    return d;
  });
  // Decode timestamps: running sum of durations in file order.
  final dtsTs = List<int>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dtsTs[i] = dtsTs[i - 1] + durTs[i - 1];
  }
  final totalTs = dtsTs.last + durTs.last;
  final cttsOffsets = List<int>.generate(n, (i) => ptsTs[i] - dtsTs[i]);
  final needsCtts = cttsOffsets.any((o) => o != 0);

  // ---- stts: group consecutive equal durations (decode order).
  List<(int, int)> runs(List<int> values) {
    final out = <(int, int)>[];
    var count = 1;
    for (var i = 1; i < values.length; i++) {
      if (values[i] == values[i - 1]) {
        count++;
      } else {
        out.add((count, values[i - 1]));
        count = 1;
      }
    }
    out.add((count, values.last));
    return out;
  }

  Uint8List boxWithVersion(String type, void Function(BytesBuilder) body) {
    final b = BytesBuilder();
    _u32(b, 0); // version(0) + flags(0)
    body(b);
    return _box(type, b.takeBytes());
  }

  // ---- ftyp.
  final ftypBody = BytesBuilder();
  ftypBody.add('isom'.codeUnits);
  _u32(ftypBody, 512);
  for (final brand in ['isom', 'iso2', 'avc1', 'mp41']) {
    ftypBody.add(brand.codeUnits);
  }
  final ftyp = _box('ftyp', ftypBody.takeBytes());

  // ---- mvhd / tkhd / mdhd / hdlr / vmhd / dinf.
  final mvhd = boxWithVersion('mvhd', (b) {
    _u32(b, 0); // creation_time
    _u32(b, 0); // modification_time
    _u32(b, timescale); // timescale
    _u32(b, totalTs); // duration
    _u32(b, 0x00010000); // rate 1.0
    _u16(b, 0x0100); // volume
    _u16(b, 0); // reserved
    _u32(b, 0);
    _u32(b, 0); // reserved
    for (final m in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _u32(b, m);
    }
    for (var i = 0; i < 6; i++) {
      _u32(b, 0);
    }
    _u32(b, 2); // next_track_ID
  });
  final tkhd = (() {
    final b = BytesBuilder();
    _u32(b, 0x00000007); // version 0, flags: enabled|in_movie|in_preview
    _u32(b, 0);
    _u32(b, 0);
    _u32(b, 1); // track_ID
    _u32(b, 0); // reserved
    _u32(b, totalTs); // duration
    _u32(b, 0);
    _u32(b, 0); // reserved
    _u16(b, 0); // layer
    _u16(b, 0); // alternate_group
    _u16(b, 0); // volume (video)
    _u16(b, 0); // reserved
    for (final m in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _u32(b, m);
    }
    _u32(b, width << 16);
    _u32(b, height << 16);
    return _box('tkhd', b.takeBytes());
  })();
  final mdhd = boxWithVersion('mdhd', (b) {
    _u32(b, 0);
    _u32(b, 0);
    _u32(b, timescale);
    _u32(b, totalTs);
    _u16(b, 0x55c7); // language 'und'
    _u16(b, 0);
  });
  final hdlr = boxWithVersion('hdlr', (b) {
    _u32(b, 0); // pre_defined
    b.add('vide'.codeUnits);
    _u32(b, 0);
    _u32(b, 0);
    _u32(b, 0);
    b.add('VideoHandler'.codeUnits);
    b.add([0]);
  });
  final vmhd = (() {
    final b = BytesBuilder();
    _u32(b, 0x00000001); // version 0, flags 1
    _u16(b, 0); // graphicsmode
    _u16(b, 0);
    _u16(b, 0);
    _u16(b, 0); // opcolor
    return _box('vmhd', b.takeBytes());
  })();
  final urlBox = _box('url ', Uint8List.fromList([0, 0, 0, 1]));
  final dref = boxWithVersion('dref', (b) {
    _u32(b, 1); // entry_count
    b.add(urlBox);
  });
  final dinf = _box('dinf', dref);

  // ---- stbl.
  final avc1Entry = (() {
    final b = BytesBuilder();
    b.add(List<int>.filled(6, 0));
    _u16(b, 1); // data_reference_index
    _u16(b, 0);
    _u16(b, 0);
    b.add(List<int>.filled(12, 0));
    _u16(b, width);
    _u16(b, height);
    _u32(b, 0x00480000); // horizresolution 72 dpi
    _u32(b, 0x00480000); // vertresolution 72 dpi
    _u32(b, 0); // reserved
    _u16(b, 1); // frame_count
    b.add(List<int>.filled(32, 0)); // compressorname (empty)
    _u16(b, 0x0018); // depth
    _u16(b, 0xFFFF); // pre_defined
    b.add(_box('avcC', sink.description!));
    return _box('avc1', b.takeBytes());
  })();
  final stsd = boxWithVersion('stsd', (b) {
    _u32(b, 1); // entry_count
    b.add(avc1Entry);
  });
  final stts = boxWithVersion('stts', (b) {
    final r = runs(durTs);
    _u32(b, r.length);
    for (final (count, delta) in r) {
      _u32(b, count);
      _u32(b, delta);
    }
  });
  final stss = boxWithVersion('stss', (b) {
    final keys = <int>[];
    for (var i = 0; i < n; i++) {
      if (samples[i].isKey) keys.add(i + 1); // 1-based
    }
    _u32(b, keys.length);
    for (final k in keys) {
      _u32(b, k);
    }
  });
  final stsc = boxWithVersion('stsc', (b) {
    _u32(b, 1);
    _u32(b, 1); // first_chunk
    _u32(b, n); // samples_per_chunk: ALL samples live in the one mdat chunk
    _u32(b, 1); // sample_description_index
  });
  final stsz = boxWithVersion('stsz', (b) {
    _u32(b, 0); // sample_size (0 = sizes follow)
    _u32(b, n);
    for (final s in samples) {
      _u32(b, s.data.length);
    }
  });
  Uint8List stcoWith(int offset) => boxWithVersion('stco', (b) {
        _u32(b, 1);
        _u32(b, offset);
      });
  Uint8List? ctts;
  if (needsCtts) {
    ctts = boxWithVersion('ctts', (b) {
      final r = runs(cttsOffsets);
      _u32(b, r.length);
      for (final (count, offset) in r) {
        _u32(b, count);
        _u32(b, offset);
      }
    });
  }

  Uint8List buildMoov(int chunkOffset) {
    final stblBody = BytesBuilder()
      ..add(stsd)
      ..add(stts)
      ..add(stss);
    if (ctts != null) stblBody.add(ctts);
    stblBody
      ..add(stsc)
      ..add(stsz)
      ..add(stcoWith(chunkOffset));
    final stbl = _box('stbl', stblBody.takeBytes());
    final minfBody = BytesBuilder()
      ..add(vmhd)
      ..add(dinf)
      ..add(stbl);
    final minf = _box('minf', minfBody.takeBytes());
    final mdiaBody = BytesBuilder()
      ..add(mdhd)
      ..add(hdlr)
      ..add(minf);
    final mdia = _box('mdia', mdiaBody.takeBytes());
    final trakBody = BytesBuilder()
      ..add(tkhd)
      ..add(mdia);
    final trak = _box('trak', trakBody.takeBytes());
    final moovBody = BytesBuilder()
      ..add(mvhd)
      ..add(trak);
    return _box('moov', moovBody.takeBytes());
  }

  // First pass with offset 0 to learn moov's size (it is offset-
  // independent), then rebuild with the true chunk offset.
  final moovProbe = buildMoov(0);
  final mdatStart = ftyp.length + moovProbe.length + 8;
  final moov = buildMoov(mdatStart);
  assert(moov.length == moovProbe.length, 'moov size must be stable');

  final mdatBody = BytesBuilder();
  for (final s in samples) {
    mdatBody.add(s.data);
  }
  final mdat = _box('mdat', mdatBody.takeBytes());
  final out = BytesBuilder()
    ..add(ftyp)
    ..add(moov)
    ..add(mdat);
  return out.takeBytes();
}
