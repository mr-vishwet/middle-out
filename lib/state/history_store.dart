import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// Whether a history record is an encode or a decode.
enum HistoryKind {
  /// A file encoded into frames + PDF.
  encode,

  /// Frames decoded back into the original file.
  decode,
}

/// One history record: an encode or a decode, persisted as JSON.
///
/// Records hold metadata only — never file bytes, never the passphrase.
/// Demo records ([isDemo]) are seeded examples from the V7 design, shown
/// with a DEMO chip and excluded from the stats row.
class HistoryRecord {
  /// Creates a history record.
  const HistoryRecord({
    required this.id,
    required this.kind,
    required this.fileName,
    required this.originalBytes,
    required this.encodedBytes,
    required this.frameCount,
    required this.groupCount,
    required this.barcode,
    required this.encrypted,
    required this.sha256Hex,
    required this.createdAt,
    this.isDemo = false,
    this.decodeCount = 0,
    this.savedPath,
    this.migrated = false,
  });

  /// Stable id (milliseconds + random suffix at creation time).
  final String id;

  /// Encode or decode.
  final HistoryKind kind;

  /// Original file name.
  final String fileName;

  /// Bytes of the original file.
  final int originalBytes;

  /// Bytes of the encoded payload (compressed + encrypted stream).
  final int encodedBytes;

  /// Frames in the encode (data + parity).
  final int frameCount;

  /// 8-frame groups in the encode.
  final int groupCount;

  /// True when the frames were rendered as stacked barcodes.
  final bool barcode;

  /// True when the payload was encrypted.
  final bool encrypted;

  /// Full SHA-256 hex of the original file.
  final String sha256Hex;

  /// When the record was created (seed time for demo records).
  final DateTime createdAt;

  /// True for seeded demo examples — never a measurement.
  final bool isDemo;

  /// How many times the encode has been decoded back byte-exact.
  final int decodeCount;

  /// Where the encoded PDF was saved, if the user saved it.
  final String? savedPath;

  /// True once the record has been migrated into the account.
  final bool migrated;

  /// Compression ratio (original / encoded).
  double get ratio =>
      encodedBytes <= 0 ? 1 : originalBytes / encodedBytes;

  /// Bytes saved by the encode (0 for decodes of others' files).
  int get savedBytes => originalBytes - encodedBytes;

  /// Creates a copy with the given fields replaced.
  HistoryRecord copyWith({
    int? decodeCount,
    String? savedPath,
    bool? migrated,
  }) =>
      HistoryRecord(
        id: id,
        kind: kind,
        fileName: fileName,
        originalBytes: originalBytes,
        encodedBytes: encodedBytes,
        frameCount: frameCount,
        groupCount: groupCount,
        barcode: barcode,
        encrypted: encrypted,
        sha256Hex: sha256Hex,
        createdAt: createdAt,
        isDemo: isDemo,
        decodeCount: decodeCount ?? this.decodeCount,
        savedPath: savedPath ?? this.savedPath,
        migrated: migrated ?? this.migrated,
      );

  /// Serialises the record to JSON.
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'fileName': fileName,
        'originalBytes': originalBytes,
        'encodedBytes': encodedBytes,
        'frameCount': frameCount,
        'groupCount': groupCount,
        'barcode': barcode,
        'encrypted': encrypted,
        'sha256Hex': sha256Hex,
        'createdAt': createdAt.toIso8601String(),
        'isDemo': isDemo,
        'decodeCount': decodeCount,
        'savedPath': savedPath,
        'migrated': migrated,
      };

  /// Parses a record from JSON.
  factory HistoryRecord.fromJson(Map<String, dynamic> json) => HistoryRecord(
        id: json['id'] as String,
        kind: HistoryKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => HistoryKind.encode,
        ),
        fileName: json['fileName'] as String,
        originalBytes: json['originalBytes'] as int,
        encodedBytes: json['encodedBytes'] as int,
        frameCount: json['frameCount'] as int,
        groupCount: json['groupCount'] as int,
        barcode: json['barcode'] as bool,
        encrypted: json['encrypted'] as bool,
        sha256Hex: json['sha256Hex'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        isDemo: json['isDemo'] as bool? ?? false,
        decodeCount: json['decodeCount'] as int? ?? 0,
        savedPath: json['savedPath'] as String?,
        migrated: json['migrated'] as bool? ?? false,
      );

  /// Seeded demo: the 1.04 GB podcast master from the V7 design.
  /// Labelled DEMO everywhere it shows — a story, not a measurement.
  factory HistoryRecord.demoPodcast() => HistoryRecord(
        id: 'demo-podcast',
        kind: HistoryKind.encode,
        fileName: 'Podcast — Ep. 14 Master.wav',
        originalBytes: 1040000000,
        encodedBytes: 14200000,
        frameCount: 8,
        groupCount: 1,
        barcode: false,
        encrypted: true,
        sha256Hex:
            '9f2c41be7d03a81d5c19e2f408b6d3a700000000000000000000000000000000',
        createdAt: DateTime.now(),
        isDemo: true,
        decodeCount: 1,
      );

  /// Seeded demo: the Product Shoot history-detail example from the V7
  /// design ("2.1 GB → 28 MB, decoded twice byte-exact").
  factory HistoryRecord.demoProductShoot() => HistoryRecord(
        id: 'demo-product-shoot',
        kind: HistoryKind.encode,
        fileName: 'Product Shoot — Final Cut.mp4',
        originalBytes: 2100000000,
        encodedBytes: 28000000,
        frameCount: 10,
        groupCount: 2,
        barcode: true,
        encrypted: true,
        sha256Hex:
            '41be7d03a81d5c19e2f408b6d3a79f2c00000000000000000000000000000000',
        createdAt: DateTime.now(),
        isDemo: true,
        decodeCount: 2,
      );

  /// Generates an id for a new real record.
  static String newId() =>
      '${DateTime.now().millisecondsSinceEpoch}-'
      '${DateTime.now().microsecond}';
}

