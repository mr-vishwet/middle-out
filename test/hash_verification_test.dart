import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/frame.dart';

import 'codec_roundtrip_test.dart' show repeatedBytes;

void main() {
  test('wrong passphrase fails verification', () {
    final data = repeatedBytes('secret payload ', 20);
    final result = Encoder.encode(data, passphrase: 'right-passphrase');
    final blobs = [for (final f in result.frames) f.toBytes()];
    expect(
      () => Decoder.decode(blobs, passphrase: 'wrong-passphrase'),
      throwsA(isA<VerificationException>()),
    );
  });

  test('missing passphrase fails verification', () {
    final data = repeatedBytes('secret payload ', 20);
    final result = Encoder.encode(data, passphrase: 'secret');
    final blobs = [for (final f in result.frames) f.toBytes()];
    expect(
      () => Decoder.decode(blobs),
      throwsA(isA<VerificationException>()),
    );
  });

  test('header-corrupt frame is dropped and rebuilt from parity', () {
    final data = repeatedBytes('tamper check ', 5);
    final blobs = [
      for (final f in Encoder.encode(data).frames) Uint8List.fromList(f.toBytes()),
    ];
    blobs[0][20] ^= 0xFF; // inside the header -> header CRC fails
    expect(Decoder.decode(blobs), data);
  });

  test('no frames fails', () {
    expect(
      () => Decoder.decode([]),
      throwsA(isA<UnrecoverableException>()),
    );
  });

  test('empty input to decode fails', () {
    expect(
      () => Decoder.decode([Uint8List(0)]),
      throwsA(isA<UnrecoverableException>()),
    );
  });
}
