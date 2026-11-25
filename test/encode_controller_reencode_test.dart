import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/ratio_engine.dart';
import 'package:middle_out/codec/reencode.dart';
import 'package:middle_out/core/constants.dart';
import 'package:middle_out/services/file_picker_service.dart';
import 'package:middle_out/services/media_reencoder_stub.dart';
import 'package:middle_out/state/encode_controller.dart';
import 'package:middle_out/state/history_store.dart';
import 'package:middle_out/state/settings_controller.dart';

String _hex(Uint8List bytes) => sha256
    .convert(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Incompressible bytes of [length] (seeded, deterministic).
Uint8List _randomBytes(int length, [int seed = 7]) {
  final random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// A fake re-encoder: returns seeded random bytes of exactly the
/// target size (incompressible, so the real PDF lands where the model
/// says it will), with a canned plan and canned settings.
class FakeMediaReencoder extends StubMediaReencoder {
  FakeMediaReencoder({
    this.cannedPlan,
    this.throwMessage,
    this.returnNull = false,
  });

  final ReencodePlan? cannedPlan;
  final String? throwMessage;
  final bool returnNull;

  int reencodeCalls = 0;
  int? lastTargetBytes;

  @override
  bool get isAvailable => true;

  @override
  String get encoderName => 'Fake encoder';

  @override
  Future<ReencodePlan?> plan(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
  }) async =>
      cannedPlan;

  @override
  Future<ReencodedMedia?> reencode(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
    ReencodeProgress? onProgress,
  }) async {
    reencodeCalls++;
    lastTargetBytes = targetBytes;
    if (throwMessage != null) {
      throw ReencodeException(throwMessage!);
    }
    if (returnNull) return null;
    onProgress?.call(0.5, 'Fake re-encoding…');
    onProgress?.call(1.0, 'Fake re-encoding…');
    return ReencodedMedia(
      bytes: _randomBytes(targetBytes, 99),
      kind: detectMediaKind(fileName, bytes),
      encoder: 'Fake encoder',
      settingsLabel: 'fake 640x360 @ 400 kbps',
    );
  }
}

/// The 3.1 MB Sintel-sized clip: random bytes named as a video, so the
/// estimate proposes a re-encode with the pinned 142,519 B budget.
EncodeController _clipController({
  MediaReencoder? reencoder,
  bool losslessOnly = false,
}) {
  final controller = EncodeController(reencoder: reencoder);
  if (losslessOnly) {
    final settings = SettingsController()..losslessOnly = true;
    controller.applySettings(settings);
  }
  controller.file = PickedRef(
    name: 'clip.mp4',
    size: 3105557,
    bytes: _randomBytes(3105557),
  );
  // Encrypted (the default): the estimate model then uses the
  // encrypted second-pass factor (1.0), so the pinned numbers from
  // the ratio tests apply exactly.
  controller.encrypted = true;
  controller.passphrase = 'test-passphrase';
  controller.phase = EncodePhase.ready;
  return controller;
}

