import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/state/history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

HistoryRecord realRecord({String id = 'r1'}) => HistoryRecord(
      id: id,
      kind: HistoryKind.encode,
      fileName: 'Film.mp4',
      originalBytes: 1000000000,
      encodedBytes: 20000000,
      frameCount: 8,
      groupCount: 1,
      barcode: false,
      encrypted: true,
      sha256Hex: 'ab' * 32,
      createdAt: DateTime(2026, 1, 2),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HistoryRecord JSON', () {
    test('round-trips', () {
      final record = realRecord().copyWith(decodeCount: 2, migrated: true);
      final parsed = HistoryRecord.fromJson(record.toJson());
      expect(parsed.id, record.id);
      expect(parsed.kind, record.kind);
      expect(parsed.fileName, record.fileName);
      expect(parsed.originalBytes, record.originalBytes);
      expect(parsed.encodedBytes, record.encodedBytes);
      expect(parsed.decodeCount, 2);
      expect(parsed.migrated, isTrue);
      expect(parsed.ratio, 50);
      expect(parsed.savedBytes, 980000000);
    });
  });

  group('HistoryStore', () {
    test('first load seeds the two demo records', () async {
      final store = HistoryStore();
      await store.load();
      expect(store.loaded, isTrue);
      expect(store.demos.length, 2);
      expect(store.real, isEmpty);
      expect(store.encodeCount, 0);
      expect(store.totalSaved, 0);
      expect(store.averageRatio, 1);
    });

    test('stats cover real records only', () async {
      final store = HistoryStore();
      await store.load();
      await store.add(realRecord());
      expect(store.encodeCount, 1);
      expect(store.totalSaved, 980000000);
      expect(store.averageRatio, 50);
      expect(store.records.first.fileName, 'Film.mp4');
    });

    test('decode count, migration and clear', () async {
      final store = HistoryStore();
      await store.load();
      await store.add(realRecord());
      await store.incrementDecodeCount('r1');
      expect(store.byId('r1')!.decodeCount, 1);
      await store.markAllMigrated();
      expect(store.byId('r1')!.migrated, isTrue);
      await store.clearAll();
      expect(store.real, isEmpty);
      expect(store.demos.length, 2);
      await store.clearAll(includeDemo: true);
      expect(store.records, isEmpty);
    });

    test('persists across loads', () async {
      final first = HistoryStore();
      await first.load();
      await first.add(realRecord());
      final second = HistoryStore();
      await second.load();
      expect(second.byId('r1'), isNotNull);
      expect(second.demos.length, 2);
    });
  });
}
