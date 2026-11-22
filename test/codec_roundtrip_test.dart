import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/chacha20.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/erasure.dart';
import 'package:middle_out/codec/frame.dart';
import 'package:middle_out/core/constants.dart';

Uint8List repeatedBytes(String text, int repeats) {
  final unit = Uint8List.fromList(utf8.encode(text));
  final out = BytesBuilder();
  for (var i = 0; i < repeats; i++) {
    out.add(unit);
  }
  return out.toBytes();
}

/// Serialises one frame in the legacy v1 wire format (97-byte header,
/// uint8 indices) so the decoder's v1 compatibility can be tested.
/// Encoders never write v1 — only this helper does.
Uint8List v1FrameBytes({
  required int frameIndex,
  required int kind,
  required int groupIndex,
  required int slot,
  required int flags,
  required int totalGroups,
  required int totalDataFrames,
  required int originalSize,
  required int compressedSize,
  required Uint8List sha256Bytes,
  required Uint8List payload,
}) {
  final header = ByteData(kHeaderSizeV1);
  header.setUint8(0, kFrameMagic[0]);
  header.setUint8(1, kFrameMagic[1]);
  header.setUint8(2, kFrameMagic[2]);
  header.setUint8(3, kFrameMagic[3]);
  header.setUint8(4, 1);
  header.setUint8(5, frameIndex);
  header.setUint8(6, kind);
  header.setUint8(7, groupIndex);
  header.setUint8(8, slot);
  header.setUint8(9, flags);
  header.setUint8(10, totalGroups);
  header.setUint16(11, totalDataFrames);
  header.setUint32(13, payload.length);
  header.setUint64(17, originalSize);
  header.setUint64(25, compressedSize);
  for (var i = 0; i < 32; i++) {
    header.setUint8(33 + i, sha256Bytes[i]);
  }
  final headerBytes = header.buffer.asUint8List(0, kHeaderSizeV1 - 4);
  header.setUint32(93, Crc32.checksum(headerBytes));
  final out = BytesBuilder()
    ..add(header.buffer.asUint8List())
    ..add(payload);
  final payloadCrc = ByteData(4)..setUint32(0, Crc32.checksum(payload));
  out.add(payloadCrc.buffer.asUint8List());
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

    test('v2 header round-trips indices above 255', () {
      final frame = Frame(
        frameIndex: 300,
        kind: kFrameKindData,
        groupIndex: 40,
        slot: 3,
        flags: kFlagEncrypted,
        totalGroups: 50,
        totalDataFrames: 300,
        originalSize: 123456789,
        compressedSize: 98765432,
        originalSha256: Uint8List(32),
        salt: Uint8List(16),
        nonce: Uint8List(12),
        payload: Uint8List(100),
      );
      final raw = frame.toBytes();
      expect(raw[4], kFrameVersion);
      expect(raw.length, kHeaderSize + 100 + 4);
      final parsed = Frame.fromBytes(raw);
      expect(parsed.frameIndex, 300);
      expect(parsed.groupIndex, 40);
      expect(parsed.totalGroups, 50);
      expect(parsed.totalDataFrames, 300);
      expect(parsed.originalSize, 123456789);
      expect(parsed.compressedSize, 98765432);
    });

    test('v1 frames still parse', () {
      final raw = v1FrameBytes(
        frameIndex: 200,
        kind: kFrameKindData,
        groupIndex: 30,
        slot: 2,
        flags: kFlagLastGroup,
        totalGroups: 40,
        totalDataFrames: 200,
        originalSize: 1234567,
        compressedSize: 765432,
        sha256Bytes: Uint8List(32),
        payload: Uint8List.fromList([1, 2, 3, 4]),
      );
      final parsed = Frame.fromBytes(raw);
      expect(parsed.frameIndex, 200);
      expect(parsed.groupIndex, 30);
      expect(parsed.totalGroups, 40);
      expect(parsed.totalDataFrames, 200);
      expect(parsed.originalSize, 1234567);
      expect(parsed.payload, [1, 2, 3, 4]);
    });

    test('v1 blobs decode (pre-v2 PDFs keep working)', () {
      final data = repeatedBytes('Middle Out v1 compat check. ', 40);
      final compressed = Uint8List.fromList(
        const ZLibEncoder().encode(data, level: 9),
      );
      final sha = Uint8List.fromList(sha256.convert(data).bytes);
      final parityA = Erasure.buildParity([compressed]);
      final parityB = Erasure.buildParity([]);
      final blobs = [
        v1FrameBytes(
          frameIndex: 0,
          kind: kFrameKindData,
          groupIndex: 0,
          slot: 0,
          flags: kFlagLastGroup,
          totalGroups: 1,
          totalDataFrames: 1,
          originalSize: data.length,
          compressedSize: compressed.length,
          sha256Bytes: sha,
          payload: compressed,
        ),
        v1FrameBytes(
          frameIndex: 1,
          kind: kFrameKindParity,
          groupIndex: 0,
          slot: kParityASlot,
          flags: kFlagLastGroup,
          totalGroups: 1,
          totalDataFrames: 1,
          originalSize: data.length,
          compressedSize: compressed.length,
          sha256Bytes: sha,
          payload: parityA,
        ),
        v1FrameBytes(
          frameIndex: 2,
          kind: kFrameKindParity,
          groupIndex: 0,
          slot: kParityBSlot,
          flags: kFlagLastGroup,
          totalGroups: 1,
          totalDataFrames: 1,
          originalSize: data.length,
          compressedSize: compressed.length,
          sha256Bytes: sha,
          payload: parityB,
        ),
      ];
      expect(Decoder.decode(blobs), data);
    });

    test('more than 256 frames round-trips (67 MB mp4 regression)', () {
      // 13 MiB of incompressible data needs ~279 frames at the default
      // 64 KiB payload — over the old 256 cap, under the 4096 cap.
      final random = Random(1234);
      final data = Uint8List(13 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      final result = Encoder.encode(data);
      expect(result.frames.length, greaterThan(256));
      expect(result.stats.frameCount, result.frames.length);
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('encode over the frame cap throws a clear error', () {
      final random = Random(99);
      final data = Uint8List(5 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      // A 1 KiB payload forces ~6,800 frames out of 5 MiB.
      expect(
        () => Encoder.encode(data, maxPayload: 1024),
        throwsA(
          isA<CodecException>().having(
            (e) => e.message,
            'message',
            allOf(contains('4096'), contains('Split')),
          ),
        ),
      );
    });
  });
}
