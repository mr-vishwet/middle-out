import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/streaming_encoder_io.dart';

Future<File> writeTempFile(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('middleout-test-');
  final file = File('${dir.path}/input.bin');
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  group('StreamingEncoder', () {
    test('is supported on the test VM', () {
      expect(StreamingEncoder.isSupported, isTrue);
    });

    test('plain round-trip through the decoder', () async {
      final data = Uint8List.fromList(
        List<int>.generate(300000, (i) => (i * 7 + i ~/ 997) % 256),
      );
      final file = await writeTempFile(data);
      try {
        final progress = <double>[];
        final result = await StreamingEncoder.encodeFile(
          path: file.path,
          onProgress: (fraction, _) => progress.add(fraction),
        );
        expect(result.stats.originalSize, data.length);
        expect(progress, isNotEmpty);
        expect(progress.last, greaterThanOrEqualTo(0.9));
        expect(
          Decoder.decode(
            [for (final frame in result.frames) frame.toBytes()],
          ),
          data,
        );
      } finally {
        await file.parent.delete(recursive: true);
      }
    });

    test('encrypted round-trip; wrong passphrase fails', () async {
      final data = Uint8List.fromList(
        'Streaming encrypted fixture. '.codeUnits,
      );
      final repeated = BytesBuilder();
      for (var i = 0; i < 2000; i++) {
        repeated.add(data);
      }
      final bytes = repeated.toBytes();
      final file = await writeTempFile(bytes);
      try {
        final result = await StreamingEncoder.encodeFile(
          path: file.path,
          passphrase: 'streaming passphrase',
        );
        final blobs = [
          for (final frame in result.frames) frame.toBytes(),
        ];
        expect(
          Decoder.decode(blobs, passphrase: 'streaming passphrase'),
          bytes,
        );
        expect(
          () => Decoder.decode(blobs, passphrase: 'wrong passphrase'),
          throwsA(isA<Exception>()),
        );
      } finally {
        await file.parent.delete(recursive: true);
      }
    });

    test('empty file encodes and decodes', () async {
      final file = await writeTempFile([]);
      try {
        final result = await StreamingEncoder.encodeFile(path: file.path);
        expect(
          Decoder.decode(
            [for (final frame in result.frames) frame.toBytes()],
          ),
          Uint8List(0),
        );
      } finally {
        await file.parent.delete(recursive: true);
      }
    });
  });
}
