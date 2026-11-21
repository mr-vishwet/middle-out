import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/state/auth_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AuthController', () {
    test('starts as guest', () async {
      final auth = AuthController();
      await auth.load();
      expect(auth.loaded, isTrue);
      expect(auth.isGuest, isTrue);
      expect(auth.account, isNull);
    });

    test('create account + verify with the demo code', () async {
      final auth = AuthController();
      await auth.load();
      auth.startCreateAccount(
        email: 'ada@example.com',
        displayName: 'Ada',
      );
      expect(auth.demoCode, isNotNull);
      expect(auth.demoCode!.length, 6);
      expect(await auth.verifyCode('000000'), isFalse);
      expect(auth.isSignedIn, isFalse);
      expect(await auth.verifyCode(auth.demoCode!), isTrue);
      expect(auth.isSignedIn, isTrue);
      expect(auth.account!.email, 'ada@example.com');
      expect(auth.account!.verified, isTrue);
    });

    test('sign-in with an unknown email needs creation', () async {
      final auth = AuthController();
      await auth.load();
      auth.startSignIn(email: 'nobody@example.com');
      expect(auth.needsCreate, isTrue);
      expect(auth.demoCode, isNull);
    });

    test('sign-in with a known email verifies and restores', () async {
      final auth = AuthController();
      await auth.load();
      auth.startCreateAccount(email: 'ada@example.com', displayName: 'Ada');
      final code = auth.demoCode!;
      expect(await auth.verifyCode(code), isTrue);
      await auth.signOut();
      expect(auth.isGuest, isTrue);
      auth.startSignIn(email: 'ada@example.com');
      expect(auth.needsCreate, isFalse);
      expect(await auth.verifyCode(auth.demoCode!), isTrue);
      expect(auth.isSignedIn, isTrue);
    });

    test('migrate reports counts and leaves 0 behind', () async {
      final auth = AuthController();
      await auth.load();
      auth.startCreateAccount(email: 'ada@example.com', displayName: 'Ada');
      await auth.verifyCode(auth.demoCode!);
      final result = await auth.migrate(historyCount: 4, queueCount: 3);
      expect(result.totalMoved, 7);
      expect(result.leftBehind, 0);
      expect(auth.account!.migrated, isTrue);
    });

    test('connected toggles persist', () async {
      final auth = AuthController();
      await auth.load();
      await auth.setCloudStorageEnabled(true);
      await auth.setPasskeysEnabled(true);
      final second = AuthController();
      await second.load();
      expect(second.cloudStorageEnabled, isTrue);
      expect(second.passkeysEnabled, isTrue);
    });

    test('delete account clears the profile', () async {
      final auth = AuthController();
      await auth.load();
      auth.startCreateAccount(email: 'ada@example.com', displayName: 'Ada');
      await auth.verifyCode(auth.demoCode!);
      await auth.deleteAccount();
      expect(auth.account, isNull);
      expect(auth.isGuest, isTrue);
      final second = AuthController();
      await second.load();
      expect(second.account, isNull);
    });
  });
}
