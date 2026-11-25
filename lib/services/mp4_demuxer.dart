/// Minimal MP4 demuxer for the Middle Out re-encoder (pure Dart, no
/// web dependency, so it is unit-testable on the VM).
///
/// Parses the `moov`/`stbl` tables of the `avc1` video track and the
/// `mp4a` audio track (when present) and returns the samples in decode
/// (file) order with presentation timestamps.
///
/// The `ctts` box is MANDATORY, not optional: real-world H.264 files
/// (including the Sintel fixture, where all 482 frames have
/// pts != dts) use B-frames, so decoding without it scrambles frame
/// order. The demuxer also refuses `co64` (64-bit chunk offsets) —
/// files that large never reach this path on the web, and the
/// re-encoder reports that honestly instead of misreading offsets.
///
/// Only 32-bit reads are used anywhere here (no 64-bit accessors),
/// so this file is safe under dart2js.
library;

import 'dart:typed_data';

/// One demuxed sample (one video frame or one AAC frame).
class Mp4Sample {
  /// Creates a demuxed sample.
  const Mp4Sample({
    required this.data,
    required this.timestampUs,
    required this.durationUs,
    required this.isKey,
  });

  /// The raw sample bytes (one Annex-B-free NAL unit set / AAC frame).
  final Uint8List data;

  /// Presentation timestamp, microseconds.
  final int timestampUs;

  /// Presentation duration, microseconds.
  final int durationUs;

  /// True for sync samples (video keyframes; always true for audio).
  final bool isKey;
}

/// A demuxed AAC audio track.
class DemuxedAudioTrack {
  /// Creates a demuxed audio track.
  const DemuxedAudioTrack({
    required this.samples,
    required this.asc,
    required this.sampleRate,
    required this.channels,
  });

  /// Audio samples in decode order.
  final List<Mp4Sample> samples;

  /// AudioSpecificConfig bytes (from the `esds` box), the
  /// `description` a decoder needs.
  final Uint8List asc;

  /// Sample rate in Hz (also the track timescale).
  final int sampleRate;

  /// Channel count.
  final int channels;

  /// Total duration in microseconds.
  int get durationUs => samples.isEmpty
      ? 0
      : samples.last.timestampUs + samples.last.durationUs;
}

/// A demuxed MP4: the video track plus the audio track when present.
class DemuxedMp4 {
  /// Creates a demuxed MP4.
  const DemuxedMp4({
    required this.samples,
    required this.avcC,
    required this.codec,
    required this.width,
    required this.height,
    required this.durationUs,
    required this.fps,
    this.audio,
  });

  /// Video samples in decode (file) order.
  final List<Mp4Sample> samples;

  /// The `avcC` extradata bytes (SPS/PPS), the `description` a
  /// decoder needs and the source of the derived codec string.
  final Uint8List avcC;

  /// Codec string derived FROM the [avcC] bytes (e.g. `avc1.640c1f`),
  /// never the string that was requested at encode time — the two
  /// can differ (the encoder's avcC says compatibility `0x0c` where
  /// the requested codec said `0x00`).
  final String codec;

  /// Coded video width in pixels.
  final int width;

  /// Coded video height in pixels.
  final int height;

  /// Total video duration in microseconds (last pts + last duration).
  final int durationUs;

  /// Average frame rate, derived from the `stts` durations.
  final double fps;

  /// The AAC audio track, when the file has one.
  final DemuxedAudioTrack? audio;
}

/// Derives the codec string from `avcC` bytes: `avc1.` + profile +
/// compatibility + level, each two lowercase hex digits.
String codecStringFromAvcC(Uint8List avcC) {
  if (avcC.length < 4) {
    throw const FormatException('avcC too short to derive a codec string');
  }
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  return 'avc1.${hex(avcC[1])}${hex(avcC[2])}${hex(avcC[3])}';
}

/// Major brands this demuxer accepts as MP4. `qt  ` (QuickTime MOV),
/// `M4V ` and friends are deliberately absent: the muxer writes
/// `isom`/`avc1`, and anything else is rejected upstream with the
/// plain "can't be re-encoded in the browser yet" message.
const Set<String> kMp4MajorBrands = {
  'isom',
  'iso2',
  'iso3',
  'iso4',
  'iso5',
  'iso6',
  'mp41',
  'mp42',
  'avc1',
  'dash',
  'msdh',
};

/// The `ftyp` major brand of [bytes], or null when the file has no
/// `ftyp` box (WebM/Matroska EBML, raw H.264, ...).
String? mp4MajorBrand(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[4] != 0x66 || // f
      bytes[5] != 0x74 || // t
      bytes[6] != 0x79 || // y
      bytes[7] != 0x70) {
    return null;
  }
  return String.fromCharCodes(bytes.sublist(8, 12));
}

