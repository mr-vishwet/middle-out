import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/services/pdf_frame_extractor.dart';

/// Incompressible bytes: 200 KiB of seeded random data encodes to 4 equal
/// data frames + 2 parity = 6 frames, enough to observe per-frame progress.
Uint8List randomBytes(int length) {
  final random = Random(42);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Extracts object [number]'s stream bytes (between 'stream\n' and
/// '\nendstream') and inflates them (content streams are FlateDecode).
Uint8List inflateObjectStream(Uint8List pdf, int number) {
  final text = latin1.decode(pdf);
  final header = text.indexOf('$number 0 obj');
  expect(header, greaterThanOrEqualTo(0), reason: 'object $number missing');
  final streamAt = text.indexOf('stream\n', header);
  final endAt = text.indexOf('\nendstream', streamAt);
  final stream = Uint8List.sublistView(pdf, streamAt + 7, endAt);
  return Uint8List.fromList(const ZLibDecoder().decodeBytes(stream));
}

void main() {
  group('PdfDocument.build progress', () {
    test('reports increasing progress per frame and yields', () async {
      final data = randomBytes(200 * 1024);
      final encoded = Encoder.encode(data);
      expect(encoded.frames.length, greaterThan(1));

      final fractions = <double>[];
      final labels = <String>[];
      // Scheduled before the build: it can only run if the build yields
      // to the event loop (a synchronous loop would starve it until the
      // build returns, after the last callback).
      var eventLoopRan = false;
      Future<void>.delayed(Duration.zero).then((_) {
        eventLoopRan = true;
      });
      var sawYield = false;

      final (pdf, stats) = await PdfDocument.build(
        encoded,
        'progress.bin',
        onProgress: (fraction, label) {
          fractions.add(fraction);
          labels.add(label);
          if (eventLoopRan) sawYield = true;
        },
      );

      // One callback per frame (phase 1) plus the two phase-2 callbacks
      // ('Binding into PDF…' at 0.95 and at 1.0).
      final frames = encoded.frames.length;
      expect(fractions.length, frames + 2);
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }
      expect(fractions.first, greaterThan(0));
      expect(fractions.last, 1.0);
      // Phase 1 labels: 'Creating images… N of M'.
      for (var i = 0; i < frames; i++) {
        expect(labels[i], 'Creating images… ${i + 1} of $frames');
      }
      // Phase 2 labels: 'Binding into PDF…'.
      expect(labels[frames], 'Binding into PDF…');
      expect(labels[frames + 1], 'Binding into PDF…');
      expect(fractions[frames], 0.95);
      expect(sawYield, isTrue, reason: 'the build must yield per frame');
      expect(stats.pages, 1 + encoded.frames.length);
      expect(pdf.length, stats.sizeBytes);
    });

    test('stops promptly when shouldCancel is set', () async {
      final data = randomBytes(200 * 1024);
      final encoded = Encoder.encode(data);
      var calls = 0;
      await expectLater(
        PdfDocument.build(
          encoded,
          'cancel.bin',
          onProgress: (fraction, label) => calls++,
          shouldCancel: () => calls >= 2,
        ),
        throwsA(isA<BuildCancelledException>()),
      );
      expect(calls, 2);
      expect(calls, lessThan(encoded.frames.length));
    });

    test('built PDF still decodes back to the original bytes', () async {
      final data = randomBytes(200 * 1024);
      final encoded = Encoder.encode(data);
      final (pdf, _) = await PdfDocument.build(encoded, 'roundtrip.bin');
      final extraction = PdfFrameExtractor.extract(pdf);
      // The cover's QR is not a frame — it must be skipped.
      expect(extraction.frames.length, encoded.frames.length);
      final decoded = Decoder.decode(extraction.frames);
      expect(decoded, data);
    });
  });

  group('PdfDocument.build cover', () {
    test('cover carries details + QR, no secrets', () async {
      final data = randomBytes(200 * 1024);
      final encoded = Encoder.encode(data);
      final (pdf, _) = await PdfDocument.build(encoded, 'cover-check.bin');
      final text = latin1.decode(pdf);
      // The cover QR image: 29 modules + 4 quiet each side = 37x37.
      expect(text.contains('/Width 37 /Height 37'), isTrue);
      // Cover content stream is object 7 (5 logo, 6 cover page).
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      expect(ops.contains('(MIDDLE OUT)'), isTrue);
      expect(ops.contains('(File: cover-check.bin)'), isTrue);
      expect(ops.contains('(Original size:'), isTrue);
      expect(ops.contains('(Format: QR-style grid)'), isTrue);
      expect(ops.contains('(Theme: Light)'), isTrue);
      expect(ops.contains('(Pages: 7)'), isTrue);
      expect(ops.contains('(Scan to open the Middle Out app.)'), isTrue);
      // No secrets on the cover.
      expect(ops.contains('SHA-256'), isFalse);
      expect(ops.contains('Encoded payload'), isFalse);
      expect(ops.contains('Ratio'), isFalse);
      expect(ops.contains('Frames:'), isFalse);
    });

    test('dark PDF cover stays light', () async {
      final data = randomBytes(100 * 1024);
      final encoded = Encoder.encode(data);
      final (pdf, _) = await PdfDocument.build(
        encoded,
        'dark-cover.bin',
        dark: true,
      );
      final ops = latin1.decode(inflateObjectStream(pdf, 7));
      expect(ops.contains('re f'), isFalse);
      expect(ops.contains('(Theme: Dark)'), isTrue);
      expect(ops.contains('(MIDDLE OUT)'), isTrue);
    });
  });
}
