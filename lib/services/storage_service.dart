import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Tiny JSON persistence layer over `shared_preferences`.
///
/// History, settings, the local account, batch metadata and shared links
/// are all small JSON documents — no relational store is needed, so phase 1
/// persists them here rather than pulling in Drift/SQLite. The passphrase
/// is never persisted anywhere (see [EncodeController]).
abstract final class StorageService {
  /// History records (list of [HistoryRecord] JSON objects).
  static const String historyKey = 'middleout.history.v1';

  /// Settings document.
  static const String settingsKey = 'middleout.settings.v1';

  /// Local account + session + connected toggles.
  static const String authKey = 'middleout.auth.v1';

  /// Batch queue metadata (path-based items only — bytes never persist).
  static const String batchKey = 'middleout.batch.v1';

  /// Shared-link records (demo links until cloud ships).
  static const String linksKey = 'middleout.links.v1';

  /// Reads a JSON list, or null when the key was never written.
  static Future<List<Map<String, dynamic>>?> readJsonList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [
      for (final item in decoded)
        if (item is Map<String, dynamic>) item,
    ];
  }

  /// Writes a JSON list.
  static Future<void> writeJsonList(
    String key,
    List<Map<String, dynamic>> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(items));
  }

  /// Reads a JSON object, or null when the key was never written.
  static Future<Map<String, dynamic>?> readJson(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Writes a JSON object.
  static Future<void> writeJson(String key, Map<String, dynamic> json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(json));
  }

  /// Removes a key.
  static Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
