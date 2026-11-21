import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/frame.dart';
import 'package:middle_out/core/constants.dart';
import 'package:middle_out/services/frame_inspector.dart';

List<Uint8List> encodeBlobs() {
  final random = Random(7);
  final data = Uint8List.fromList(
    List<int>.generate(200000, (_) => random.nextInt(256)),
  );
  final result = Encoder.encode(data, maxPayload: 16384);
  return [for (final frame in result.frames) frame.toBytes()];
}

void main() {
  group('FrameInspector', () {
    test('complete set inspects clean', () {
      final inspection = FrameInspector.inspect(encodeBlobs());
      expect(inspection.isComplete, isTrue);
      expect(inspection.recoverable, isTrue);
      expect(inspection.readableFrames, inspection.totalFrames);
      expect(inspection.hasDamage, isFalse);
    });

    test('one missing data frame is recoverable via parity', () {
      final blobs = encodeBlobs();
      blobs.removeAt(0); // first DATA frame
      final inspection = FrameInspector.inspect(blobs);
      expect(inspection.missingDataIndices, [0]);
      expect(inspection.recoverable, isTrue);
      expect(inspection.hasDamage, isTrue);
      expect(inspection.recoveredViaParity, [0]);
    });

    test('one corrupt payload is recoverable via parity', () {
      final blobs = encodeBlobs();
      final corrupt = Uint8List.fromList(blobs[1]);
      corrupt[kHeaderSize + 10] ^= 0xFF; // flip a payload byte
      blobs[1] = corrupt;
      final inspection = FrameInspector.inspect(blobs);
      expect(inspection.corruptDataIndices, [1]);
      expect(inspection.recoverable, isTrue);
      expect(inspection.recoveredViaParity, [1]);
    });

    test('two losses in one trio are unrecoverable, naming the trio', () {
      final blobs = encodeBlobs();
      blobs.removeAt(0);
      blobs.removeAt(0); // DATA frames 0 and 1 — same trio
      final inspection = FrameInspector.inspect(blobs);
      expect(inspection.recoverable, isFalse);
      expect(inspection.unrecoverableReason, contains('Group 1'));
      expect(inspection.unrecoverableReason, contains('[0, 1, 2]'));
    });

    test('no readable frames throws', () {
      expect(
        () => FrameInspector.inspect([Uint8List.fromList([1, 2, 3])]),
        throwsA(isA<CodecException>()),
      );
    });
  });
}
