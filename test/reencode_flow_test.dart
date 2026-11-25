import 'dart:convert' show latin1;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/frame.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/codec/reencode.dart';
import 'package:middle_out/core/constants.dart';
import 'package:middle_out/services/frame_inspector.dart';
import 'package:middle_out/state/history_store.dart';

String _hex(Uint8List bytes) => sha256
    .convert(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

ReencodeRecord _record({
  required int originalSize,
  required String originalSha,
  required int reencodedSize,
  required String reencodedSha,
}) =>
    ReencodeRecord(
      originalName: 'clip.mp4',
      originalSizeBytes: originalSize,
      originalSha256Hex: originalSha,
      mediaKind: MediaKind.video,
      encoder: 'Fake encoder',
      settingsLabel: 'fake 640x360 @ 400 kbps',
      reencodedSizeBytes: reencodedSize,
      reencodedSha256Hex: reencodedSha,
      targetPdfBytes: 310555,
    );

void main() {
  group('Encoder re-encode flag', () {
    test('encode with a record sets kFlagReencoded on EVERY frame',
        () {
      final reencoded = Uint8List.fromList(
        List<int>.generate(1000, (i) => i % 251),
      );
      final record = _record(
        originalSize: 3105557,
        originalSha: _hex(Uint8List(3105557)),
        reencodedSize: reencoded.length,
        reencodedSha: _hex(reencoded),
      );
      final result = Encoder.encode(reencoded, reencode: record);
      expect(result.frames, isNotEmpty);
      for (final frame in result.frames) {
        expect(frame.flags & kFlagReencoded, kFlagReencoded);
        expect(frame.isReencoded, isTrue);
      }
      // The header SHA/size describe the RE-ENCODED bytes, so decode
      // verification still works on them — never the original.
      expect(result.stats.sha256Hex, _hex(reencoded));
      expect(result.stats.originalSize, reencoded.length);
      expect(result.stats.reencode, same(record));
    });

    test('encode without a record sets no flag, stats carry none', () {
      final data = Uint8List.fromList(
        List<int>.generate(1000, (i) => i % 251),
      );
      final result = Encoder.encode(data);
      for (final frame in result.frames) {
        expect(frame.flags & kFlagReencoded, 0);
        expect(frame.isReencoded, isFalse);
      }
      expect(result.stats.reencode, isNull);
      expect(result.stats.sha256Hex, _hex(data));
    });

    test('encodeAsync carries the record and the flag too', () async {
      final reencoded = Uint8List.fromList(
        List<int>.generate(500, (i) => i % 251),
      );
      final record = _record(
        originalSize: 3105557,
        originalSha: _hex(Uint8List(10)),
        reencodedSize: reencoded.length,
        reencodedSha: _hex(reencoded),
      );
      final result = await Encoder.encodeAsync(
        reencoded,
        reencode: record,
      );
      expect(
        result.frames.every((f) => f.isReencoded),
        isTrue,
      );
      expect(result.stats.reencode, same(record));
    });

    test('the flag survives a frame round-trip (toBytes/fromBytes)',
        () {
      final reencoded = Uint8List.fromList(
        List<int>.generate(500, (i) => i % 251),
      );
      final record = _record(
        originalSize: 3105557,
        originalSha: _hex(Uint8List(10)),
        reencodedSize: reencoded.length,
        reencodedSha: _hex(reencoded),
      );
      final result = Encoder.encode(reencoded, reencode: record);
      final parsed = [
        for (final f in result.frames) Frame.fromBytes(f.toBytes()),
      ];
      expect(parsed.every((f) => f.isReencoded), isTrue);
      expect(parsed.first.originalSha256, result.frames.first.originalSha256);
    });

    test('buildFrames reencoded flag is independent of the other flags',
        () {
      final sha = Uint8List(32);
      final frames = Encoder.buildFrames(
        chunks: [Uint8List.fromList([1, 2, 3])],
        sha256Bytes: sha,
        originalSize: 3,
        compressedSize: 3,
        salt: Uint8List(16),
        nonce: Uint8List(12),
        encrypted: true,
        barcode: true,
        equalSplit: true,
        reencoded: true,
      );
      expect(frames.first.isReencoded, isTrue);
      expect(frames.first.isEncrypted, isTrue);
      expect(frames.first.isBarcode, isTrue);
    });
  });

  group('FrameInspector isReencoded', () {
    test('re-encoded frames inspect as re-encoded', () {
      final reencoded = Uint8List.fromList(
        List<int>.generate(500, (i) => i % 251),
      );
      final record = _record(
        originalSize: 3105557,
        originalSha: _hex(Uint8List(10)),
        reencodedSize: reencoded.length,
        reencodedSha: _hex(reencoded),
      );
      final result = Encoder.encode(reencoded, reencode: record);
      final inspection = FrameInspector.inspect(
        [for (final f in result.frames) f.toBytes()],
      );
      expect(inspection.isReencoded, isTrue);
      // The inspector's expected hash is the RE-ENCODED hash.
      expect(inspection.expectedSha256Hex, _hex(reencoded));
    });

    test('plain frames inspect as not re-encoded', () {
      final data = Uint8List.fromList(
        List<int>.generate(500, (i) => i % 251),
      );
      final result = Encoder.encode(data);
      final inspection = FrameInspector.inspect(
        [for (final f in result.frames) f.toBytes()],
      );
      expect(inspection.isReencoded, isFalse);
    });
  });

  group('HistoryRecord re-encode JSON', () {
    HistoryRecord recordWithReencode() => HistoryRecord(
          id: 'r1',
          kind: HistoryKind.encode,
          fileName: 'clip.mp4',
          originalBytes: 3105557,
          encodedBytes: 142519,
          frameCount: 2,
          groupCount: 1,
          barcode: false,
          encrypted: true,
          sha256Hex: 'a' * 64,
          createdAt: DateTime.utc(2026, 11, 25, 12, 0, 0),
          reencode: _record(
            originalSize: 3105557,
            originalSha: 'a' * 64,
            reencodedSize: 142519,
            reencodedSha: 'b' * 64,
          ),
        );

    test('round-trips with the record (all fields, incl. mediaKind)',
        () {
      final record = recordWithReencode();
      final restored = HistoryRecord.fromJson(record.toJson());
      expect(restored.reencode, isNotNull);
      expect(restored.reencode!.originalName, 'clip.mp4');
      expect(restored.reencode!.originalSizeBytes, 3105557);
      expect(restored.reencode!.originalSha256Hex, 'a' * 64);
      expect(restored.reencode!.mediaKind, MediaKind.video);
      expect(restored.reencode!.encoder, 'Fake encoder');
      expect(
        restored.reencode!.settingsLabel,
        'fake 640x360 @ 400 kbps',
      );
      expect(restored.reencode!.reencodedSizeBytes, 142519);
      expect(restored.reencode!.reencodedSha256Hex, 'b' * 64);
      expect(restored.reencode!.targetPdfBytes, 310555);
      expect(restored.sha256Hex, 'a' * 64);
      expect(restored.originalBytes, 3105557);
    });

    test('records written before the field existed parse with null '
        '(old JSON has no reencode key)', () {
      final json = recordWithReencode().toJson()..remove('reencode');
      final restored = HistoryRecord.fromJson(json);
      expect(restored.reencode, isNull);
      expect(restored.fileName, 'clip.mp4');
    });

    test('records without a re-encode omit the field in JSON', () {
      final record = HistoryRecord(
        id: 'r2',
        kind: HistoryKind.encode,
        fileName: 'note.txt',
        originalBytes: 1000,
        encodedBytes: 100,
        frameCount: 2,
        groupCount: 1,
        barcode: false,
        encrypted: false,
        sha256Hex: 'c' * 64,
        createdAt: DateTime.utc(2026, 11, 25),
      );
      expect(record.toJson()['reencode'], isNull);
      expect(HistoryRecord.fromJson(record.toJson()).reencode, isNull);
    });

    test('copyWith preserves the record', () {
      final record = recordWithReencode();
      final bumped = record.copyWith(decodeCount: 3);
      expect(bumped.reencode, isNotNull);
      expect(bumped.decodeCount, 3);
      expect(bumped.reencode!.originalSha256Hex, 'a' * 64);
    });

    test('ReencodeRecord.fromJson tolerates a corrupt record', () {
      expect(ReencodeRecord.fromJson(null), isNull);
      expect(ReencodeRecord.fromJson({'mediaKind': 'video'}), isNull);
    });
  });

  group('PDF cover labels a re-encode plainly', () {
    // Cover content stream is object 7, FlateDecode — same helper as
    // pdf_document_test.dart.
    String coverOps(Uint8List pdf) {
      final text = latin1.decode(pdf);
      const number = 7;
      final header = text.indexOf('$number 0 obj');
      expect(header, greaterThanOrEqualTo(0));
      final streamAt = text.indexOf('stream\n', header);
      final endAt = text.indexOf('\nendstream', streamAt);
      final stream = Uint8List.sublistView(pdf, streamAt + 7, endAt);
      final inflated =
          Uint8List.fromList(const ZLibDecoder().decodeBytes(stream));
      return latin1.decode(inflated);
    }

    test('cover carries the re-encode lines; plain cover does not',
        () async {
      final reencoded = Uint8List.fromList(
        List<int>.generate(500, (i) => i % 251),
      );
      final record = _record(
        originalSize: 3105557,
        originalSha: _hex(Uint8List(10)),
        reencodedSize: reencoded.length,
        reencodedSha: _hex(reencoded),
      );
      final result = Encoder.encode(reencoded, reencode: record);
      final (pdfBytes, _) =
          await PdfDocument.build(result, 'clip.mp4');
      final ops = coverOps(pdfBytes);
      expect(ops, contains('Re-encoded to fit 10:1'));
      expect(
        ops,
        contains('lower-quality copy, not the original'),
      );
      expect(ops, contains('Re-encoded from'));
      // Parens are PDF-escaped in the content stream.
      expect(ops, contains(r'\(re-encoded\)'));

      final plain = Encoder.encode(reencoded);
      final (plainBytes, _) =
          await PdfDocument.build(plain, 'clip.mp4');
      expect(coverOps(plainBytes), isNot(contains('Re-encoded')));
    });
  });

  group('detectMediaKind', () {
    test('extension table + magic-byte fallback', () {
      expect(detectMediaKind('clip.mp4'), MediaKind.video);
      expect(detectMediaKind('shot.JPG'), MediaKind.image);
      expect(detectMediaKind('song.mp3'), MediaKind.audio);
      expect(detectMediaKind('data.zip'), MediaKind.other);
      expect(detectMediaKind('run.exe'), MediaKind.other);
      // No extension: ftyp magic still finds video.
      final mp4Head = Uint8List(12)..[4] = 0x66;
      mp4Head[5] = 0x74;
      mp4Head[6] = 0x79;
      mp4Head[7] = 0x70;
      expect(detectMediaKind('file', mp4Head), MediaKind.video);
      // Random bytes, no extension: other.
      final random = Random(1);
      final noise = Uint8List.fromList(
        List<int>.generate(64, (_) => random.nextInt(256)),
      );
      expect(detectMediaKind('file', noise), MediaKind.other);
    });
  });
}
