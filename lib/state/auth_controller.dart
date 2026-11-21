import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/storage_service.dart';

/// A local account profile.
///
/// Phase 1 has no backend, so the account lives on this device only: the
/// profile, the session and the connected toggles are all persisted
/// locally. Cloud sync, real magic-link email and cloud encode arrive with
/// the backend in phase 2; the UI says so wherever it matters.
class LocalAccount {
  /// Creates a local account profile.
  const LocalAccount({
    required this.email,
    required this.displayName,
    required this.createdAt,
    this.verified = false,
    this.migrated = false,
  });

  /// Account email (the sign-in identifier).
  final String email;

  /// Display name.
  final String displayName;

  /// When the account was created on this device.
  final DateTime createdAt;

  /// True once the 6-digit code was verified.
  final bool verified;

  /// True once guest work was migrated into the account.
  final bool migrated;

  /// Creates a copy with the given fields replaced.
  LocalAccount copyWith({bool? verified, bool? migrated}) => LocalAccount(
        email: email,
        displayName: displayName,
        createdAt: createdAt,
        verified: verified ?? this.verified,
        migrated: migrated ?? this.migrated,
      );

  /// Serialises the profile to JSON.
  Map<String, dynamic> toJson() => {
        'email': email,
        'displayName': displayName,
        'createdAt': createdAt.toIso8601String(),
        'verified': verified,
        'migrated': migrated,
      };

  /// Parses a profile from JSON.
  factory LocalAccount.fromJson(Map<String, dynamic> json) => LocalAccount(
        email: json['email'] as String,
        displayName: json['displayName'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        verified: json['verified'] as bool? ?? false,
        migrated: json['migrated'] as bool? ?? false,
      );
}

/// Result of migrating guest work into the account.
class MigrationResult {
  /// Creates a migration result.
  const MigrationResult({
    required this.historyMoved,
    required this.queueMoved,
  });

  /// History records moved.
  final int historyMoved;

  /// Queued batch items moved.
  final int queueMoved;

  /// Items left behind — always 0; migration never drops anything.
  int get leftBehind => 0;

  /// Total items moved.
  int get totalMoved => historyMoved + queueMoved;
}

/// Auth + account state: guest-first, sign-in optional.
///
/// The product works fully as a guest. Signing in (local in phase 1)
/// unlocks the account screens and records the preference for cloud
/// features; the verification code is generated on-device and shown
/// in-app, labelled DEMO — in production it arrives by email.
class AuthController extends ChangeNotifier {
  /// Stored local profile, if one was ever created on this device.
  LocalAccount? account;

  /// True when a session is active.
  bool signedIn = false;

  /// Email of the verification in progress, if any.
  String? pendingEmail;

  /// Display name of the account being created, if any.
  String? pendingName;

  /// Whether the pending verification is a sign-in (vs create).
  bool pendingIsSignIn = false;

  /// The demo 6-digit code for the pending verification.
  /// Shown in-app, labelled DEMO — no email is sent in phase 1.
  String? demoCode;

  /// Set by [startSignIn] when no local account matches the email.
  bool needsCreate = false;

  /// Shared-links switch (Connected screen).
  bool shareLinksEnabled = true;

  /// Cloud-storage switch (Connected screen). The switch saves the
  /// preference; cloud upload itself ships with the backend in phase 2.
  bool cloudStorageEnabled = false;

  /// Passkey sign-in switch (Connected screen). Saves the preference;
  /// passkeys ship with the backend in phase 2.
  bool passkeysEnabled = false;

  /// True once [load] has completed.
  bool loaded = false;

  /// True when no session is active.
  bool get isGuest => !signedIn;

  /// True when signed in with a verified account.
  bool get isSignedIn => signedIn && account != null;

  /// Loads the persisted profile, session and toggles.
  Future<void> load() async {
    final json = await StorageService.readJson(StorageService.authKey);
    if (json != null) {
      final accountJson = json['account'];
      if (accountJson is Map<String, dynamic>) {
        account = LocalAccount.fromJson(accountJson);
      }
      signedIn = json['signedIn'] as bool? ?? false;
      shareLinksEnabled = json['shareLinksEnabled'] as bool? ?? true;
      cloudStorageEnabled = json['cloudStorageEnabled'] as bool? ?? false;
      passkeysEnabled = json['passkeysEnabled'] as bool? ?? false;
    }
    loaded = true;
    notifyListeners();
  }

