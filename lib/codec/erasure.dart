import 'dart:typed_data';

import '../core/constants.dart';

/// XOR erasure coding: each group of 6 DATA frames carries 2 PARITY frames.
///
/// Parity A (slot 6) is the XOR of data slots 0, 1, 2; parity B (slot 7)
/// is the XOR of slots 3, 4, 5. Each trio can lose any ONE frame — lost
/// or CRC-corrupt — and rebuild it exactly. Two losses in one trio are
/// unrecoverable by design (the decoder reports which group and trio).
///
/// Payloads inside a trio are zero-padded to the trio's longest payload
/// before XOR; the true length is recovered from the frame header (or,
/// for a lost frame, from the encode metadata — see `decoder.dart`).
class Erasure {
  /// Builds the parity payload for one trio of data payloads.
  /// Returns empty bytes when the trio has no frames (a trailing group
  /// whose second trio is empty still emits a parity frame, keeping every
  /// group at exactly 8 frames for a uniform PDF layout).
  static Uint8List buildParity(List<Uint8List> trioPayloads) {
    if (trioPayloads.isEmpty) return Uint8List(0);
    var width = 0;
    for (final payload in trioPayloads) {
      if (payload.length > width) width = payload.length;
    }
    final parity = Uint8List(width);
    for (final payload in trioPayloads) {
      for (var i = 0; i < payload.length; i++) {
        parity[i] ^= payload[i];
      }
    }
    return parity;
  }

  /// Rebuilds one lost payload from its parity frame and its surviving
  /// trio siblings. [wantLength] is the lost frame's true payload length;
  /// the XOR result is trimmed to it (parity is padded to trio width).
  static Uint8List recover(
    Uint8List parity,
    List<Uint8List> survivingPayloads,
    int wantLength,
  ) {
    final rebuilt = Uint8List.fromList(parity);
    for (final payload in survivingPayloads) {
      for (var i = 0; i < payload.length; i++) {
        rebuilt[i] ^= payload[i];
      }
    }
    return Uint8List.sublistView(rebuilt, 0, wantLength);
  }

  /// Which parity slot protects [dataSlot] (0-5).
  static int paritySlotFor(int dataSlot) =>
      kParityATrio.contains(dataSlot) ? kParityASlot : kParityBSlot;

  /// The trio (data slots) a parity slot protects.
  static List<int> trioForParitySlot(int paritySlot) =>
      paritySlot == kParityASlot ? kParityATrio : kParityBTrio;
}
