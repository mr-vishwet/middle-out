/// Minimal MP4 muxer for the Middle Out re-encoder (pure Dart, no web
/// dependency, so it is unit-testable on the VM).
///
/// Writes `ftyp` + `moov` + a single `mdat` chunk: all video samples
/// first, then all audio samples (when an audio track is present).
/// The video track uses timescale 24000 (24 fps x 1000, so a 41.667 ms
/// frame is exactly 1000 units — timescale 1000 would round every
/// frame to 42 ms and drift +160 ms over a 20 s clip); the audio
/// track uses its sample rate as its timescale.
///
/// Two spike bugs are avoided here by construction: `stsc` says all
/// samples live in ONE chunk (not one sample per chunk), and the codec
/// string is always derived from the `avcC` bytes, never reused from
/// the string that was requested at encode time.
///
/// Only 32-bit writes are used anywhere here (no 64-bit accessors),
/// so this file is safe under dart2js.
library;

import 'dart:typed_data';

import 'mp4_demuxer.dart';

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

Uint8List _versionedBox(String type, void Function(BytesBuilder) body) {
  final b = BytesBuilder();
  _u32(b, 0); // version(0) + flags(0)
  body(b);
  return _box(type, b.takeBytes());
}

/// Like [_versionedBox] but with an explicit version byte. `ctts`
/// uses version 1: its offsets are SIGNED (a B-frame's pts can be
/// before its dts, so version 0's unsigned offsets corrupt it — a
/// -1000 offset read back as 4294966296 shifts the frame by ~49 h).
Uint8List _versionedBoxV(String type, int version, void Function(BytesBuilder) body) {
  final b = BytesBuilder();
  _u32(b, version << 24);
  body(b);
  return _box(type, b.takeBytes());
}

