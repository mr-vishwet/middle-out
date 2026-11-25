import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/ratio_engine.dart';
import 'package:middle_out/codec/reencode.dart';
import 'package:middle_out/state/encode_controller.dart';

void main() {
  group('RatioEngine.decide — the three paths', () {
    test('plain text that beats 10:1 losslessly takes the lossless path '
        '(no re-encode offered, even for video)', () {
      // 1.02 MB of text at 142x (the old README-x461 size — a
      // synthetic text case; the live README has since grown):
      // lossless PDF ~22 KB.
      final plan = RatioEngine.analyse(
        fileSize: 1023420,
        sampledRatio: 142.28,
        kind: MediaKind.other,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.lossless);
      expect(plan.losslessPdfBytes, 21964);
      expect(plan.reencodeTargetMediaBytes, isNull);
      expect(plan.deadEndReason, isNull);
      // Same numbers for a video file that happens to compress well:
      // the kind never forces a re-encode when lossless already fits.
      expect(
        RatioEngine.decide(
          fileSize: 1023420,
          sampledRatio: 142.28,
          kind: MediaKind.video,
          losslessOnly: false,
        ),
        RatioDecision.lossless,
      );
    });

    test('3.1 MB clip that misses 10:1 proposes a re-encode with a '
        'model-checked budget', () {
      // The Sintel fixture: 3,105,557 B, sampled ratio ~1.0.
      final plan = RatioEngine.analyse(
        fileSize: 3105557,
        sampledRatio: 1.0,
        kind: MediaKind.video,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.reencode);
      // CORRECTED from the brief's flat "~230-235 KB": a 1-data-page
      // encode carries the whole stream TWICE (1 data + 1 parity
      // frame), so the PDF is ~2.13x the media, not 1.333x — the flat
      // input/13.3 = 233,501 B models to a 493,642 B PDF, far over the
      // 310,555 B target. The real budget is ~142.5 KB. Pinned exact:
      expect(plan.reencodeTargetMediaBytes, 142519);
      expect(plan.reencodeTargetPdfBytes, 303084);
      expect(plan.targetPdfBytes, 310555);
      expect(plan.reencodeTargetPdfBytes, lessThanOrEqualTo(310555));
      // The lossless number is the honest one: ~6.5 MB, 2.08x the file.
      expect(plan.losslessPdfBytes, 6453260);
    });

    test('the flat input/13.3 budget does NOT fit the 3.1 MB clip', () {
      // The spike test's media budget (input / 13.3 = 233,501 B) was
      // never checked against a real PDF build. The model says its
      // PDF is 493,642 B — 59% over the 310,555 B target. This test
      // pins that failure so nobody re-adopts the flat factor.
      expect(
        RatioEngine.modelledPdfBytes(compressedSize: 233501),
        493642,
      );
      expect(493642, greaterThan(310555));
    });

    test('20 MiB random data is a dead end (not re-encodable media)', () {
      final plan = RatioEngine.analyse(
        fileSize: 20971520,
        sampledRatio: 1.0,
        kind: MediaKind.other,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.deadEnd);
      expect(plan.reencodeTargetMediaBytes, isNull);
      expect(
        plan.deadEndReason,
        contains('Only video and still images'),
      );
    });

    test('20 MiB random VIDEO can re-encode (kind is what matters)', () {
      // Same bytes, video kind: the solver finds ~978 KB of media.
      final plan = RatioEngine.analyse(
        fileSize: 20971520,
        sampledRatio: 1.0,
        kind: MediaKind.video,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.reencode);
      expect(plan.reencodeTargetMediaBytes, 978219);
      expect(plan.reencodeTargetPdfBytes, 2037262);
      expect(plan.reencodeTargetPdfBytes, lessThanOrEqualTo(2097152));
    });

    test('dead ends: zip, exe, audio', () {
      for (final kind in [MediaKind.other, MediaKind.audio]) {
        final plan = RatioEngine.analyse(
          fileSize: 5000000,
          sampledRatio: 1.0,
          kind: kind,
          losslessOnly: false,
        );
        expect(plan.decision, RatioDecision.deadEnd,
            reason: 'kind $kind must be a dead end');
        expect(plan.reencodeTargetMediaBytes, isNull);
      }
      // Audio gets its own reason (never the reason to build an
      // audio encoder).
      expect(
        RatioEngine.analyse(
          fileSize: 5000000,
          sampledRatio: 1.0,
          kind: MediaKind.audio,
          losslessOnly: false,
        ).deadEndReason,
        contains('Audio is not re-encoded'),
      );
      // A zip that compresses 2x still misses 10:1 and is a dead end.
      expect(
        RatioEngine.analyse(
          fileSize: 5000000,
          sampledRatio: 2.0,
          kind: MediaKind.other,
          losslessOnly: false,
        ).decision,
        RatioDecision.deadEnd,
      );
    });

    test('lossless-only mode turns a re-encodable file into a dead end',
        () {
      final plan = RatioEngine.analyse(
        fileSize: 3105557,
        sampledRatio: 1.0,
        kind: MediaKind.video,
        losslessOnly: true,
      );
      expect(plan.decision, RatioDecision.deadEnd);
      expect(plan.deadEndReason, contains('Lossless-only is on'));
      // ...but a file that fits losslessly still encodes.
      expect(
        RatioEngine.analyse(
          fileSize: 1023420,
          sampledRatio: 142.28,
          kind: MediaKind.video,
          losslessOnly: true,
        ).decision,
        RatioDecision.lossless,
      );
    });

    test('a 5 MB image proposes a re-encode', () {
      final plan = RatioEngine.analyse(
        fileSize: 5000000,
        sampledRatio: 1.05,
        kind: MediaKind.image,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.reencode);
      expect(plan.reencodeTargetMediaBytes, 230827);
      expect(plan.reencodeTargetPdfBytes, 485700);
      expect(plan.reencodeTargetPdfBytes, lessThanOrEqualTo(500000));
    });

    test('a tiny file is a dead end: the fixed PDF cost alone breaks '
        '10:1', () {
      // 10 KB file, target 1,000 B; the fixed document cost plus two
      // code pages is ~6,400 B. No media size can fit.
      final plan = RatioEngine.analyse(
        fileSize: 10000,
        sampledRatio: 1.0,
        kind: MediaKind.video,
        losslessOnly: false,
      );
      expect(plan.decision, RatioDecision.deadEnd);
      expect(
        plan.deadEndReason,
        contains('PDF alone is bigger than a tenth'),
      );
      expect(
        RatioEngine.reencodeTargetMediaBytes(fileSize: 10000),
        isNull,
      );
    });

    test('empty file is a dead end, not a crash', () {
      expect(
        RatioEngine.analyse(
          fileSize: 0,
          sampledRatio: 1.0,
          kind: MediaKind.video,
          losslessOnly: false,
        ).decision,
        RatioDecision.deadEnd,
      );
    });
  });

  group('RatioEngine budget math', () {
    test('parity factor is not flat: 1 page ~2.08x, 2 pages ~1.56x, '
        'full groups ~1.39x', () {
      // 1 data page (media < 5 MiB): 2 frames carry the whole stream.
      // (1 MB, not 100 KB: at 100 KB the ~6 KB fixed cost skews the
      // ratio by 0.06.)
      final onePage = RatioEngine.modelledPdfBytes(compressedSize: 1000000);
      expect(onePage / 1000000, closeTo(2.08, 0.05));
      // 2 data pages (media 20 MiB — the rule rounds sqrt(4) to 2):
      // 3 frames carry half each. The measured real build is 1.503x;
      // the model over-states by ~3%, so ~1.56x.
      final twoPages =
          RatioEngine.modelledPdfBytes(compressedSize: 20971520);
      expect(twoPages / 20971520, closeTo(1.56, 0.05));
      // 6 data pages (~200 MB — sqrt(38) rounds to 6): 8 frames
      // carry a sixth each.
      final sixPages =
          RatioEngine.modelledPdfBytes(compressedSize: 200000000);
      expect(sixPages / 200000000, closeTo(1.39, 0.05));
    });

    test('a 100 KB file is a dead end: the smallest meaningful '
        're-encode still breaks 10:1', () {
      // Target 10,000 B; even 4 KB of media (the solver's floor —
      // below that the output is mush, not a re-encode) models to a
      // ~14.5 KB PDF. The solver returns null instead of a
      // token-sized target.
      expect(
        RatioEngine.reencodeTargetMediaBytes(fileSize: 100000),
        isNull,
      );
      expect(
        RatioEngine.analyse(
          fileSize: 100000,
          sampledRatio: 1.0,
          kind: MediaKind.video,
          losslessOnly: false,
        ).decision,
        RatioDecision.deadEnd,
      );
    });

    test('budget solver never returns a media size whose modeled PDF '
        'exceeds the target', () {
      for (final size in [
        200000,
        1000000,
        3105557,
        5000000,
        20971520,
        100000000,
        1073741824,
      ]) {
        final media = RatioEngine.reencodeTargetMediaBytes(fileSize: size);
        expect(media, isNotNull, reason: 'size $size must have a budget');
        final pdf = RatioEngine.modelledPdfBytes(compressedSize: media!);
        expect(pdf, lessThanOrEqualTo(size ~/ 10),
            reason: 'size $size media $media models to $pdf');
        // And the margin holds: within 98% of the target.
        expect(pdf, lessThanOrEqualTo((size ~/ 10 * 0.98).floor() + 1),
            reason: 'size $size media $media models to $pdf');
      }
    });

    test('modelledPdfBytes agrees with EncodeController.estimateFor '
        '(the two models must never drift)', () {
      // Same inputs, both paths (in-memory + streaming), a spread of
      // sizes and ratios: the ratio engine replicates _estimatePdfBytes
      // exactly, so the numbers must be identical, not just close.
      for (final (size, ratio) in [
        (1023420, 142.28),
        (3105557, 1.0),
        (2097152, 1.0),
        (20971520, 1.0),
        (100000000, 1.27),
        (1040000000, 73.0),
      ]) {
        for (final streaming in [false, true]) {
          final estimate = EncodeController.estimateFor(
            fileSize: size,
            ratio: ratio,
            sampleBytes: 768 * 1024,
            streaming: streaming,
          );
          final estCompressed = (size / ratio.clamp(1.0, 1000.0)).ceil();
          final modelled = RatioEngine.modelledPdfBytes(
            compressedSize: estCompressed,
            streaming: streaming,
          );
          expect(
            modelled,
            estimate.estimatedPdfBytes,
            reason: 'size $size ratio $ratio streaming $streaming',
          );
        }
      }
      // Plain payloads (second-pass squeeze) agree too.
      final plain = EncodeController.estimateFor(
        fileSize: 1023420,
        ratio: 142.28,
        sampleBytes: 768 * 1024,
        encrypted: false,
        secondPassFactor: 0.472,
      );
      expect(
        RatioEngine.modelledPdfBytes(
          compressedSize: (1023420 / 142.28).ceil(),
          encrypted: false,
          secondPassFactor: 0.472,
        ),
        plain.estimatedPdfBytes,
      );
    });
  });

  group('EncodeController.estimateFor carries the decision', () {
    test('3.1 MB video estimate proposes a re-encode with both numbers',
        () {
      final estimate = EncodeController.estimateFor(
        fileSize: 3105557,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
        mediaKind: MediaKind.video,
      );
      expect(estimate.decision, RatioDecision.reencode);
      expect(estimate.losslessPdfBytes, estimate.estimatedPdfBytes);
      expect(estimate.losslessPdfBytes, 6453260);
      expect(estimate.reencodeTargetPdfBytes, 303084);
      expect(estimate.reencodeTargetMediaBytes, 142519);
      expect(estimate.deadEndReason, isNull);
    });

    test('20 MiB random estimate is a dead end with a reason', () {
      final estimate = EncodeController.estimateFor(
        fileSize: 20971520,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
        mediaKind: MediaKind.other,
      );
      expect(estimate.decision, RatioDecision.deadEnd);
      expect(estimate.deadEndReason, contains('Only video'));
      expect(estimate.reencodeTargetPdfBytes, isNull);
    });

    test('lossless-only flips a video estimate to dead end', () {
      final estimate = EncodeController.estimateFor(
        fileSize: 3105557,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
        mediaKind: MediaKind.video,
        losslessOnly: true,
      );
      expect(estimate.decision, RatioDecision.deadEnd);
      expect(estimate.deadEndReason, contains('Lossless-only'));
    });

    test('default kind (other) keeps old callers lossless-or-dead-end '
        'only', () {
      // estimateFor defaults mediaKind to other: a compressible file
      // is lossless, an incompressible one is a dead end — never a
      // surprise re-encode for callers that do not detect the kind.
      expect(
        EncodeController.estimateFor(
          fileSize: 1023420,
          ratio: 142.28,
          sampleBytes: 768 * 1024,
        ).decision,
        RatioDecision.lossless,
      );
      expect(
        EncodeController.estimateFor(
          fileSize: 3105557,
          ratio: 1.0,
          sampleBytes: 768 * 1024,
        ).decision,
        RatioDecision.deadEnd,
      );
    });
  });
}
