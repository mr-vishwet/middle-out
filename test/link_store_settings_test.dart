import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/state/link_store.dart';
import 'package:middle_out/state/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LinkStore', () {
    test('create, expiry, revoke, persist', () async {
      final store = LinkStore();
      await store.load();
      expect(store.links, isEmpty);
      final before = DateTime.now();
      final link = await store.create('Film.mp4');
      expect(link.isLive, isTrue);
      expect(link.url, startsWith('https://middleout.app/s/'));
      expect(
        link.expiresAt.difference(before),
        greaterThan(const Duration(days: 6, hours: 23)),
      );
      await store.revoke(link.id);
      expect(store.links.single.isLive, isFalse);
      final second = LinkStore();
      await second.load();
      expect(second.links.length, 1);
      expect(second.links.single.revoked, isTrue);
    });
  });

  group('SettingsController', () {
    test('defaults and persistence', () async {
      final settings = SettingsController();
      await settings.load();
      expect(settings.defaultBarcode, isFalse);
      expect(settings.defaultEncrypted, isTrue);
      expect(settings.showDemo, isTrue);
      await settings.setDefaultBarcode(true);
      await settings.setShowDemo(false);
      final second = SettingsController();
      await second.load();
      expect(second.defaultBarcode, isTrue);
      expect(second.showDemo, isFalse);
    });
  });
}