/// Groups consecutive equal values into (count, value) runs, for
/// `stts`/`ctts` tables.
List<(int, int)> _runs(List<int> values) {
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

/// Writes one MPEG-4 descriptor (tag + base-128 length + payload).
void _descriptor(BytesBuilder b, int tag, Uint8List payload) {
  b.add([tag]);
  // Base-128 length, high bit set on every byte but the last.
  final lenBytes = <int>[];
  var len = payload.length;
  lenBytes.add(len & 0x7F);
  len >>= 7;
  while (len > 0) {
    lenBytes.add((len & 0x7F) | 0x80);
    len >>= 7;
  }
  b.add(lenBytes.reversed.toList());
  b.add(payload);
}

/// Builds an `esds` box payload from AudioSpecificConfig bytes and
/// the audio bitrate the encoder ran at.
Uint8List _esdsBox(Uint8List asc, int bitrate) {
  final configPayload = BytesBuilder();
  configPayload.add([0x40, 0x15]); // AAC, audio stream
  configPayload.add([0, 0, 0]); // bufferSizeDB
  _u32(configPayload, bitrate); // maxBitrate
  _u32(configPayload, bitrate); // avgBitrate
  _descriptor(configPayload, 0x05, asc); // DecoderSpecificInfo
  final configBytes = configPayload.takeBytes();

  final esPayload = BytesBuilder();
  esPayload.add([0, 0]); // ES_ID
  esPayload.add([0]); // flags
  _descriptor(esPayload, 0x04, configBytes); // DecoderConfigDescriptor
  _descriptor(esPayload, 0x06, Uint8List.fromList([0x02])); // SLConfig
  final esBytes = esPayload.takeBytes();

  final body = BytesBuilder();
  _u32(body, 0); // version + flags
  _descriptor(body, 0x03, esBytes); // ES_Descriptor
  return _box('esds', body.takeBytes());
}

/// Muxes encoder output into a playable MP4.
///
/// [videoSamples] are in encoder-output (decode) order with
/// presentation timestamps; when they are not monotonic in that order
/// a `ctts` box is emitted. [avcC] comes from the encoder's
/// `decoderConfig.description`. [audio] (when present) is muxed as a
/// second track after the video chunk in the same `mdat`.
Uint8List muxMp4({
  required List<Mp4Sample> videoSamples,
  required Uint8List avcC,
  required int width,
  required int height,
  DemuxedAudioTrack? audio,
  int audioBitrate = 16000,
}) {
  const videoTimescale = 24000;
  final n = videoSamples.length;
  if (n == 0) {
    throw const FormatException('cannot mux an MP4 with no video samples');
  }
  // Per-sample presentation time + duration in timescale units.
  final ptsTs = List<int>.generate(
    n,
    (i) => (videoSamples[i].timestampUs * videoTimescale / 1000000).round(),
  );
  final durTs = List<int>.generate(n, (i) {
    var d =
        (videoSamples[i].durationUs * videoTimescale / 1000000).round();
    if (d < 1) d = 1;
    return d;
  });
  // Decode timestamps: running sum of durations in file order.
  final dtsTs = List<int>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dtsTs[i] = dtsTs[i - 1] + durTs[i - 1];
  }
  final totalVideoTs = dtsTs.last + durTs.last;
  final cttsOffsets = List<int>.generate(n, (i) => ptsTs[i] - dtsTs[i]);
  final needsCtts = cttsOffsets.any((o) => o != 0);

  // ---- audio timing (timescale = sample rate).
  final audioSamples = audio?.samples ?? const <Mp4Sample>[];
  final audioTimescale = audio?.sampleRate ?? 0;
  final audioDurTs = <int>[];
  var totalAudioTs = 0;
  if (audio != null && audioSamples.isNotEmpty) {
    for (final s in audioSamples) {
      var d = (s.durationUs * audioTimescale / 1000000).round();
      if (d < 1) d = 1;
      audioDurTs.add(d);
      totalAudioTs += d;
    }
  }
  // mvhd timescale 1000; duration is the SUM of durations (the dts
  // span), matching the spike's proven construction — NOT max
  // pts+duration, which would read 20.25 s for this clip (the first
  // frame's pts starts 83 ms in and the B-reorder tail runs past
  // the span). The sum gives 20.083 s, exactly what <video> reports
  // for the spike's muxed file.
  final totalMvhd = ((totalVideoTs * 1000 / videoTimescale).round())
      .clamp(0, 1 << 31);
  final totalMvhdAudio = audio == null || audioSamples.isEmpty
      ? 0
      : (totalAudioTs * 1000 / audioTimescale).round();
  final mvhdDuration =
      totalMvhdAudio > totalMvhd ? totalMvhdAudio : totalMvhd;

  final videoBytes = videoSamples.fold(0, (s, c) => s + c.data.length);

  // ---- ftyp.
  final ftypBody = BytesBuilder();
  ftypBody.add('isom'.codeUnits);
  _u32(ftypBody, 512);
  for (final brand in ['isom', 'iso2', 'avc1', 'mp41']) {
    ftypBody.add(brand.codeUnits);
  }
  final ftyp = _box('ftyp', ftypBody.takeBytes());

  // ---- mvhd / tkhd / mdhd / hdlr / vmhd|smhd / dinf (shared pieces).
  final mvhd = _versionedBox('mvhd', (b) {
    _u32(b, 0); // creation_time
    _u32(b, 0); // modification_time
    _u32(b, 1000); // timescale
    _u32(b, mvhdDuration); // duration
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
    _u32(b, audio == null ? 2 : 3); // next_track_ID
  });

  Uint8List tkhd(int trackId, int durationMvhd, int w, int h, int volume) {
    final b = BytesBuilder();
    _u32(b, 0x00000007); // version 0, flags: enabled|in_movie|in_preview
    _u32(b, 0);
    _u32(b, 0);
    _u32(b, trackId);
    _u32(b, 0); // reserved
    _u32(b, durationMvhd);
    _u32(b, 0);
    _u32(b, 0); // reserved
    _u16(b, 0); // layer
    _u16(b, 0); // alternate_group
    _u16(b, volume);
    _u16(b, 0); // reserved
    for (final m in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
      _u32(b, m);
    }
    _u32(b, w << 16);
    _u32(b, h << 16);
    return _box('tkhd', b.takeBytes());
  }

  Uint8List mdhd(int timescale, int duration) => _versionedBox('mdhd', (b) {
        _u32(b, 0);
        _u32(b, 0);
        _u32(b, timescale);
        _u32(b, duration);
        _u16(b, 0x55c7); // language 'und'
        _u16(b, 0);
      });

  Uint8List hdlr(String handler, String name) => _versionedBox('hdlr', (b) {
        _u32(b, 0); // pre_defined
        b.add(handler.codeUnits);
        _u32(b, 0);
        _u32(b, 0);
        _u32(b, 0);
        b.add(name.codeUnits);
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

  final smhd = _versionedBox('smhd', (b) {
    _u16(b, 0); // balance
    _u16(b, 0); // reserved
  });

  final dinf = _box(
    'dinf',
    _versionedBox('dref', (b) {
      _u32(b, 1); // entry_count
      b.add(_box('url ', Uint8List.fromList([0, 0, 0, 1])));
    }),
  );

  // ---- video stbl.
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
    b.add(_box('avcC', avcC));
    return _box('avc1', b.takeBytes());
  })();
  final videoStsd = _versionedBox('stsd', (b) {
    _u32(b, 1); // entry_count
    b.add(avc1Entry);
  });
  final videoStts = _versionedBox('stts', (b) {
    final r = _runs(durTs);
    _u32(b, r.length);
    for (final (count, delta) in r) {
      _u32(b, count);
      _u32(b, delta);
    }
  });
  final videoStss = _versionedBox('stss', (b) {
    final keys = <int>[];
    for (var i = 0; i < n; i++) {
      if (videoSamples[i].isKey) keys.add(i + 1); // 1-based
    }
    _u32(b, keys.length);
    for (final k in keys) {
      _u32(b, k);
    }
  });
  Uint8List? videoCtts;
  if (needsCtts) {
    // Version 1: signed offsets (a B-frame's pts can precede its dts).
    videoCtts = _versionedBoxV('ctts', 1, (b) {
      final r = _runs(cttsOffsets);
      _u32(b, r.length);
      for (final (count, offset) in r) {
        _u32(b, count);
        _u32(b, offset);
      }
    });
  }
  final videoStsc = _versionedBox('stsc', (b) {
    _u32(b, 1);
    _u32(b, 1); // first_chunk
    _u32(b, n); // samples_per_chunk: ALL samples in the one mdat chunk
    _u32(b, 1); // sample_description_index
  });
  final videoStsz = _versionedBox('stsz', (b) {
    _u32(b, 0); // sample_size (0 = sizes follow)
    _u32(b, n);
    for (final s in videoSamples) {
      _u32(b, s.data.length);
    }
  });
  Uint8List videoStcoWith(int offset) => _versionedBox('stco', (b) {
        _u32(b, 1);
        _u32(b, offset);
      });

  Uint8List buildVideoStbl(int chunkOffset) {
    final body = BytesBuilder()
      ..add(videoStsd)
      ..add(videoStts)
      ..add(videoStss);
    if (videoCtts != null) body.add(videoCtts);
    body
      ..add(videoStsc)
      ..add(videoStsz)
      ..add(videoStcoWith(chunkOffset));
    return _box('stbl', body.takeBytes());
  }

  // ---- audio stbl (when present).
  Uint8List? buildAudioStbl(int chunkOffset) {
    if (audio == null || audioSamples.isEmpty) return null;
    final mp4aEntry = (() {
      final b = BytesBuilder();
      b.add(List<int>.filled(6, 0));
      _u16(b, 1); // data_reference_index
      b.add(List<int>.filled(8, 0)); // reserved
      _u16(b, audio.channels);
      _u16(b, 16); // sample size
      _u16(b, 0); // pre_defined
      _u16(b, 0); // reserved
      _u32(b, audio.sampleRate << 16); // sample rate, 16.16 fixed
      b.add(_esdsBox(audio.asc, audioBitrate));
      return _box('mp4a', b.takeBytes());
    })();
    final stsd = _versionedBox('stsd', (b) {
      _u32(b, 1);
      b.add(mp4aEntry);
    });
    final stts = _versionedBox('stts', (b) {
      final r = _runs(audioDurTs);
      _u32(b, r.length);
      for (final (count, delta) in r) {
        _u32(b, count);
        _u32(b, delta);
      }
    });
    final stsc = _versionedBox('stsc', (b) {
      _u32(b, 1);
      _u32(b, 1);
      _u32(b, audioSamples.length); // all samples in the one chunk
      _u32(b, 1);
    });
    final stsz = _versionedBox('stsz', (b) {
      _u32(b, 0);
      _u32(b, audioSamples.length);
      for (final s in audioSamples) {
        _u32(b, s.data.length);
      }
    });
    final stco = _versionedBox('stco', (b) {
      _u32(b, 1);
      _u32(b, chunkOffset);
    });
    final body = BytesBuilder()
      ..add(stsd)
      ..add(stts)
      ..add(stsc)
      ..add(stsz)
      ..add(stco);
    return _box('stbl', body.takeBytes());
  }

  Uint8List buildMoov(int videoChunkOffset, int audioChunkOffset) {
    final videoMinf = _box(
      'minf',
      (BytesBuilder()
            ..add(vmhd)
            ..add(dinf)
            ..add(buildVideoStbl(videoChunkOffset)))
          .takeBytes(),
    );
    final videoMdia = _box(
      'mdia',
      (BytesBuilder()
            ..add(mdhd(videoTimescale, totalVideoTs))
            ..add(hdlr('vide', 'VideoHandler'))
            ..add(videoMinf))
          .takeBytes(),
    );
    final videoTrak = _box(
      'trak',
      (BytesBuilder()
            ..add(tkhd(1, mvhdDuration, width, height, 0))
            ..add(videoMdia))
          .takeBytes(),
    );
    final trakBody = BytesBuilder()..add(videoTrak);
    if (audio != null && audioSamples.isNotEmpty) {
      final audioStbl = buildAudioStbl(audioChunkOffset)!;
      final audioMinf = _box(
        'minf',
        (BytesBuilder()
              ..add(smhd)
              ..add(dinf)
              ..add(audioStbl))
            .takeBytes(),
      );
      final audioMdia = _box(
        'mdia',
        (BytesBuilder()
              ..add(mdhd(audioTimescale, totalAudioTs))
              ..add(hdlr('soun', 'SoundHandler'))
              ..add(audioMinf))
            .takeBytes(),
      );
      final audioTrak = _box(
        'trak',
        (BytesBuilder()
              ..add(tkhd(2, mvhdDuration, 0, 0, 0x0100))
              ..add(audioMdia))
            .takeBytes(),
      );
      trakBody.add(audioTrak);
    }
    return _box(
      'moov',
      (BytesBuilder()
            ..add(mvhd)
            ..add(trakBody.takeBytes()))
          .takeBytes(),
    );
  }

  // First pass with offset 0 to learn moov's size (it is offset-
  // independent), then rebuild with the true chunk offsets.
  final moovProbe = buildMoov(0, 0);
  final mdatStart = ftyp.length + moovProbe.length + 8;
  final videoChunkOffset = mdatStart;
  final audioChunkOffset = mdatStart + videoBytes;
  final moov = buildMoov(videoChunkOffset, audioChunkOffset);
  assert(moov.length == moovProbe.length, 'moov size must be stable');

  final mdatBody = BytesBuilder();
  for (final s in videoSamples) {
    mdatBody.add(s.data);
  }
  for (final s in audioSamples) {
    mdatBody.add(s.data);
  }
  final mdat = _box('mdat', mdatBody.takeBytes());
  final out = BytesBuilder()
    ..add(ftyp)
    ..add(moov)
    ..add(mdat);
  return out.takeBytes();
}