/// The history store: all encode/decode records, newest first.
///
/// Loads from [StorageService] on start and seeds the two demo records on
/// first run. Stats ([totalSaved], [averageRatio], [encodeCount]) cover
/// real records only — demo records never inflate them.
class HistoryStore extends ChangeNotifier {
  /// Records, newest first.
  List<HistoryRecord> records = [];

  /// True once [load] has completed.
  bool loaded = false;

  /// Real (non-demo) records.
  List<HistoryRecord> get real =>
      [for (final r in records) if (!r.isDemo) r];

  /// Seeded demo records.
  List<HistoryRecord> get demos =>
      [for (final r in records) if (r.isDemo) r];

  /// Real encodes.
  List<HistoryRecord> get encodes => [
        for (final r in real)
          if (r.kind == HistoryKind.encode) r,
      ];

  /// Real decodes.
  List<HistoryRecord> get decodes => [
        for (final r in real)
          if (r.kind == HistoryKind.decode) r,
      ];

  /// Number of real encodes.
  int get encodeCount => encodes.length;

  /// Bytes saved across real encodes.
  int get totalSaved =>
      encodes.fold(0, (sum, r) => sum + r.savedBytes);

  /// Mean compression ratio across real encodes (1 when there are none).
  double get averageRatio {
    if (encodes.isEmpty) return 1;
    return encodes.fold(0.0, (sum, r) => sum + r.ratio) / encodes.length;
  }

  /// Loads persisted records, seeding demos on first run.
  Future<void> load() async {
    final stored =
        await StorageService.readJsonList(StorageService.historyKey);
    if (stored == null) {
      records = [
        HistoryRecord.demoPodcast(),
        HistoryRecord.demoProductShoot(),
      ];
      await _persist();
    } else {
      records = [
        for (final json in stored) HistoryRecord.fromJson(json),
      ];
    }
    loaded = true;
    notifyListeners();
  }

  /// Finds a record by id, or null.
  HistoryRecord? byId(String id) {
    for (final record in records) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// Adds a record to the top of the list and persists.
  Future<void> add(HistoryRecord record) async {
    records = [record, ...records];
    await _persist();
    notifyListeners();
  }

  /// Removes a record and persists.
  Future<void> remove(String id) async {
    records = [for (final r in records) if (r.id != id) r];
    await _persist();
    notifyListeners();
  }

  /// Bumps a record's decode count (called after a verified decode).
  Future<void> incrementDecodeCount(String id) async {
    records = [
      for (final r in records)
        if (r.id == id)
          r.copyWith(decodeCount: r.decodeCount + 1)
        else
          r,
    ];
    await _persist();
    notifyListeners();
  }

  /// Records where the encoded PDF was saved.
  Future<void> setSavedPath(String id, String path) async {
    records = [
      for (final r in records)
        if (r.id == id) r.copyWith(savedPath: path) else r,
    ];
    await _persist();
    notifyListeners();
  }

  /// Marks every record migrated (account migration).
  Future<void> markAllMigrated() async {
    records = [for (final r in records) r.copyWith(migrated: true)];
    await _persist();
    notifyListeners();
  }

  /// Clears records. Demo records are kept unless [includeDemo] is set.
  Future<void> clearAll({bool includeDemo = false}) async {
    records = includeDemo
        ? []
        : [for (final r in records) if (r.isDemo) r];
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await StorageService.writeJsonList(
      StorageService.historyKey,
      [for (final r in records) r.toJson()],
    );
  }
}
