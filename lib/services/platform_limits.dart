import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/format.dart';

/// Where an encode runs. The mode decides the per-file limit and whether
/// anything leaves the device.
enum EncodeMode {
  /// Native app: 100 GB per file, streaming, local.
  native,

  /// Web, in-browser: 10 GB, no upload.
  webLocal,

  /// Web, cloud: 50 GB, resumable chunked upload (account needed).
  webCloud,
}

/// Human-readable info for an [EncodeMode]: limits, labels, descriptions.
extension EncodeModeInfo on EncodeMode {
  /// Maximum single-file size for this mode, in bytes.
  int get maxBytes => switch (this) {
        EncodeMode.native => PlatformLimits.nativeMaxBytes,
        EncodeMode.webLocal => PlatformLimits.webLocalMaxBytes,
        EncodeMode.webCloud => PlatformLimits.webCloudMaxBytes,
      };

  /// Short label for the mode picker (e.g. 'Web · Local').
  String get label => switch (this) {
        EncodeMode.native => 'Native app',
        EncodeMode.webLocal => 'Web · Local',
        EncodeMode.webCloud => 'Web · Cloud',
      };

  /// One-line description of where the encode runs.
  String get description => switch (this) {
        EncodeMode.native => 'Streaming, local — nothing leaves your device.',
        EncodeMode.webLocal => 'In-browser, no upload — nothing leaves this tab.',
        EncodeMode.webCloud =>
          'Resumable chunked upload. Account needed.',
      };

  /// Whether this mode needs an account.
  bool get needsAccount => this == EncodeMode.webCloud;
}

/// Platform-limit rules: detection, enforcement and routing advice.
class PlatformLimitsService {
  /// The default mode for the current platform: native on mobile/desktop,
  /// web-local on web.
  static EncodeMode defaultMode() =>
      kIsWeb ? EncodeMode.webLocal : EncodeMode.native;

  /// All modes available on the current platform.
  static List<EncodeMode> availableModes() => kIsWeb
      ? [EncodeMode.webLocal, EncodeMode.webCloud]
      : [EncodeMode.native];

  /// True when [fileSize] fits in [mode].
  static bool fits(int fileSize, EncodeMode mode) => fileSize <= mode.maxBytes;

  /// The smallest mode that can hold [fileSize], or null when no mode can.
  /// Native (100 GB) is the ceiling: anything larger cannot be encoded.
  static EncodeMode? smallestModeFor(int fileSize) {
    if (fileSize <= EncodeMode.webLocal.maxBytes) return EncodeMode.webLocal;
    if (fileSize <= EncodeMode.webCloud.maxBytes) return EncodeMode.webCloud;
    if (fileSize <= EncodeMode.native.maxBytes) return EncodeMode.native;
    return null;
  }

  /// Human-readable routing advice when [fileSize] exceeds [mode]'s limit.
  static String overLimitAdvice(int fileSize, EncodeMode mode) {
    final target = smallestModeFor(fileSize);
    if (target == null) {
      return 'This file (${formatBytes(fileSize)}) is larger than the '
          '100 GB native limit — split it before encoding.';
    }
    if (target == mode) return '';
    return 'This file (${formatBytes(fileSize)}) exceeds the '
        '${mode.label} limit (${formatBytes(mode.maxBytes)}). '
        'Switch to ${target.label} (up to ${formatBytes(target.maxBytes)}).';
  }

  /// Checks the encoded PDF against the product's hard band: a 1 GB input
  /// must compress to a 5–20 MB PDF, never hundreds of MB. Returns null
  /// when in band, otherwise a warning for the result screen.
  static String? pdfBandWarning(int originalBytes, int pdfBytes) {
    if (originalBytes <= 0) return null;
    final gb = originalBytes / (1024 * 1024 * 1024);
    final maxAllowed = (kPdfSizeMaxPerGb * gb).ceil();
    if (pdfBytes <= maxAllowed) return null;
    return 'This PDF (${formatBytes(pdfBytes)}) is above the '
        '${formatBytes(kPdfSizeMaxPerGb)}-per-GB band for a '
        '${formatBytes(originalBytes)} input. Already-compressed or random '
        'data barely shrinks — the frames carry nearly the whole file.';
  }
}