/// True when [bytes] look like an MP4 this demuxer can read.
bool isMp4Container(Uint8List bytes) {
  final brand = mp4MajorBrand(bytes);
  return brand != null && kMp4MajorBrands.contains(brand);
}

/// One parsed box: [type] plus the payload span [start]..[end].
typedef _BoxSpan = ({String type, int start, int end});

Iterable<_BoxSpan> _childBoxes(Uint8List bytes, int start, int end) sync* {
  final bd = ByteData.sublistView(bytes);
  var pos = start;
  while (pos + 8 <= end) {
    final size = bd.getUint32(pos);
    if (size == 1) {
      throw const FormatException(
        '64-bit box sizes (largesize) are not supported',
      );
    }
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

/// Reads the variable-length descriptor length used inside `esds`
/// (base-128, high bit set on every byte but the last).
int _readDescriptorLength(Uint8List bytes, int offset, List<int> nextOut) {
  var length = 0;
  var pos = offset;
  while (pos < bytes.length) {
    final b = bytes[pos++];
    length = (length << 7) | (b & 0x7F);
    if ((b & 0x80) == 0) break;
  }
  nextOut[0] = pos;
  return length;
}

/// Extracts the AudioSpecificConfig from an `esds` payload (the box
/// payload, starting at the version/flags word).
Uint8List _ascFromEsds(Uint8List bytes, int start, int end) {
  var pos = start + 4; // skip version/flags
  if (pos >= end || bytes[pos] != 0x03) {
    throw const FormatException('esds has no ES_Descriptor');
  }
  pos++;
  final next = <int>[0];
  _readDescriptorLength(bytes, pos, next);
  pos = next[0] + 3; // ES_ID (2) + flags (1)
  if (pos >= end || bytes[pos] != 0x04) {
    throw const FormatException('esds has no DecoderConfigDescriptor');
  }
  pos++;
  _readDescriptorLength(bytes, pos, next);
  pos = next[0] + 13; // objectType + streamType + bufferSize + bitrates
  if (pos >= end || bytes[pos] != 0x05) {
    throw const FormatException('esds has no DecoderSpecificInfo');
  }
  pos++;
  final ascLen = _readDescriptorLength(bytes, pos, next);
  pos = next[0];
  if (pos + ascLen > end) {
    throw const FormatException('esds DecoderSpecificInfo is truncated');
  }
  return bytes.sublist(pos, pos + ascLen);
}

/// Reads a run-length table (`stts`/`ctts`/`stsc` style): a u32 count
/// followed by that many fixed-width entries.
List<(int, int)> _readRuns(
  ByteData bd,
  ({int start, int end}) box,
  int entryBytes,
) {
  final count = bd.getUint32(box.start + 4);
  final out = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    final o = box.start + 8 + i * entryBytes;
    out.add((bd.getUint32(o), bd.getUint32(o + 4)));
  }
  return out;
}

/// Demuxes [bytes] into video (+ audio) samples.
///
/// Throws [FormatException] with a plain reason when the file is not
/// a readable MP4 with an `avc1` video track, and [UnsupportedError]
/// for `co64` (64-bit chunk offsets).
DemuxedMp4 demuxMp4(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final moov = _findBox(bytes, 0, bytes.length, 'moov');
  if (moov == null) {
    throw const FormatException('no moov box — not a readable MP4 file');
  }
  List<Mp4Sample>? videoSamples;
  Uint8List? avcC;
  String? codec;
  var width = 0;
  var height = 0;
  var videoDurationUs = 0;
  var fps = 0.0;
  DemuxedAudioTrack? audio;

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
    final entry = stsd.start + 8;
    if (entry + 8 > bytes.length) continue;
    final entryType = String.fromCharCodes(bytes.sublist(entry + 4, entry + 8));
    if (entryType != 'avc1' && entryType != 'mp4a') continue;

    // mdhd timescale (version 0: +12, version 1: +20).
    final mdhdVersion = bytes[mdhd.start];
    final timescale = bd.getUint32(
      mdhd.start + (mdhdVersion == 1 ? 20 : 12),
    );
    if (timescale == 0) continue;

    final sttsBox = _findBox(bytes, stbl.start, stbl.end, 'stts');
    final stscBox = _findBox(bytes, stbl.start, stbl.end, 'stsc');
    final stszBox = _findBox(bytes, stbl.start, stbl.end, 'stsz');
    if (sttsBox == null || stscBox == null || stszBox == null) continue;
    if (_findBox(bytes, stbl.start, stbl.end, 'co64') != null) {
      throw UnsupportedError(
        '64-bit chunk offsets (co64) are not supported',
      );
    }
    final stcoBox = _findBox(bytes, stbl.start, stbl.end, 'stco');
    if (stcoBox == null) continue;

    final durations = <int>[];
    for (final (count, delta) in _readRuns(bd, sttsBox, 8)) {
      durations.addAll(List<int>.filled(count, delta));
    }
    final stsc = <(int, int)>[];
    {
      final count = bd.getUint32(stscBox.start + 4);
      for (var i = 0; i < count; i++) {
        final o = stscBox.start + 8 + i * 12;
        stsc.add((bd.getUint32(o), bd.getUint32(o + 4)));
      }
    }
    final stco = <int>[];
    {
      final count = bd.getUint32(stcoBox.start + 4);
      for (var i = 0; i < count; i++) {
        stco.add(bd.getUint32(stcoBox.start + 8 + i * 4));
      }
    }
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
    // Decode timestamps: running sum of stts durations.
    final dts = <int>[];
    var acc = 0;
    for (final d in durations) {
      dts.add(acc);
      acc += d;
    }

    if (entryType == 'avc1') {
      width = bd.getUint16(entry + 32);
      height = bd.getUint16(entry + 34);
      final entrySize = bd.getUint32(entry);
      final avcCBox = _findBox(bytes, entry + 86, entry + entrySize, 'avcC');
      if (avcCBox == null) {
        throw const FormatException('avc1 entry has no avcC box');
      }
      avcC = bytes.sublist(avcCBox.start, avcCBox.end);
      codec = codecStringFromAvcC(avcC);

      final cttsOffsets = <int>[];
      final cttsBox = _findBox(bytes, stbl.start, stbl.end, 'ctts');
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
      final keySet = <int>{};
      final stssBox = _findBox(bytes, stbl.start, stbl.end, 'stss');
      if (stssBox != null) {
        final count = bd.getUint32(stssBox.start + 4);
        for (var i = 0; i < count; i++) {
          keySet.add(bd.getUint32(stssBox.start + 8 + i * 4));
        }
      }
      videoSamples = _collectSamples(
        bytes,
        stco,
        stsc,
        sizes,
        durations,
        dts,
        cttsOffsets,
        timescale,
        keySet,
      );
      if (videoSamples.isNotEmpty) {
        final last = videoSamples.last;
        videoDurationUs = last.timestampUs + last.durationUs;
        fps = videoSamples.length * 1000000 / videoDurationUs;
      }
    } else {
      // mp4a: channels @ +24, sample rate (16.16) @ +32, esds @ +36.
      final channels = bd.getUint16(entry + 24);
      final sampleRate = bd.getUint32(entry + 32) >> 16;
      final entrySize = bd.getUint32(entry);
      final esdsBox = _findBox(bytes, entry + 36, entry + entrySize, 'esds');
      if (esdsBox == null) continue;
      final asc = _ascFromEsds(bytes, esdsBox.start, esdsBox.end);
      final audioSamples = _collectSamples(
        bytes,
        stco,
        stsc,
        sizes,
        durations,
        dts,
        const <int>[],
        timescale,
        null,
      );
      audio = DemuxedAudioTrack(
        samples: audioSamples,
        asc: asc,
        sampleRate: sampleRate,
        channels: channels,
      );
    }
  }

  if (videoSamples == null || avcC == null || codec == null) {
    throw const FormatException(
      'no avc1 video track found in this MP4 file',
    );
  }
  return DemuxedMp4(
    samples: videoSamples,
    avcC: avcC,
    codec: codec,
    width: width,
    height: height,
    durationUs: videoDurationUs,
    fps: fps,
    audio: audio,
  );
}

/// Walks `stco`/`stsc`/`stsz` and builds the sample list. [cttsOffsets]
/// is empty for audio (pts == dts); [keySet] is null for audio (every
/// sample is a sync sample).
List<Mp4Sample> _collectSamples(
  Uint8List bytes,
  List<int> stco,
  List<(int, int)> stsc,
  List<int> sizes,
  List<int> durations,
  List<int> dts,
  List<int> cttsOffsets,
  int timescale,
  Set<int>? keySet,
) {
  final samples = <Mp4Sample>[];
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
        Mp4Sample(
          data: data,
          timestampUs: (pts * 1000000 / timescale).round(),
          durationUs: (durations[sampleIndex] * 1000000 / timescale).round(),
          isKey: keySet == null || keySet.contains(sampleIndex + 1),
        ),
      );
      sampleIndex++;
    }
  }
  return samples;
}
