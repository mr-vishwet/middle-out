import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/pdf_document.dart';
import 'package:middle_out/services/pdf_frame_extractor.dart';

/// Incompressible bytes: 200 KiB of seeded random data encodes to 4 data
/// frames (64 KiB payload each) + 2 parity = 8 frames, enough to observe
/// per-frame progress.
Uint8List randomBytes(int length) {
  final random = Random(42);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
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

      // One callback per frame plus the final 'Saving PDF…' call.
      expect(fractions.length, encoded.frames.length + 1);
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }
      expect(fractions.first, greaterThan(0));
      expect(fractions.last, 1.0);
      expect(
        labels.every((label) => label.contains('PDF')),
        isTrue,
        reason: 'the frames are already built — the label must say PDF',
      );
      expect(labels.first, contains('page 2 of'));
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
      // The cover's manifest grid is not a frame — it must be skipped.
      expect(extraction.frames.length, encoded.frames.length);
      final decoded = Decoder.decode(extraction.frames);
      expect(decoded, data);
    });
  });
}
