import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// A shared link for an encoded PDF.
///
/// Phase 1 has no backend, so links are demo records: the link is
/// created, listed with its 7-day expiry, and revocable — but it does not
/// resolve anywhere until cloud sharing ships in phase 2. The UI labels
/// it DEMO, and the PDF file itself is what you share today.
class SharedLink {
  /// Creates a shared link record.
  const SharedLink({
    required this.id,
    required this.fileName,
    required this.createdAt,
    required this.expiresAt,
    this.revoked = false,
  });

  /// Link id (the path segment after `/s/`).
  final String id;

  /// File the link points at.
  final String fileName;

  /// When the link was created.
  final DateTime createdAt;

  /// When the link expires (7 days after creation).
  final DateTime expiresAt;

  /// True once the link has been revoked.
  final bool revoked;

  /// True when the link is past its expiry.
  bool get expired => DateTime.now().isAfter(expiresAt);

  /// True when the link is live (not revoked, not expired).
  bool get isLive => !revoked && !expired;

  /// The demo URL. Labelled DEMO in the UI — it resolves only once
  /// cloud sharing ships in phase 2.
  String get url => 'https://middleout.app/s/$id';

  /// Creates a copy with the given fields replaced.
  SharedLink copyWith({bool? revoked}) => SharedLink(
        id: id,
        fileName: fileName,
        createdAt: createdAt,
        expiresAt: expiresAt,
        revoked: revoked ?? this.revoked,
      );

  /// Serialises the link to JSON.
  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'revoked': revoked,
      };

  /// Parses a link from JSON.
  factory SharedLink.fromJson(Map<String, dynamic> json) => SharedLink(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        revoked: json['revoked'] as bool? ?? false,
      );
}

/// The shared-link store: created links, newest first.
class LinkStore extends ChangeNotifier {
  /// Links, newest first.
  List<SharedLink> links = [];

  /// True once [load] has completed.
  bool loaded = false;

  /// Loads persisted links.
  Future<void> load() async {
    final stored =
        await StorageService.readJsonList(StorageService.linksKey);
    links = stored == null
        ? []
        : [for (final json in stored) SharedLink.fromJson(json)];
    loaded = true;
    notifyListeners();
  }

  /// Creates a demo link for [fileName], expiring in 7 days.
  Future<SharedLink> create(String fileName) async {
    final now = DateTime.now();
    final link = SharedLink(
      id: _newId(),
      fileName: fileName,
      createdAt: now,
      expiresAt: now.add(const Duration(days: 7)),
    );
    links = [link, ...links];
    await _persist();
    notifyListeners();
    return link;
  }

  /// Revokes a link.
  Future<void> revoke(String id) async {
    links = [
      for (final link in links)
        if (link.id == id) link.copyWith(revoked: true) else link,
    ];
    await _persist();
    notifyListeners();
  }

  /// Removes all links (data controls).
  Future<void> clearAll() async {
    links = [];
    await _persist();
    notifyListeners();
  }

  String _newId() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final now = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    var value = now;
    for (var i = 0; i < 10; i++) {
      buf.write(chars[value % chars.length]);
      value ~/= chars.length;
    }
    return buf.toString();
  }

  Future<void> _persist() async {
    await StorageService.writeJsonList(
      StorageService.linksKey,
      [for (final link in links) link.toJson()],
    );
  }
}
