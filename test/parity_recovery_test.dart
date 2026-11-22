import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/frame.dart';
import 'package:middle_out/core/constants.dart';

void main() {
  (Uint8List, EncodeResult) multiFrameEncode() {
    // Random (incompressible) data sized to compress into exactly 6 data
    // frames: one full group = 6 DATA + 2 PARITY = 8 frames. The -64
    // leaves room for zlib's stored-block overhead so no 7th frame appears.
    final random = Random(99);
    final data = Uint8List.fromList(
      List<int>.generate(6 * 1024 - 64, (_) => random.nextInt(256)),
    );
    final result = Encoder.encode(data, maxPayload: 1024);
    expect(result.stats.frameCount, 8);
    expect(result.frames.first.totalDataFrames, 6);
    return (data, result);
  }

  List<Uint8List> blobsOf(EncodeResult result) =>
      [for (final f in result.frames) f.toBytes()];

  test('lose one data frame per trio', () {
    final (data, result) = multiFrameEncode();
    final blobs = blobsOf(result);
    // Drop data frame 1 (trio A) and data frame 4 (trio B).
    final kept = [for (var i = 0; i < blobs.length; i++) if (i != 1 && i != 4) blobs[i]];
    expect(Decoder.decode(kept), data);
  });

  test('lose the last frame', () {
    final (data, result) = multiFrameEncode();
    final blobs = blobsOf(result);
    final kept = blobs.sublist(0, 5) + blobs.sublist(6);
    expect(Decoder.decode(kept), data);
  });

  test('lose the first frame', () {
    final (data, result) = multiFrameEncode();
    final blobs = blobsOf(result);
    expect(Decoder.decode(blobs.sublist(1)), data);
  });

  test('corrupt payload recovers via parity', () {
    final (data, result) = multiFrameEncode();
    final blobs = blobsOf(result).map(Uint8List.fromList).toList();
    blobs[2][kHeaderSize + 10] ^= 0xFF; // flip a payload byte -> CRC fails
    expect(Decoder.decode(blobs), data);
  });

  test('lose two in one trio fails', () {
    final (_, result) = multiFrameEncode();
    final blobs = blobsOf(result);
    final kept = [for (var i = 0; i < blobs.length; i++) if (i != 0 && i != 2) blobs[i]];
    expect(() => Decoder.decode(kept), throwsA(isA<UnrecoverableException>()));
  });

  test('lose data frame and its parity fails', () {
    final (_, result) = multiFrameEncode();
    final blobs = blobsOf(result);
    final kept = [for (var i = 0; i < blobs.length; i++) if (i != 0 && i != 6) blobs[i]];
    expect(() => Decoder.decode(kept), throwsA(isA<UnrecoverableException>()));
  });

  test('lose parity frames only is fine', () {
    final (data, result) = multiFrameEncode();
    final blobs = [
      for (final f in result.frames)
        if (f.isData) f.toBytes(),
    ];
    expect(blobs.length, 6);
    expect(Decoder.decode(blobs), data);
  });

  test('1-data group: lose the only data frame, parity rebuilds it', () {
    // Small file: 1 data + 1 parity, no second parity (empty trio).
    final data = Uint8List.fromList(
      'Middle Out one-frame group. '.codeUnits,
    );
    final result = Encoder.encode(data);
    expect(result.frames.length, 2);
    expect(
      result.frames.any((f) => f.slot == kParityBSlot),
      isFalse,
    );
    // Drop the data frame — only the parity remains.
    final parityOnly = [
      for (final f in result.frames)
        if (f.isParity) f.toBytes(),
    ];
    expect(Decoder.decode(parityOnly), data);
  });

  test('1-data group: lose the only parity frame is fine', () {
    final data = Uint8List.fromList(
      'Middle Out one-frame group, parity lost. '.codeUnits,
    );
    final result = Encoder.encode(data);
    expect(result.frames.length, 2);
    // Drop the parity frame — the data frame alone decodes. The
    // decoder's missing-parity path is never hit: the empty trio has
    // nothing missing, so it continues.
    final dataOnly = [
      for (final f in result.frames)
        if (f.isData) f.toBytes(),
    ];
    expect(Decoder.decode(dataOnly), data);
  });

  test('equal-split: lose a middle frame, parity rebuilds it', () {
    // 200 KiB random -> 4 dense data frames + 2 parity. Losing data
    // frame 1 (trio A) must rebuild to the exact chunk size.
    final random = Random(7);
    final data = Uint8List.fromList(
      List<int>.generate(200 * 1024, (_) => random.nextInt(256)),
    );
    final result = Encoder.encode(data);
    expect(result.frames.where((f) => f.isData).length, 4);
    final blobs = blobsOf(result);
    // Frame list order is group order: data frames first.
    final kept = [
      for (var i = 0; i < blobs.length; i++)
        if (i != 1) blobs[i],
    ];
    expect(Decoder.decode(kept), data);
  });
}
