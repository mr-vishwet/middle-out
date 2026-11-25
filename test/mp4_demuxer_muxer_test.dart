/// VM tests for the production MP4 demuxer + muxer (pure Dart).
///
/// The Sintel fixture is read straight off disk with `dart:io` —
// no HTTP fixture loader needed on the VM.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/services/mp4_demuxer.dart';
import 'package:middle_out/services/mp4_muxer.dart';

Uint8List _fixtureBytes() =>
    File('test/fixtures/sintel-720p.mp4').readAsBytesSync();

void main() {
  test('demux: Sintel fixture parses to 482 samples', () {
    final bytes = _fixtureBytes();
    expect(bytes.length, 3105557);
    expect(isMp4Container(bytes), isTrue);
    expect(mp4MajorBrand(bytes), 'isom');

    final demuxed = demuxMp4(bytes);
    expect(demuxed.samples.length, 482);
    expect(demuxed.width, 1280);
    expect(demuxed.height, 720);
    expect(demuxed.codec, 'avc1.64001f');
    expect(demuxed.avcC.length, greaterThan(0));
    expect(codecStringFromAvcC(demuxed.avcC), 'avc1.64001f');
    // 3 keyframes in the source GOP structure.
    expect(demuxed.samples.where((s) => s.isKey).length, 3);
    expect(demuxed.samples.first.isKey, isTrue);
    // Presentation timestamps in DECODE order are NOT monotonic
    // (B-frames) — and even sorted they are not a clean grid: this
    // real file starts at pts 83333 us (a 2-frame B-delay) and has
    // two 83333 us gaps in its 482 pts values. Assert the actual
    // shape instead: 482 distinct pts, gaps only 41666/41667/83333.
    final sortedPts = demuxed.samples.map((s) => s.timestampUs).toList()
      ..sort();
    expect(sortedPts.toSet().length, 482);
    expect(sortedPts.first, 83333);
    expect(sortedPts.last, 20208333);
    var gridOk = true;
    for (var i = 1; i < sortedPts.length; i++) {
      final gap = sortedPts[i] - sortedPts[i - 1];
      if (gap != 41666 && gap != 41667 && gap != 83333) gridOk = false;
    }
    expect(gridOk, isTrue);
    // Decode-order last pts + duration == the mdhd duration.
    expect(demuxed.durationUs, closeTo(20166667, 50000));
    expect(demuxed.fps, closeTo(24, 0.5));
    // Most frames have pts != dts (B-frames) — ctts is doing work.
    final dts = <int>[];
    var acc = 0;
    for (final s in demuxed.samples) {
      dts.add(acc);
      acc += s.durationUs;
    }
    var reordered = 0;
    for (var i = 0; i < demuxed.samples.length; i++) {
      if (demuxed.samples[i].timestampUs != dts[i]) reordered++;
    }
    expect(reordered, greaterThan(400));
  });

  test('demux: Sintel audio track parses', () {
    final demuxed = demuxMp4(_fixtureBytes());
    final audio = demuxed.audio;
    expect(audio, isNotNull);
    expect(audio!.sampleRate, 48000);
    expect(audio.channels, 2);
    expect(audio.asc.length, greaterThanOrEqualTo(2));
    // 20.08 s of AAC at 1024 samples/frame, 48 kHz ≈ 938 frames;
    // the audio track ends at 20.011 s, before the video's
    // B-reorder tail.
    expect(audio.samples.length, 938);
    expect(audio.samples.every((s) => s.isKey), isTrue);
    expect(audio.durationUs, closeTo(20010666, 50000));
    var monotonic = true;
    for (var i = 1; i < audio.samples.length; i++) {
      if (audio.samples[i].timestampUs < audio.samples[i - 1].timestampUs) {
        monotonic = false;
      }
    }
    expect(monotonic, isTrue);
  });

  test('mux: video-only round-trip re-demuxes identically', () {
    final demuxed = demuxMp4(_fixtureBytes());
    final muxed = muxMp4(
      videoSamples: demuxed.samples,
      avcC: demuxed.avcC,
      width: demuxed.width,
      height: demuxed.height,
    );
    // Mux overhead is small (one mdat + moov tables).
    final chunkBytes =
        demuxed.samples.fold(0, (s, c) => s + c.data.length);
    expect(muxed.length - chunkBytes, lessThan(8192));
    final back = demuxMp4(muxed);
    expect(back.samples.length, 482);
    expect(back.codec, 'avc1.64001f');
    expect(back.width, 1280);
    expect(back.height, 720);
    expect(back.durationUs, closeTo(20166667, 50000));
    for (var i = 0; i < 482; i++) {
      expect(back.samples[i].data.length, demuxed.samples[i].data.length);
      expect(back.samples[i].timestampUs, demuxed.samples[i].timestampUs);
      expect(back.samples[i].isKey, demuxed.samples[i].isKey);
    }
  });

  test('mux: video+audio round-trip keeps both tracks', () {
    final demuxed = demuxMp4(_fixtureBytes());
    final muxed = muxMp4(
      videoSamples: demuxed.samples,
      avcC: demuxed.avcC,
      width: demuxed.width,
      height: demuxed.height,
      audio: demuxed.audio,
    );
    final back = demuxMp4(muxed);
    expect(back.samples.length, 482);
    final audio = back.audio;
    expect(audio, isNotNull);
    expect(audio!.sampleRate, 48000);
    expect(audio.channels, 2);
    expect(audio.asc, demuxed.audio!.asc);
    expect(audio.samples.length, demuxed.audio!.samples.length);
    for (var i = 0; i < audio.samples.length; i++) {
      expect(audio.samples[i].data.length,
          demuxed.audio!.samples[i].data.length);
      expect(audio.samples[i].timestampUs,
          demuxed.audio!.samples[i].timestampUs);
    }
    expect(back.durationUs, closeTo(20166667, 50000));
  });

  test('mux: synthetic chunks with B-frame reorder need ctts', () {
    // 3 frames, decode order 0,1,2 with pts 0, 83333, 41667
    // (frame 2 is a B-frame shown before frame 1).
    final avcC = Uint8List.fromList(
        [0x01, 0x64, 0x00, 0x1f, 0xff, 0xe1, 0x00, 0x0a, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x01, 0x00, 0x04, 11, 12, 13, 14]);
    final samples = <Mp4Sample>[
      Mp4Sample(
          data: Uint8List.fromList([0, 0, 0, 1, 0x65]),
          timestampUs: 0,
          durationUs: 41667,
          isKey: true),
      Mp4Sample(
          data: Uint8List.fromList([0, 0, 0, 1, 0x41]),
          timestampUs: 83333,
          durationUs: 41667,
          isKey: false),
      Mp4Sample(
          data: Uint8List.fromList([0, 0, 0, 1, 0x01]),
          timestampUs: 41667,
          durationUs: 41667,
          isKey: false),
    ];
    final muxed = muxMp4(
      videoSamples: samples,
      avcC: avcC,
      width: 640,
      height: 360,
    );
    expect(codecStringFromAvcC(avcC), 'avc1.64001f');
    final back = demuxMp4(muxed);
    expect(back.samples.length, 3);
    expect(back.samples[0].timestampUs, 0);
    expect(back.samples[1].timestampUs, 83333);
    expect(back.samples[2].timestampUs, 41667);
    expect(back.samples[0].isKey, isTrue);
    expect(back.samples[1].isKey, isFalse);
  });

  test('container sniffing rejects non-MP4 inputs', () {
    // WebM/Matroska EBML header.
    expect(
      isMp4Container(
          Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0, 0, 0, 0, 0])),
      isFalse,
    );
    expect(mp4MajorBrand(Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3])), isNull);
    // QuickTime MOV brand.
    final mov = Uint8List(12);
    mov.setRange(4, 8, 'ftyp'.codeUnits);
    mov.setRange(8, 12, 'qt  '.codeUnits);
    expect(isMp4Container(mov), isFalse);
    expect(mp4MajorBrand(mov), 'qt  ');
    // Random bytes / truncated input.
    expect(isMp4Container(Uint8List.fromList([1, 2, 3])), isFalse);
    expect(() => demuxMp4(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FormatException>()));
  });
}
