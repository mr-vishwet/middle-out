import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/core/constants.dart';
import 'package:middle_out/services/platform_limits.dart';
import 'package:middle_out/state/encode_controller.dart';

void main() {
  group('platform limits', () {
    test('limit values match the V7 spec', () {
      expect(PlatformLimits.nativeMaxBytes, 100 * 1024 * 1024 * 1024);
      expect(PlatformLimits.webLocalMaxBytes, 10 * 1024 * 1024 * 1024);
      expect(PlatformLimits.webCloudMaxBytes, 50 * 1024 * 1024 * 1024);
    });

    test('fits() enforces each mode', () {
      expect(PlatformLimitsService.fits(5 * 1024 * 1024 * 1024, EncodeMode.webLocal), isTrue);
      expect(PlatformLimitsService.fits(11 * 1024 * 1024 * 1024, EncodeMode.webLocal), isFalse);
      expect(PlatformLimitsService.fits(11 * 1024 * 1024 * 1024, EncodeMode.webCloud), isTrue);
      expect(PlatformLimitsService.fits(60 * 1024 * 1024 * 1024, EncodeMode.webCloud), isFalse);
      expect(PlatformLimitsService.fits(60 * 1024 * 1024 * 1024, EncodeMode.native), isTrue);
    });

    test('smallestModeFor routes over-limit files', () {
      expect(
        PlatformLimitsService.smallestModeFor(5 * 1024 * 1024 * 1024),
        EncodeMode.webLocal,
      );
      expect(
        PlatformLimitsService.smallestModeFor(20 * 1024 * 1024 * 1024),
        EncodeMode.webCloud,
      );
      expect(
        PlatformLimitsService.smallestModeFor(80 * 1024 * 1024 * 1024),
        EncodeMode.native,
      );
      expect(
        PlatformLimitsService.smallestModeFor(200 * 1024 * 1024 * 1024),
        isNull,
      );
    });

    test('overLimitAdvice names the target mode', () {
      final advice = PlatformLimitsService.overLimitAdvice(
        20 * 1024 * 1024 * 1024,
        EncodeMode.webLocal,
      );
      expect(advice, contains('Web · Cloud'));
      // 50 GiB in the app's decimal formatting (50 * 1024^3 bytes).
      expect(advice, contains('53.7 GB'));
    });

    test('over 100 GB has no route', () {
      final advice = PlatformLimitsService.overLimitAdvice(
        200 * 1024 * 1024 * 1024,
        EncodeMode.native,
      );
      expect(advice, contains('split it'));
    });
  });

  group('PDF size band', () {
    test('in-band PDF produces no warning', () {
      expect(
        PlatformLimitsService.pdfBandWarning(1024 * 1024 * 1024, 14 * 1024 * 1024),
        isNull,
      );
    });

    test('over-band PDF warns', () {
      final warning = PlatformLimitsService.pdfBandWarning(
        1024 * 1024 * 1024,
        200 * 1024 * 1024,
      );
      expect(warning, isNotNull);
      expect(warning, contains('above the'));
    });
  });

  group('memory guard', () {
    // estimateMemoryPeak is pure: these tests drive it directly with
    // explicit frame plans, so they do not depend on the adaptive page
    // rule. chunkSize 1024 keeps the grid trivial; the peak is then
    // dominated by the held bytes the test sets.
    test('small files are ok on every platform', () {
      const small = 20 * 1024 * 1024;
      final desktop = EncodeController.estimateMemoryPeak(
        fileSize: small,
        estCompressed: small,
        dataFrames: 2,
        parityFrames: 1,
        chunkSize: 1024,
        estimatedPdfBytes: 30 * 1024 * 1024,
        streaming: false,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: false,
      );
      expect(desktop.level, MemoryGuardLevel.ok);
      final web = EncodeController.estimateMemoryPeak(
        fileSize: small,
        estCompressed: small,
        dataFrames: 2,
        parityFrames: 1,
        chunkSize: 1024,
        estimatedPdfBytes: 30 * 1024 * 1024,
        streaming: false,
        barcode: false,
        web: true,
        mobile: false,
        streamingBinding: false,
      );
      expect(web.level, MemoryGuardLevel.ok);
    });

    test('desktop warns above 1 GiB, web refuses above 1 GiB', () {
      // Peak ~1.2 GiB: 600 MB stream held + 240 MB parity + ~126 MB
      // transient page + 850 MB of held PDF images (two-phase).
      // Streaming, so no input file is held.
      final desktop = EncodeController.estimateMemoryPeak(
        fileSize: 600 * 1024 * 1024,
        estCompressed: 600 * 1024 * 1024,
        dataFrames: 10,
        parityFrames: 4,
        chunkSize: 60 * 1024 * 1024,
        estimatedPdfBytes: 850 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: false,
      );
      expect(desktop.level, MemoryGuardLevel.warn);
      expect(desktop.reason, contains('Tap Encode again'));
      final web = EncodeController.estimateMemoryPeak(
        fileSize: 600 * 1024 * 1024,
        estCompressed: 600 * 1024 * 1024,
        dataFrames: 10,
        parityFrames: 4,
        chunkSize: 60 * 1024 * 1024,
        estimatedPdfBytes: 850 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: true,
        mobile: false,
        streamingBinding: false,
      );
      expect(web.level, MemoryGuardLevel.refuse);
      expect(web.reason, contains('Split the file'));
    });

    test('desktop refuses above 2 GiB', () {
      final guard = EncodeController.estimateMemoryPeak(
        fileSize: 0,
        estCompressed: 0,
        dataFrames: 1,
        parityFrames: 0,
        chunkSize: 1024,
        estimatedPdfBytes: 3 * 1024 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: false,
      );
      expect(guard.level, MemoryGuardLevel.refuse);
    });

    test('web warns above 512 MiB where desktop is ok', () {
      // Peak ~576 MB: 550 MB of held PDF images + small extras.
      final web = EncodeController.estimateMemoryPeak(
        fileSize: 100 * 1024 * 1024,
        estCompressed: 100 * 1024 * 1024,
        dataFrames: 2,
        parityFrames: 1,
        chunkSize: 1024,
        estimatedPdfBytes: 550 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: true,
        mobile: false,
        streamingBinding: false,
      );
      expect(web.level, MemoryGuardLevel.warn);
      final desktop = EncodeController.estimateMemoryPeak(
        fileSize: 100 * 1024 * 1024,
        estCompressed: 100 * 1024 * 1024,
        dataFrames: 2,
        parityFrames: 1,
        chunkSize: 1024,
        estimatedPdfBytes: 550 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: false,
      );
      expect(desktop.level, MemoryGuardLevel.ok);
    });

    test('a file sink drops the held PDF to one page', () {
      // Same inputs as the desktop-warn case, but the output goes to
      // a file sink (not built yet — this tests the flag's math):
      // held output falls from 850 MB to one ~63 MB page, so the peak
      // (~681 MB) is ok even on desktop.
      final guard = EncodeController.estimateMemoryPeak(
        fileSize: 600 * 1024 * 1024,
        estCompressed: 600 * 1024 * 1024,
        dataFrames: 10,
        parityFrames: 4,
        chunkSize: 60 * 1024 * 1024,
        estimatedPdfBytes: 850 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: true,
      );
      expect(guard.level, MemoryGuardLevel.ok);
    });

    test('a 50 GB incompressible file refuses on desktop', () {
      // Beyond the ceiling: streamed in fixed 64 KiB chunks it needs
      // 819,200 data frames (over the 4,096 cap) and a ~70 GB PDF —
      // far past the 2 GiB refuse line. The route for such a file is
      // the streaming encoder plus a file sink (not built yet), not
      // this in-memory build.
      final estimate = EncodeController.estimateFor(
        fileSize: 50 * 1024 * 1024 * 1024,
        ratio: 1.0,
        sampleBytes: 768 * 1024,
        streaming: true,
      );
      expect(estimate.overCap, isTrue);
      expect(
        estimate.memoryGuard.level,
        MemoryGuardLevel.refuse,
      );
    });

    test('a chunk too large for one code grid refuses outright', () {
      // A 100 GB file at the 30-page cap needs ~3.6 GB pages, past
      // the grid cap (~2.9 GB at maxHeight) — chooseGridSize throws,
      // so the guard refuses with no peak estimate.
      final guard = EncodeController.estimateMemoryPeak(
        fileSize: 100 * 1024 * 1024 * 1024,
        estCompressed: 100 * 1024 * 1024 * 1024,
        dataFrames: 30,
        parityFrames: 10,
        chunkSize: (100 * 1024 * 1024 * 1024 + 29) ~/ 30,
        estimatedPdfBytes: 120 * 1024 * 1024 * 1024,
        streaming: true,
        barcode: false,
        web: false,
        mobile: false,
        streamingBinding: false,
      );
      expect(guard.level, MemoryGuardLevel.refuse);
      expect(guard.estimatedPeakBytes, -1);
      expect(guard.reason, contains('cannot hold'));
    });

    test('desktop warn ceiling for an incompressible streamed file is '
        'in the hundreds of MB (two-phase binding)', () {
      // The guard level for a ratio-1.0 streamed file, via estimateFor
      // (which uses the adaptive page count). The exact ceiling moves
      // with the page rule; the test pins the order of magnitude so a
      // binding or model change fails loudly instead of silently
      // moving the ceiling 10x.
      int peakLevel(int fileSize) {
        final estimate = EncodeController.estimateFor(
          fileSize: fileSize,
          ratio: 1.0,
          sampleBytes: 768 * 1024,
          streaming: true,
        );
        return estimate.memoryGuard.level.index;
      }

      expect(peakLevel(20 * 1024 * 1024), MemoryGuardLevel.ok.index);
      expect(peakLevel(400 * 1024 * 1024), MemoryGuardLevel.ok.index);
      // A 2 GB incompressible file cannot two-phase bind under a
      // 1 GiB warn threshold (its PDF alone is ~2.8 GB), so the
      // guard must at least warn there.
      expect(
        peakLevel(2 * 1024 * 1024 * 1024),
        greaterThanOrEqualTo(MemoryGuardLevel.warn.index),
      );
      // And the warn ceiling itself sits in the hundreds of MB, not
      // in the tens of GB: find the first warn size by bisection.
      var lo = 400 * 1024 * 1024;
      var hi = 2 * 1024 * 1024 * 1024;
      while (hi - lo > 16 * 1024 * 1024) {
        final mid = (lo + hi) ~/ 2;
        if (peakLevel(mid) == MemoryGuardLevel.ok.index) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      expect(hi, greaterThan(300 * 1024 * 1024));
      expect(hi, lessThan(1024 * 1024 * 1024));
    });
  });
}
