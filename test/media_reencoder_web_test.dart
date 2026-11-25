/// Chrome tests for the production WebCodecs re-encoder
/// (lib/services/media_reencoder_web.dart).
///
/// Run: flutter test --platform chrome test/media_reencoder_web_test.dart
/// (NEVER -d chrome: silently ignored, Chrome tests skip.)
///
/// The budget here is the TRUE one from Worker B's ratio engine —
/// NOT the flat input/13.3: a 1-data-page encode carries the stream
/// twice (1 data + 1 parity frame), so the PDF is ~2.08x the media.
/// Pinned: reencodeTargetMediaBytes(3,105,557) == 142,519 B, and the
/// finished PDF must land at or below 310,555 B.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/ratio_engine.dart';
import 'package:middle_out/codec/reencode.dart';
import 'package:middle_out/services/audio_webcodecs.dart';
import 'package:middle_out/services/media_reencoder.dart';
import 'package:middle_out/services/mp4_demuxer.dart';
import 'package:web/web.dart' as web;

import 'fixture_loader.dart';

const String kFixture = 'sintel-720p.mp4';
const int kInputBytes = 3105557;

/// The true media budget for the clip (ratio-engine solver).
const int kTrueMediaBudget = 142519;

/// The PDF target: input / 10.
const int kPdfTarget = 310555;

const Duration kTestTimeout = Duration(minutes: 6);

Future<void> _pollUntil(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
  String what = 'condition',
}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('timed out waiting for $what after $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
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

/// One encoded chunk, copied out of the encoder callback.
class _Chunk {
  _Chunk(this.data, this.timestampUs, this.durationUs, this.isKey);

  final Uint8List data;
  final int timestampUs;
  final int durationUs;
  final bool isKey;
}

class _Sink {
  _Sink(this.label, this.encoder);

  final String label;
  final web.VideoEncoder encoder;
  final List<_Chunk> chunks = [];
  final List<String> errors = [];

  int get totalBytes => chunks.fold(0, (s, c) => s + c.data.length);
  int get keyframes => chunks.where((c) => c.isKey).length;
}

_Sink _makeSink(String label, int width, int height, int bitrate) {
  late final _Sink sink;
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
      }).toJS,
      error: ((JSObject e) {
        sink.errors.add(_jsErrorString(e));
      }).toJS,
    ),
  );
  sink = _Sink(label, encoder);
  encoder.configure(
    web.VideoEncoderConfig(
      codec: width >= 720 ? 'avc1.64001f' : 'avc1.42001E',
      width: width,
      height: height,
      bitrate: bitrate,
      framerate: 24,
      bitrateMode: 'variable',
    ),
  );
  return sink;
}

/// Decodes [mp4Bytes] with VideoDecoder and counts the frames,
/// checking frames 100 and 400 are non-black (real content, not a
/// stuck frame). Returns (frames, wall).
Future<({int frames, Duration wall})> _decodeCount(
  Uint8List mp4Bytes,
) async {
  final demuxed = demuxMp4(mp4Bytes);
  final sw = Stopwatch()..start();
  final pending = Queue<web.VideoFrame>();
  final errors = <String>[];
  var decodeFinished = false;
  var consumed = 0;
  final bright = <int, int>{};
  final thumb =
      web.document.createElement('canvas') as web.HTMLCanvasElement;
  thumb.width = 32;
  thumb.height = 18;
  final tctx = thumb.getContext('2d') as web.CanvasRenderingContext2D;
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
      if (index == 100 || index == 400) {
        tctx.drawImage(frame, 0, 0, 32, 18);
        final img = tctx.getImageData(0, 0, 32, 18);
        final px = img.data.toDart;
        var nb = 0;
        for (var i = 0; i < px.length; i += 4) {
          if (px[i] + px[i + 1] + px[i + 2] > 30) nb++;
        }
        bright[index] = nb;
      }
      frame.close();
    }
  }

  await Future.wait([submit(), pump()]);
  decoder.close();
  sw.stop();
  if (errors.isNotEmpty) {
    throw StateError('VideoDecoder errors: $errors');
  }
  expect(bright[100], greaterThan(100),
      reason: 're-decoded frame 100 is (near-)black');
  expect(bright[400], greaterThan(100),
      reason: 're-decoded frame 400 is (near-)black');
  return (frames: consumed, wall: sw.elapsed);
}

