import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// User settings, persisted locally.
///
/// Defaults feed the encode flow ([EncodeController.applySettings]) and
/// the settings screen. Nothing here leaves the device.
class SettingsController extends ChangeNotifier {
  /// Default code format for new encodes (false = QR grid).
  bool defaultBarcode = false;

  /// Default encryption for new encodes (default ON, per the spec).
  bool defaultEncrypted = true;

  /// Verify the SHA-256 after every decode (always on in v0.1 — the
  /// decoder refuses to show unverified output; this switch controls the
  /// explicit verify screen step).
  bool autoVerify = true;

  /// Keep the encoded PDF in the app's documents dir after sharing.
  bool keepPdfs = true;

  /// Show the seeded demo records and demo card.
  bool showDemo = true;

  /// Lossless-only mode: when on, no re-encode is ever proposed — a
  /// file that cannot reach 10:1 losslessly is a dead end, and the
  /// estimate shows the true lossless size with the incompressible
  /// warning. Default off: re-encodable media may be proposed for
  /// re-encoding, always with the user's confirmation.
  bool losslessOnly = false;

  /// True once [load] has completed.
  bool loaded = false;

  /// Loads persisted settings (defaults when never written).
  Future<void> load() async {
    final json =
        await StorageService.readJson(StorageService.settingsKey);
    if (json != null) {
      defaultBarcode = json['defaultBarcode'] as bool? ?? false;
      defaultEncrypted = json['defaultEncrypted'] as bool? ?? true;
      autoVerify = json['autoVerify'] as bool? ?? true;
      keepPdfs = json['keepPdfs'] as bool? ?? true;
      showDemo = json['showDemo'] as bool? ?? true;
      losslessOnly = json['losslessOnly'] as bool? ?? false;
    }
    loaded = true;
    notifyListeners();
  }

  /// Sets the default code format.
  Future<void> setDefaultBarcode(bool value) async {
    defaultBarcode = value;
    await _persist();
    notifyListeners();
  }

  /// Sets the default encryption toggle.
  Future<void> setDefaultEncrypted(bool value) async {
    defaultEncrypted = value;
    await _persist();
    notifyListeners();
  }

  /// Sets the auto-verify preference.
  Future<void> setAutoVerify(bool value) async {
    autoVerify = value;
    await _persist();
    notifyListeners();
  }

  /// Sets the keep-PDFs preference.
  Future<void> setKeepPdfs(bool value) async {
    keepPdfs = value;
    await _persist();
    notifyListeners();
  }

  /// Sets whether demo content shows.
  Future<void> setShowDemo(bool value) async {
    showDemo = value;
    await _persist();
    notifyListeners();
  }

  /// Sets lossless-only mode (no re-encode is ever proposed).
  Future<void> setLosslessOnly(bool value) async {
    losslessOnly = value;
    await _persist();
    notifyListeners();
  }

  /// Serialises settings to JSON.
  Map<String, dynamic> toJson() => {
        'defaultBarcode': defaultBarcode,
        'defaultEncrypted': defaultEncrypted,
        'autoVerify': autoVerify,
        'keepPdfs': keepPdfs,
        'showDemo': showDemo,
        'losslessOnly': losslessOnly,
      };

  Future<void> _persist() async {
    await StorageService.writeJson(StorageService.settingsKey, toJson());
  }
}
