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
}