void main() {
  group('refreshEstimate proposes a re-encode for the clip', () {
    test('decision, both numbers, and the fake plan load', () async {
      final fake = FakeMediaReencoder(
        cannedPlan: const ReencodePlan(
          encoder: 'Fake encoder',
          settingsLabel: 'fake 640x360 @ 400 kbps',
        ),
      );
      final controller = _clipController(reencoder: fake);
      await controller.refreshEstimate();
      final estimate = controller.estimate!;
      expect(estimate.decision, RatioDecision.reencode);
      expect(estimate.losslessPdfBytes, 6453260);
      expect(estimate.reencodeTargetMediaBytes, 142519);
      expect(estimate.reencodeTargetPdfBytes, 303084);
      expect(controller.awaitingReencodeDecision, isTrue);
      expect(controller.reencodePlan, isNotNull);
      expect(
        controller.reencodePlan!.settingsLabel,
        'fake 640x360 @ 400 kbps',
      );
    });

    test('with the stub (unavailable) the proposal has no plan', () async {
      final controller = _clipController();
      await controller.refreshEstimate();
      expect(controller.estimate!.decision, RatioDecision.reencode);
      expect(controller.reencodePlan, isNull);
    });

    test('lossless-only mode flips the clip estimate to dead end',
        () async {
      final controller = _clipController(losslessOnly: true);
      await controller.refreshEstimate();
      expect(controller.estimate!.decision, RatioDecision.deadEnd);
      expect(
        controller.estimate!.deadEndReason,
        contains('Lossless-only is on'),
      );
      expect(controller.awaitingDeadEndDecision, isTrue);
    });
  });

  group('confirmReencode flow', () {
    test('re-encodes, flags every frame, records history, PDF fits '
        '10:1', () async {
      final fake = FakeMediaReencoder(
        cannedPlan: const ReencodePlan(
          encoder: 'Fake encoder',
          settingsLabel: 'fake 640x360 @ 400 kbps',
        ),
      );
      final controller = _clipController(reencoder: fake);
      HistoryRecord? recorded;
      controller.onEncoded = (record) async {
        recorded = record;
      };
      await controller.refreshEstimate();
      await controller.confirmReencode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.error, isNull);
      expect(fake.reencodeCalls, 1);
      expect(fake.lastTargetBytes, 142519);
      expect(controller.reencodeChoice, ReencodeChoice.confirmed);
      final stats = controller.result!.stats;
      expect(stats.reencode, isNotNull);
      expect(stats.reencode!.originalSizeBytes, 3105557);
      expect(stats.reencode!.originalSha256Hex,
          _hex(_randomBytes(3105557)));
      expect(stats.reencode!.reencodedSizeBytes, 142519);
      expect(stats.reencode!.reencodedSha256Hex,
          _hex(_randomBytes(142519, 99)));
      // The header SHA/size describe the RE-ENCODED bytes.
      expect(stats.sha256Hex, _hex(_randomBytes(142519, 99)));
      expect(stats.originalSize, 142519);
      // Every frame carries the flag — including parity frames.
      expect(
        controller.result!.frames.every(
          (f) => f.flags & kFlagReencoded != 0,
        ),
        isTrue,
      );
      // The REAL PDF lands inside 10:1 — the budget is not just a
      // modeled number.
      expect(controller.pdfStats, isNotNull);
      expect(controller.pdfStats!.sizeBytes, lessThanOrEqualTo(310555));
      // History describes the ORIGINAL file and carries the record.
      expect(recorded, isNotNull);
      expect(recorded!.originalBytes, 3105557);
      expect(recorded!.sha256Hex, _hex(_randomBytes(3105557)));
      expect(recorded!.reencode, isNotNull);
      expect(recorded!.reencode!.encoder, 'Fake encoder');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('encode() without confirmation fails honestly and never '
        're-encodes', () async {
      final fake = FakeMediaReencoder();
      final controller = _clipController(reencoder: fake);
      await controller.refreshEstimate();
      expect(controller.awaitingReencodeDecision, isTrue);
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.error, contains('confirm the proposal'));
      expect(fake.reencodeCalls, 0);
      expect(controller.result, isNull);
    });

    test('a throwing re-encoder fails with its message, verbatim',
        () async {
      final fake = FakeMediaReencoder(
        throwMessage:
            "even the lowest quality can't reach 10:1 for this file",
      );
      final controller = _clipController(reencoder: fake);
      await controller.refreshEstimate();
      await controller.confirmReencode();
      expect(controller.phase, EncodePhase.error);
      expect(
        controller.error,
        "even the lowest quality can't reach 10:1 for this file",
      );
      expect(controller.result, isNull);
    });

    test('a null re-encode result fails honestly', () async {
      final fake = FakeMediaReencoder(returnNull: true);
      final controller = _clipController(reencoder: fake);
      await controller.refreshEstimate();
      await controller.confirmReencode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.error, contains('cannot be re-encoded'));
    });

    test('the stub fails honestly: re-encoding is not available',
        () async {
      // Inject the stub explicitly: the platform default on web is
      // the real WebCodecs encoder, which fails differently on this
      // fake (non-MP4) clip — the stub's honest failure is what this
      // test pins.
      final controller =
          _clipController(reencoder: StubMediaReencoder());
      await controller.refreshEstimate();
      await controller.confirmReencode();
      expect(controller.phase, EncodePhase.error);
      expect(
        controller.error,
        'Re-encoding is not available on this device.',
      );
    });
  });

  group('declineReencode flow', () {
    test('encodes losslessly, records the choice, never re-encodes',
        () async {
      final fake = FakeMediaReencoder();
      final controller = _clipController(reencoder: fake);
      HistoryRecord? recorded;
      controller.onEncoded = (record) async {
        recorded = record;
      };
      await controller.refreshEstimate();
      await controller.declineReencode();
      expect(controller.phase, EncodePhase.done);
      expect(fake.reencodeCalls, 0);
      expect(controller.reencodeChoice, ReencodeChoice.declined);
      final stats = controller.result!.stats;
      expect(stats.reencode, isNull);
      expect(stats.originalSize, 3105557);
      expect(stats.sha256Hex, _hex(_randomBytes(3105557)));
      expect(
        controller.result!.frames.every(
          (f) => f.flags & kFlagReencoded == 0,
        ),
        isTrue,
      );
      expect(recorded, isNotNull);
      expect(recorded!.reencode, isNull);
      expect(recorded!.originalBytes, 3105557);
    },
        timeout: const Timeout(Duration(minutes: 2)),
        onPlatform: const {
          'chrome': Skip(
            'full 3.1 MB lossless encode + PDF build (~28M grid '
            'cells) exceeds 2 min under DDC; the VM run covers it, '
            'and the confirm test covers the same encode + PDF code '
            'in the browser',
          ),
        });
  });

  group('dead-end flow', () {
    EncodeController deadEndController() {
      final controller = EncodeController();
      controller.file = PickedRef(
        name: 'data.bin',
        size: 1024 * 1024,
        bytes: _randomBytes(1024 * 1024),
      );
      controller.encrypted = false;
      controller.phase = EncodePhase.ready;
      return controller;
    }

    test('encode() is blocked until the user chooses lossless anyway',
        () async {
      final controller = deadEndController();
      await controller.refreshEstimate();
      expect(controller.estimate!.decision, RatioDecision.deadEnd);
      expect(controller.awaitingDeadEndDecision, isTrue);
      await controller.encode();
      expect(controller.phase, EncodePhase.error);
      expect(controller.error, contains("can't reach 10:1"));
      controller.acknowledgeDeadEnd();
      expect(controller.awaitingDeadEndDecision, isFalse);
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.result!.stats.reencode, isNull);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('confirm/decline are no-ops on a dead end', () async {
      final controller = deadEndController();
      await controller.refreshEstimate();
      await controller.confirmReencode();
      expect(controller.reencodeChoice, ReencodeChoice.undecided);
      expect(controller.phase, EncodePhase.ready);
      await controller.declineReencode();
      expect(controller.reencodeChoice, ReencodeChoice.undecided);
    });
  });

  group('lossless path is untouched', () {
    test('text that beats 10:1 encodes losslessly with no proposal',
        () async {
      final controller = EncodeController();
      final unit = 'Middle Out lossless test. '.codeUnits;
      // 560 KB of repeated text: ratio ~200x, so the lossless PDF is
      // ~8 KB against a 56 KB target. (A few KB of text would be a
      // dead end — the fixed ~6.4 KB PDF cost alone breaks 10:1 —
      // which is correct behaviour, not a bug.)
      final bytes = Uint8List.fromList(
        [for (var i = 0; i < 20000; i++) ...unit],
      );
      controller.file = PickedRef(
        name: 'note.txt',
        size: bytes.length,
        bytes: bytes,
      );
      controller.encrypted = false;
      controller.phase = EncodePhase.ready;
      await controller.refreshEstimate();
      expect(controller.estimate!.decision, RatioDecision.lossless);
      expect(controller.awaitingReencodeDecision, isFalse);
      await controller.encode();
      expect(controller.phase, EncodePhase.done);
      expect(controller.result!.stats.reencode, isNull);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