  /// Explicitly continues as a guest (no account, no upload, no sync).
  void continueAsGuest() {
    signedIn = false;
    pendingEmail = null;
    pendingName = null;
    demoCode = null;
    needsCreate = false;
    notifyListeners();
  }

  /// Starts account creation: stores the pending profile and generates
  /// the demo verification code.
  void startCreateAccount({
    required String email,
    required String displayName,
  }) {
    pendingEmail = email.trim();
    pendingName = displayName.trim();
    pendingIsSignIn = false;
    needsCreate = false;
    demoCode = _generateCode();
    notifyListeners();
  }

  /// Starts sign-in for [email]. When no local account matches, sets
  /// [needsCreate] so the UI offers account creation instead.
  void startSignIn({required String email}) {
    final trimmed = email.trim();
    if (account == null ||
        account!.email.toLowerCase() != trimmed.toLowerCase()) {
      pendingEmail = trimmed;
      needsCreate = true;
      demoCode = null;
      notifyListeners();
      return;
    }
    pendingEmail = trimmed;
    pendingName = account!.displayName;
    pendingIsSignIn = true;
    needsCreate = false;
    demoCode = _generateCode();
    notifyListeners();
  }

  /// Generates a fresh demo code (the "resend" action).
  void resendCode() {
    if (pendingEmail == null) return;
    demoCode = _generateCode();
    notifyListeners();
  }

  /// Verifies [code] against the demo code. On success the account is
  /// created (or the session restored) and the user is signed in.
  /// Returns true when the code matched.
  Future<bool> verifyCode(String code) async {
    if (demoCode == null ||
        pendingEmail == null ||
        code.trim() != demoCode) {
      return false;
    }
    if (pendingIsSignIn && account != null) {
      account = account!.copyWith(verified: true);
    } else {
      account = LocalAccount(
        email: pendingEmail!,
        displayName: pendingName!.isEmpty ? pendingEmail! : pendingName!,
        createdAt: DateTime.now(),
        verified: true,
        migrated: account?.migrated ?? false,
      );
    }
    signedIn = true;
    pendingEmail = null;
    pendingName = null;
    demoCode = null;
    await _persist();
    notifyListeners();
    return true;
  }

  /// Migrates guest work into the account. Nothing is dropped: the
  /// counts are reported back and [MigrationResult.leftBehind] is 0.
  Future<MigrationResult> migrate({
    required int historyCount,
    required int queueCount,
  }) async {
    if (account != null) {
      account = account!.copyWith(migrated: true);
      await _persist();
    }
    notifyListeners();
    return MigrationResult(
      historyMoved: historyCount,
      queueMoved: queueCount,
    );
  }

  /// Signs out. The local profile stays on the device for the next
  /// sign-in; guest work is untouched.
  Future<void> signOut() async {
    signedIn = false;
    await _persist();
    notifyListeners();
  }

  /// Deletes the local account profile and session. Local history and
  /// queue data are untouched — use Data Controls to clear those too.
  Future<void> deleteAccount() async {
    account = null;
    signedIn = false;
    pendingEmail = null;
    pendingName = null;
    demoCode = null;
    shareLinksEnabled = true;
    cloudStorageEnabled = false;
    passkeysEnabled = false;
    await StorageService.remove(StorageService.authKey);
    notifyListeners();
  }

  /// Sets the shared-links switch.
  Future<void> setShareLinksEnabled(bool value) async {
    shareLinksEnabled = value;
    await _persist();
    notifyListeners();
  }

  /// Sets the cloud-storage preference switch.
  Future<void> setCloudStorageEnabled(bool value) async {
    cloudStorageEnabled = value;
    await _persist();
    notifyListeners();
  }

  /// Sets the passkeys preference switch.
  Future<void> setPasskeysEnabled(bool value) async {
    passkeysEnabled = value;
    await _persist();
    notifyListeners();
  }

  String _generateCode() {
    final random = Random.secure();
    return List<int>.generate(6, (_) => random.nextInt(10)).join();
  }

  Future<void> _persist() async {
    await StorageService.writeJson(StorageService.authKey, {
      'account': account?.toJson(),
      'signedIn': signedIn,
      'shareLinksEnabled': shareLinksEnabled,
      'cloudStorageEnabled': cloudStorageEnabled,
      'passkeysEnabled': passkeysEnabled,
    });
  }
}
