import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/core/constants.dart';
import 'package:middle_out/services/platform_limits.dart';

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
}
