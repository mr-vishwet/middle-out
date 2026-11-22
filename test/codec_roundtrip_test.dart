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
  writeUint64BE(header, 17, originalSize);
  writeUint64BE(header, 25, compressedSize);
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
      // Highly compressible sample -> 1 DATA + 1 PARITY = 2 frames
      // (the second trio is empty, so no second parity is emitted).
      expect(result.frames.length, 2);
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
      // zlib of nothing is 8 bytes: 1 data frame + its parity.
      expect(result.frames.length, 2);
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
      // 13 MiB of incompressible data in FIXED 64 KiB chunks needs
      // ~278 frames — over the old 256 cap, under the 4096 cap. Fixed
      // chunks come from buildFrames directly now (the in-memory path
      // equal-splits into at most 20 data frames); the streaming path
      // still frames this way, and the v2 uint16 indices must hold.
      final random = Random(1234);
      final data = Uint8List(13 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }
      final compressed = Uint8List.fromList(
        const ZLibEncoder().encode(data, level: 9),
      );
      final chunks = <Uint8List>[];
      for (var i = 0; i < compressed.length; i += kDefaultMaxPayload) {
        final end = min(i + kDefaultMaxPayload, compressed.length);
        chunks.add(Uint8List.sublistView(compressed, i, end));
      }
      final frames = Encoder.buildFrames(
        chunks: chunks,
        sha256Bytes: Uint8List.fromList(sha256.convert(data).bytes),
        originalSize: data.length,
        compressedSize: compressed.length,
        salt: Uint8List(kSaltLength),
        nonce: Uint8List(kNonceLength),
        encrypted: false,
        barcode: false,
      );
      expect(frames.length, greaterThan(256));
      // No equal-split flag on fixed-chunk frames: the decoder takes
      // the old derivation path for them.
      expect(
        frames.every((f) => f.flags & kFlagEqualSplit == 0),
        isTrue,
      );
      expect(
        Decoder.decode([for (final f in frames) f.toBytes()]),
        data,
      );
    });

    test('encode over the frame cap throws a clear error', () {
      // 5,000 fixed chunks need ~6,668 frames — over the 4,096 cap.
      // buildFrames checks the cap before framing, so empty chunks
      // exercise it cheaply.
      expect(
        () => Encoder.buildFrames(
          chunks: List<Uint8List>.filled(5000, Uint8List(0)),
          sha256Bytes: Uint8List(32),
          originalSize: 0,
          compressedSize: 0,
          salt: Uint8List(16),
          nonce: Uint8List(12),
          encrypted: false,
          barcode: false,
        ),
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

  group('equal-split encode', () {
    test('200 KiB random payload splits into 4 dense data pages', () {
      final random = Random(7);
      final data = Uint8List.fromList(
        List<int>.generate(200 * 1024, (_) => random.nextInt(256)),
      );
      final result = Encoder.encode(data);
      final dataFrames = [
        for (final f in result.frames)
          if (f.isData) f,
      ];
      expect(dataFrames.length, 4);
      // All four carry the full chunk size — no sparse last page. The
      // last chunk is zero-padded to chunkSize; the decoder trims the
      // padding (the round-trip below proves it).
      final chunkSize = (result.stats.compressedSize + 3) ~/ 4;
      for (final frame in dataFrames) {
        expect(frame.payload.length, chunkSize);
      }
      // Every frame carries the equal-split flag.
      for (final frame in result.frames) {
        expect(frame.flags & kFlagEqualSplit, kFlagEqualSplit);
      }
      // 4 data in one group: both trios non-empty, so both parities exist.
      expect(result.frames.length, 6);
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('small file: 1 data + 1 parity, no second parity', () {
      final data = repeatedBytes('Middle Out small file. ', 10);
      final result = Encoder.encode(data);
      expect(result.frames.length, 2);
      expect(
        result.frames.where((f) => f.isData).length,
        1,
      );
      expect(
        result.frames.where((f) => f.isParity).length,
        1,
      );
      expect(
        result.frames.any((f) => f.slot == kParityBSlot),
        isFalse,
      );
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('buildFrames with no chunks: 1 empty data frame, no parity', () {
      // The empty-input edge: no empty parity frame is emitted (an
      // empty parity would render as a near-blank code page).
      final frames = Encoder.buildFrames(
        chunks: <Uint8List>[],
        sha256Bytes: Uint8List(32),
        originalSize: 0,
        compressedSize: 0,
        salt: Uint8List(16),
        nonce: Uint8List(12),
        encrypted: false,
        barcode: false,
      );
      expect(frames.length, 1);
      expect(frames.first.isData, isTrue);
      expect(frames.first.payload.length, 0);
    });

    test('5 MB single frame round-trips (equal split, one page)', () {
      // A 5 MB payload with a large unit splits into ONE ~5 MB frame —
      // the big-frame shape the grid cap sizes for.
      final random = Random(11);
      final data = Uint8List.fromList(
        List<int>.generate(5 * 1024 * 1024, (_) => random.nextInt(256)),
      );
      final result = Encoder.encode(data, maxPayload: 8 * 1024 * 1024);
      expect(
        result.frames.where((f) => f.isData).length,
        1,
      );
      expect(
        result.frames.first.payload.length,
        greaterThan(5 * 1024 * 1024),
      );
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });

    test('20 data pages max, however large the file', () {
      // 2 MiB of random data would need 32 fixed chunks — equal-split
      // caps it at 20 dense data frames.
      final random = Random(13);
      final data = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024, (_) => random.nextInt(256)),
      );
      final result = Encoder.encode(data);
      expect(
        result.frames.where((f) => f.isData).length,
        20,
      );
      expect(result.stats.groupCount, 4);
      // 3 full groups (2 parities each) + a 2-data group (1 parity).
      expect(result.frames.length, 27);
      expect(
        Decoder.decode([for (final f in result.frames) f.toBytes()]),
        data,
      );
    });
  });

  // ByteData.getUint64/setUint64 throw UnsupportedError under dart2js
  // (JS numbers cannot hold 64-bit ints) — a real web encode of a
  // 67 MB file hit exactly that. The codec now uses writeUint64BE /
  // readUint64BE (byte loops) instead. VM tests cannot catch
  // dart2js-only failures, so these tests assert the byte layout
  // itself, including values above 2^32 where a 32-bit shortcut
  // would silently corrupt the size fields.
  group('uint64 header fields (dart2js-safe)', () {
    test('writeUint64BE produces exact big-endian bytes', () {
      final cases = <int, List<int>>{
        0: [0, 0, 0, 0, 0, 0, 0, 0],
        255: [0, 0, 0, 0, 0, 0, 0, 255],
        // Distinct byte pattern, verifiable by eye.
        0x0001020304050607: [0, 1, 2, 3, 4, 5, 6, 7],
        0x0011223344556677: [0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77],
        // Realistic multi-GB file sizes (above 2^32).
        5368709120: [0, 0, 0, 1, 0x40, 0, 0, 0], // 5 GiB
        107374182400: [0, 0, 0, 0x19, 0, 0, 0, 0], // 100 GiB
        // Largest exactly-representable int on the web (2^53 - 1).
        9007199254740991: [0, 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
      };
      for (final entry in cases.entries) {
        final data = ByteData(8);
        writeUint64BE(data, 0, entry.key);
        expect(
          data.buffer.asUint8List(),
          entry.value,
          reason: 'value ${entry.key}',
        );
      }
    });

    test('readUint64BE round-trips through writeUint64BE', () {
      const values = [
        0,
        1,
        255,
        256,
        4294967295, // 2^32 - 1
        4294967296, // 2^32
        5368709120, // 5 GiB
        1099511627776, // 1 TiB
        9007199254740991, // 2^53 - 1
      ];
      for (final value in values) {
        final data = ByteData(8);
        writeUint64BE(data, 0, value);
        expect(readUint64BE(data, 0), value);
      }
    });

    test('v2 frame round-trips multi-GB sizes', () {
      final frame = Frame(
        frameIndex: 1,
        kind: kFrameKindData,
        groupIndex: 0,
        slot: 0,
        flags: 0,
        totalGroups: 1,
        totalDataFrames: 1,
        originalSize: 1099511627776, // 1 TiB
        compressedSize: 5368709120, // 5 GiB
        originalSha256: Uint8List(32),
        salt: Uint8List(16),
        nonce: Uint8List(12),
        payload: Uint8List(10),
      );
      final raw = frame.toBytes();
      // The wire layout is unchanged: originalSize at bytes 20..27,
      // compressedSize at 28..35, big-endian.
      expect(raw.sublist(20, 28), [0, 0, 1, 0, 0, 0, 0, 0]);
      expect(raw.sublist(28, 36), [0, 0, 0, 1, 0x40, 0, 0, 0]);
      final parsed = Frame.fromBytes(raw);
      expect(parsed.originalSize, 1099511627776);
      expect(parsed.compressedSize, 5368709120);
    });

    test('v1 frame round-trips multi-GB sizes', () {
      final raw = v1FrameBytes(
        frameIndex: 1,
        kind: kFrameKindData,
        groupIndex: 0,
        slot: 0,
        flags: 0,
        totalGroups: 1,
        totalDataFrames: 1,
        originalSize: 1099511627776, // 1 TiB
        compressedSize: 5368709120, // 5 GiB
        sha256Bytes: Uint8List(32),
        payload: Uint8List.fromList([9, 8, 7]),
      );
      // v1 offsets: originalSize at bytes 17..24, compressedSize 25..32.
      expect(raw.sublist(17, 25), [0, 0, 1, 0, 0, 0, 0, 0]);
      expect(raw.sublist(25, 33), [0, 0, 0, 1, 0x40, 0, 0, 0]);
      final parsed = Frame.fromBytes(raw);
      expect(parsed.originalSize, 1099511627776);
      expect(parsed.compressedSize, 5368709120);
      expect(parsed.payload, [9, 8, 7]);
    });
  });
}
