import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/chacha20.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/core/constants.dart';

Uint8List repeatedBytes(String text, int repeats) {
  final unit = Uint8List.fromList(utf8.encode(text));
  final out = BytesBuilder();
  for (var i = 0; i < repeats; i++) {
    out.add(unit);
  }
  return out.toBytes();
}

void main() {
  group('ChaCha20', () {
    test('RFC 8439 section A.5 vector (cross-checked against OpenSSL)', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final nonce = Uint8List.fromList(
        [0, 0, 0, 0x09, 0, 0, 0, 0x4A, 0, 0, 0, 0],
      );
      final plaintext = Uint8List.fromList(
        "Ladies and Gentlemen of the class of '99: If I could offer you "
        "only one tip for the future, sunscreen would be it.".codeUnits,
      );
      final ciphertext = ChaCha20.xor(key, nonce, plaintext, counter: 1);
      expect(
        ciphertext.sublist(0, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '5c90838db44879743e6bfd58c64e05a8',
      );
      expect(ChaCha20.xor(key, nonce, ciphertext, counter: 1), plaintext);
    });

    test('round-trip at arbitrary lengths', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final nonce = Uint8List(12)..[3] = 7;
      final random = Random(42);
      for (final length in [0, 1, 63, 64, 65, 1000]) {
        final data =
            Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
        final enc = ChaCha20.xor(key, nonce, data);
        expect(ChaCha20.xor(key, nonce, enc), data);
        if (length > 0) expect(enc, isNot(data));
      }
    });
  });

  group('encode/decode round-trip', () {
    test('plain round-trip, one group', () {
      final data = repeatedBytes(
        'Middle Out encodes this file into visual frames. ',
        200,
      );
      final result = Encoder.encode(data);
      // Highly compressible sample -> 1 DATA + 2 PARITY = 3 frames.
      expect(result.frames.length, 3);
      expect(result.stats.groupCount, 1);
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('encrypted round-trip; payload not human-readable', () {
      final data = repeatedBytes('Middle Out encodes this file. ', 50);
      final result = Encoder.encode(data, passphrase: 'correct horse battery staple');
      final blobs = [for (final f in result.frames) f.toBytes()];
      expect(Decoder.decode(blobs, passphrase: 'correct horse battery staple'), data);
      final joined = BytesBuilder();
      for (final blob in blobs) {
        joined.add(blob);
      }
      expect(
        String.fromCharCodes(joined.toBytes()).contains('Middle Out encodes'),
        isFalse,
      );
    });

    test('empty file', () {
      final result = Encoder.encode(Uint8List(0));
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        Uint8List(0),
      );
    });

    test('random data, multiple groups', () {
      final random = Random(7);
      final data = Uint8List.fromList(
        List<int>.generate(200000, (_) => random.nextInt(256)),
      );
      final result = Encoder.encode(data, maxPayload: 16384);
      expect(result.stats.groupCount, greaterThan(1));
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('frame header fields', () {
      final data = repeatedBytes('header check ', 100);
      final frame = Encoder.encode(data).frames.first;
      expect(frame.originalSize, data.length);
      expect(frame.totalGroups, 1);
      expect(frame.totalDataFrames, 1);
      expect(
        frame.toBytes().length,
        kHeaderSize + frame.payload.length + 4,
      );
    });
  });
}