void main() {
  test(
    'a video: Sintel re-encodes inside the TRUE 142,519 B budget',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      final bytes = await loadFixture(kFixture);
      expect(bytes.length, kInputBytes);

      // The budget itself comes from Worker B's solver — and the
      // pinned value is the regression check on the solver.
      final budget = RatioEngine.reencodeTargetMediaBytes(
        fileSize: kInputBytes,
      );
      // ignore: avoid_print
      print('REENCODE budget: solver=$budget pinned=$kTrueMediaBudget');
      expect(budget, kTrueMediaBudget);

      final reencoder = createMediaReencoder();
      expect(reencoder.isAvailable, isTrue);
      expect(reencoder.encoderName, 'WebCodecs avc1');

      // The proposal hook must describe real settings BEFORE the
      // encode runs (the proposal screen shows these numbers).
      final plan = await reencoder.plan(
        bytes,
        kFixture,
        targetBytes: budget!,
      );
      expect(plan, isNotNull);
      // ignore: avoid_print
      print('REENCODE plan: ${plan!.encoder} — ${plan.settingsLabel}');
      expect(plan.encoder, 'WebCodecs avc1');
      expect(plan.settingsLabel, contains('50 kbps'));
      expect(plan.settingsLabel, contains('24 fps'));
      expect(plan.settingsLabel, contains('audio dropped to fit 10:1'));
      // The proposal must show the RANGE, not just the first rung:
      // the encode steps down the ladder, and for this clip it lands
      // on the floor rung — the user confirms the worst case too.
      expect(plan.settingsLabel,
          contains('stepping down to 320x180 @ 50 kbps'));

      final sw = Stopwatch()..start();
      final out = await reencoder.reencode(
        bytes,
        kFixture,
        targetBytes: budget,
      );
      sw.stop();
      expect(out, isNotNull);
      // ignore: avoid_print
      print(
        'REENCODE result: bytes=${out!.bytes.length} budget=$budget '
        'encoder=${out.encoder} settings=[${out.settingsLabel}] '
        'wall=${sw.elapsedMilliseconds} ms',
      );
      expect(out.bytes.length, lessThanOrEqualTo(budget));
      expect(out.encoder, startsWith('WebCodecs avc1.'));
      expect(out.settingsLabel, contains('50 kbps'));
      expect(out.settingsLabel, contains('24 fps'));
      expect(out.settingsLabel, contains('audio dropped to fit 10:1'));

      // The finished PDF (ratio-engine model) must fit input / 10.
      final pdfBytes = RatioEngine.modelledPdfBytes(
        compressedSize: out.bytes.length,
      );
      // ignore: avoid_print
      print('REENCODE modelled PDF: $pdfBytes B (target <= $kPdfTarget)');
      expect(pdfBytes, lessThanOrEqualTo(kPdfTarget));

      // The muxed file re-demuxes to the same 482 samples...
      final remuxed = demuxMp4(out.bytes);
      expect(remuxed.samples.length, 482);
      expect(remuxed.codec, startsWith('avc1.'));
      expect(remuxed.width, anyOf(426, 320));
      // ...VideoDecoder re-decodes every frame with real content...
      final decoded = await _decodeCount(out.bytes);
      // ignore: avoid_print
      print(
        'REENCODE verify-decode: frames=${decoded.frames} '
        'wall=${decoded.wall.inMilliseconds} ms',
      );
      expect(decoded.frames, 482);
      // ...and <video> reports the 20.083 s duration within 50 ms.
      final blob = web.Blob(
        [out.bytes.toJS as JSAny].toJS,
        web.BlobPropertyBag(type: 'video/mp4'),
      );
      final url = web.URL.createObjectURL(blob);
      final video =
          web.document.createElement('video') as web.HTMLVideoElement;
      video.muted = true;
      video.preload = 'auto';
      video.src = url;
      web.document.body!.appendChild(video);
      await _pollUntil(
        () => video.readyState >= 1,
        what: 're-encoded video loadedmetadata',
      );
      // ignore: avoid_print
      print(
        'REENCODE playback: duration=${video.duration} s '
        '${video.videoWidth}x${video.videoHeight}',
      );
      expect(video.duration, closeTo(20.083, 0.05));
      expect(video.videoWidth, remuxed.width);
      video.pause();
      video.remove();
    },
  );

  test(
    'ladder probe: actual bytes of every pinned rung (keyframes 2 s)',
    // Sequential single-rung encodes: 8 parallel software encoders
    // on this 1.5-CPU VM blew the 6-min timeout (the parallel
    // version). One decode + one encode per rung, ~45 s each at low
    // res, slower at 720p — 15 min total budget.
    timeout: const Timeout(Duration(minutes: 15)),
    skip: !kIsWeb,
    () async {
      // The pinned ladder (coordinator): each rung encoded on its
      // own decode pass, keyframes forced every 2 s (48 frames) —
      // the numbers the production ladder bets on.
      const rungs = <(int, int, int)>[
        (1280, 720, 800000),
        (1280, 720, 400000),
        (640, 360, 200000),
        (640, 360, 100000),
        (426, 240, 100000),
        (426, 240, 75000),
        (426, 240, 50000),
        (320, 180, 50000),
      ];
      final bytes = await loadFixture(kFixture);
      final demuxed = demuxMp4(bytes);

      /// Decodes [demuxed] once and encodes it at one rung.
      Future<({int bytes, int keyframes, int wallMs})> encodeRung(
        int width,
        int height,
        int bitrate,
      ) async {
        final sink = _makeSink(
          '${width}x$height@${bitrate ~/ 1000}k',
          width,
          height,
          bitrate,
        );
        final canvas =
            web.document.createElement('canvas') as web.HTMLCanvasElement;
        canvas.width = width;
        canvas.height = height;
        final ctx =
            canvas.getContext('2d') as web.CanvasRenderingContext2D;
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
            final index = consumed++;
            final tsUs = frame.timestamp;
            final durUs = frame.duration ?? (1000000 ~/ 24);
            ctx.drawImage(frame, 0, 0, width, height);
            final out = web.VideoFrame(
              canvas,
              web.VideoFrameInit(timestamp: tsUs, duration: durUs),
            );
            sink.encoder.encode(
              out,
              web.VideoEncoderEncodeOptions(keyFrame: index % 48 == 0),
            );
            out.close();
            frame.close();
            while (sink.encoder.encodeQueueSize > 24) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          }
        }

        await Future.wait([submit(), pump()]);
        await sink.encoder.flush().toDart;
        sink.encoder.close();
        decoder.close();
        sw.stop();
        expect(errors, isEmpty);
        expect(sink.errors, isEmpty, reason: sink.label);
        expect(sink.chunks.length, greaterThan(400), reason: sink.label);
        expect(consumed, 482, reason: sink.label);
        return (
          bytes: sink.totalBytes,
          keyframes: sink.keyframes,
          wallMs: sw.elapsedMilliseconds,
        );
      }

      // ignore: avoid_print
      print(
        'LADDER probe (sequential, keyframes every 2 s; budget '
        '$kTrueMediaBudget B; spike single-keyframe baselines: '
        '240p@75k=187804 B, 240p@100k=235509 B, 360p@100k=272196 B)',
      );
      for (final (w, h, bitrate) in rungs) {
        final r = await encodeRung(w, h, bitrate);
        final effKbps = r.bytes * 8 / 20.083 / 1000;
        // ignore: avoid_print
        print(
          'LADDER ${w}x$h@${bitrate ~/ 1000}k: bytes=${r.bytes} '
          'eff=${effKbps.toStringAsFixed(1)} kbps '
          'keyframes=${r.keyframes} wall=${r.wallMs} ms '
          'fitsTrueBudget=${r.bytes <= kTrueMediaBudget}',
        );
      }
    },
  );

  test(
    'b image: PNG re-encodes to JPEG inside the target',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      // A photo-like 1280x720 canvas, exported as PNG.
      final src =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      src.width = 1280;
      src.height = 720;
      final g = src.getContext('2d') as web.CanvasRenderingContext2D;
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
      Future<Uint8List> shot(String type, [double? quality]) async {
        final completer = Completer<web.Blob?>();
        if (quality == null) {
          src.toBlob(((web.Blob? b) {
            completer.complete(b);
          }).toJS, type);
        } else {
          src.toBlob(((web.Blob? b) {
            completer.complete(b);
          }).toJS, type, quality.toJS);
        }
        final blob = await completer.future;
        final buf = await blob!.arrayBuffer().toDart;
        final dartBuf = buf.toDart;
        return Uint8List.view(dartBuf, 0, dartBuf.lengthInBytes);
      }

      final png = await shot('image/png');
      // ignore: avoid_print
      print('IMAGE source PNG: ${png.length} B');
      expect(png.length, greaterThan(50000));

      final reencoder = createMediaReencoder();
      final out = await reencoder.reencode(png, 'photo.png', targetBytes: 15000);
      expect(out, isNotNull);
      // ignore: avoid_print
      print(
        'IMAGE re-encoded: bytes=${out!.bytes.length} '
        'encoder=${out.encoder} settings=[${out.settingsLabel}]',
      );
      expect(out.bytes.length, lessThanOrEqualTo(15000));
      // JPEG magic.
      expect(out.bytes[0], 0xFF);
      expect(out.bytes[1], 0xD8);
      expect(out.bytes[2], 0xFF);
      expect(out.encoder, 'canvas JPEG');
      expect(out.settingsLabel, contains('JPEG'));
      expect(out.settingsLabel, contains('PNG → JPEG'));

      // A small JPEG that already fits is kept as-is, honestly.
      final smallJpeg = await shot('image/jpeg', 0.7);
      final kept = await reencoder.reencode(
        smallJpeg,
        'photo.jpg',
        targetBytes: 100000,
      );
      expect(kept, isNotNull);
      expect(kept!.bytes, smallJpeg);
      expect(kept.encoder, 'original');
    },
  );

  test(
    'c audio probe + non-MP4 rejection + plan() on non-video',
    timeout: const Timeout(kTestTimeout),
    skip: !kIsWeb,
    () async {
      // AudioEncoder AAC probe (48 kHz stereo, the Sintel track).
      final audioResults = <int, bool>{};
      for (final bitrate in [12000, 16000, 24000, 32000]) {
        audioResults[bitrate] = await probeAudioEncoder(
          sampleRate: 48000,
          channels: 2,
          bitrate: bitrate,
        );
      }
      // Controls at "normal" rates: if these are false too, this
      // Chrome build has no AAC encoder at all (not just a low-rate
      // limit) — the re-encoder then always drops audio, plainly.
      final control64k = await probeAudioEncoder(
        sampleRate: 48000,
        channels: 2,
        bitrate: 64000,
      );
      final control128k = await probeAudioEncoder(
        sampleRate: 44100,
        channels: 2,
        bitrate: 128000,
      );
      // ignore: avoid_print
      print(
        'AUDIO probe hasAudioEncoder=$hasAudioEncoder '
        'AAC 48kHz stereo support by bitrate: $audioResults '
        'controls: 48kHz/64k=$control64k 44.1kHz/128k=$control128k',
      );
      expect(audioResults.length, 4);

      final reencoder = createMediaReencoder();

      // WebM (EBML) is rejected with the plain reason, not returned.
      final webm = Uint8List(64);
      webm[0] = 0x1A;
      webm[1] = 0x45;
      webm[2] = 0xDF;
      webm[3] = 0xA3;
      await expectLater(
        reencoder.reencode(webm, 'clip.webm', targetBytes: 100000),
        throwsA(
          isA<ReencodeException>().having(
            (e) => e.message,
            'message',
            contains("can't be re-encoded in the browser yet"),
          ),
        ),
      );
      // QuickTime MOV (ftyp 'qt  ') is rejected the same way.
      final mov = Uint8List(12);
      mov.setRange(4, 8, 'ftyp'.codeUnits);
      mov.setRange(8, 12, 'qt  '.codeUnits);
      await expectLater(
        reencoder.reencode(mov, 'clip.mov', targetBytes: 100000),
        throwsA(isA<ReencodeException>()),
      );
      // Non-media returns null (not an exception).
      final text = Uint8List.fromList('hello, world'.codeUnits);
      expect(
        await reencoder.reencode(text, 'notes.txt', targetBytes: 1000),
        isNull,
      );
      // plan() returns null for non-media too.
      expect(
        await reencoder.plan(text, 'notes.txt', targetBytes: 1000),
        isNull,
      );
    },
  );
}
