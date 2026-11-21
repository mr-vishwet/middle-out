import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/state/batch_controller.dart';
import 'package:middle_out/state/history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

BatchItem smallItem({String id = 'b1', bool encrypted = false}) =>
    BatchItem(
      id: id,
      name: 'note.txt',
      size: 26,
      bytes: Uint8List.fromList('Middle Out batch test file.'.codeUnits),
      encrypted: encrypted,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BatchController', () {
    test('runOne encodes, builds the PDF and records history', () async {
      final batch = BatchController();
      await batch.load();
      final seen = <HistoryRecord>[];
      batch.onItemDone = (record) async {
        seen.add(record);
      };
      await batch.addItem(smallItem());
      await batch.runOne('b1');
      final item = batch.items.single;
      expect(item.status, BatchStatus.done);
      expect(item.result, isNotNull);
      expect(item.pdfBytes, isNotNull);
      expect(item.pdfStats!.pages, item.result!.frames.length + 1);
      expect(seen.length, 1);
      expect(seen.single.fileName, 'note.txt');
      expect(batch.doneCount, 1);
    });

    test('encrypted item without a passphrase fails with guidance', () async {
      final batch = BatchController();
      await batch.load();
      await batch.addItem(smallItem(encrypted: true));
      await batch.runOne('b1');
      final item = batch.items.single;
      expect(item.status, BatchStatus.error);
      expect(item.error, contains('passphrase'));
    });

    test('per-item options update and items remove', () async {
      final batch = BatchController();
      await batch.load();
      await batch.addItem(smallItem());
      batch.updateOptions('b1', barcode: true, passphrase: 'secret');
      expect(batch.items.single.barcode, isTrue);
      expect(batch.items.single.passphrase, 'secret');
      await batch.remove('b1');
      expect(batch.items, isEmpty);
    });

    test('runAll runs queued items in order', () async {
      final batch = BatchController();
      await batch.load();
      await batch.addItem(smallItem(id: 'b1'));
      await batch.addItem(smallItem(id: 'b2'));
      await batch.runAll();
      expect(batch.doneCount, 2);
      expect(batch.running, isFalse);
    });
  });
}
