import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/constants.dart';

/// ChaCha20 (RFC 8439) in pure Dart, plus PBKDF2-HMAC-SHA256 key derivation.
///
/// No platform dependency: the same code runs on mobile and web. Validated
/// against OpenSSL's RFC 8439 ChaCha20 via the Python reference
/// (`reference/test_codec_reference.py`, ChaCha20Tests).
///
/// v0.1 uses raw ChaCha20 (a stream cipher, no authentication tag).
/// Tampering is caught by the per-frame payload CRCs and the final SHA-256
/// verification — a wrong passphrase or a flipped bit fails loudly at
/// decode time. ChaCha20-Poly1305 (AEAD) is the planned v0.2 upgrade.
class ChaCha20 {
  static const List<int> _constants = [
    0x61707865, // "expa"
    0x3320646e, // "nd 3"
    0x79622d32, // "2-by"
    0x6b206574, // "te k"
  ];

  static int _rotl32(int value, int bits) =>
      ((value << bits) | (value >> (32 - bits))) & 0xFFFFFFFF;

  static void _quarterRound(List<int> s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] ^= s[a];
    s[d] = _rotl32(s[d], 16);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] ^= s[c];
    s[b] = _rotl32(s[b], 12);
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] ^= s[a];
    s[d] = _rotl32(s[d], 8);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] ^= s[c];
    s[b] = _rotl32(s[b], 7);
  }

  /// One 64-byte keystream block (RFC 8439 section 2.3).
  static Uint8List block(Uint8List key, int counter, Uint8List nonce) {
    if (key.length != kKeyLength) {
      throw ArgumentError('ChaCha20 key must be 32 bytes');
    }
    if (nonce.length != kNonceLength) {
      throw ArgumentError('ChaCha20 nonce must be 12 bytes');
    }
    final state = List<int>.filled(16, 0);
    for (var i = 0; i < 4; i++) {
      state[i] = _constants[i];
    }
    final keyWords = ByteData.sublistView(key);
    for (var i = 0; i < 8; i++) {
      state[4 + i] = keyWords.getUint32(i * 4, Endian.little);
    }
    state[12] = counter & 0xFFFFFFFF;
    final nonceWords = ByteData.sublistView(nonce);
    for (var i = 0; i < 3; i++) {
      state[13 + i] = nonceWords.getUint32(i * 4, Endian.little);
    }
    final working = List<int>.from(state);
    for (var i = 0; i < 10; i++) {
      // Column rounds.
      _quarterRound(working, 0, 4, 8, 12);
      _quarterRound(working, 1, 5, 9, 13);
      _quarterRound(working, 2, 6, 10, 14);
      _quarterRound(working, 3, 7, 11, 15);
      // Diagonal rounds.
      _quarterRound(working, 0, 5, 10, 15);
      _quarterRound(working, 1, 6, 11, 12);
      _quarterRound(working, 2, 7, 8, 13);
      _quarterRound(working, 3, 4, 9, 14);
    }
    final out = ByteData(64);
    for (var i = 0; i < 16; i++) {
      out.setUint32(i * 4, (working[i] + state[i]) & 0xFFFFFFFF, Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// Encrypts or decrypts [data] — identical operation for a stream cipher.
  static Uint8List xor(
    Uint8List key,
    Uint8List nonce,
    Uint8List data, {
    int counter = 0,
  }) {
    final out = Uint8List(data.length);
    var blockCounter = counter;
    for (var offset = 0; offset < data.length; offset += 64) {
      final keystream = block(key, blockCounter, nonce);
      blockCounter++;
      final end = (offset + 64).clamp(0, data.length);
      for (var i = offset; i < end; i++) {
        out[i] = data[i] ^ keystream[i - offset];
      }
    }
    return out;
  }
}

/// PBKDF2-HMAC-SHA256 key derivation (RFC 2898). The passphrase is UTF-8
/// encoded (matching the Python reference) so non-ASCII passphrases derive
/// the same key on both sides.
Uint8List deriveKey(String passphrase, Uint8List salt) {
  final password = Uint8List.fromList(utf8.encode(passphrase));
  final hmac = Hmac(sha256, password);
  // Block index 1, big-endian, appended to the salt.
  final firstInput = Uint8List(salt.length + 4)
    ..setAll(0, salt)
    ..setAll(salt.length, [0, 0, 0, 1]);
  var u = Uint8List.fromList(hmac.convert(firstInput).bytes);
  final derived = Uint8List.fromList(u);
  for (var i = 1; i < kPbkdf2Iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < derived.length; j++) {
      derived[j] ^= u[j];
    }
  }
  return derived;
}
