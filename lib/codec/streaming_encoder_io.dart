import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/constants.dart';
import 'chacha20.dart';
import 'encoder.dart';

/// Progress callback for streaming encodes: [fraction] 0..1 and a
/// human-readable stage label.
typedef StreamingProgress = void Function(double fraction, String label);

/// Streaming encode for native platforms.
///
/// Two passes over the file, neither of which loads it whole:
/// 1. Read the file in 1 MiB chunks, hashing (SHA-256) and compressing
///    (zlib-9) incrementally; the compressed stream is encrypted
///    incrementally (ChaCha20, 64-byte block aligned) and written to a
///    temp file, which is deleted afterwards.
/// 2. Read the temp file back in [maxPayload] chunks and frame it with
///    [Encoder.buildFrames] — identical framing to the in-memory path.
///
/// Peak memory is bounded by the chunk size plus one frame, not the file
/// size. The PDF assembly afterwards ([PdfDocument.build]) still holds
/// the PDF in memory — full frame-at-a-time PDF streaming is phase 2.
class StreamingEncoder {
  /// True on platforms with file access.
  static bool get isSupported => true;

  /// Chunks read off disk per pass (1 MiB).
  static const int chunkSize = 1024 * 1024;

  /// Encodes the file at [path]. Pass [passphrase] to encrypt.
  /// Reports progress via [onProgress] when given.
  static Future<EncodeResult> encodeFile({
    required String path,
    String? passphrase,
    int maxPayload = kDefaultMaxPayload,
    bool barcode = false,
    StreamingProgress? onProgress,
  }) async {
    final file = File(path);
    final originalSize = await file.length();
    final tempDir = await Directory.systemTemp.createTemp('middleout-');
    final tempFile = File('${tempDir.path}/stream.bin');
    try {
      // --- Pass 1: hash + compress + encrypt to a temp file. ---
      final hashSink = AccumulatorSink<Digest>();
      final hashConverter = sha256.startChunkedConversion(hashSink);
      final encrypted = passphrase != null;
      final Uint8List salt;
      final Uint8List nonce;
      final Uint8List key;
      if (encrypted) {
        final random = Random.secure();
        salt = Uint8List.fromList(
          List<int>.generate(kSaltLength, (_) => random.nextInt(256)),
        );
        nonce = Uint8List.fromList(
          List<int>.generate(kNonceLength, (_) => random.nextInt(256)),
        );
        key = deriveKey(passphrase, salt);
      } else {
        salt = Uint8List(kSaltLength);
        nonce = Uint8List(kNonceLength);
        key = Uint8List(0);
      }
      final raf = tempFile.openSync(mode: FileMode.write);
      final encryptor = _BlockEncryptor(
        key: key,
        nonce: nonce,
        enabled: encrypted,
        onEncrypted: raf.writeFromSync,
      );
      final zlibSink = _ZlibSink(encryptor.add);
      final zlibConverter =
          ZLibEncoder(level: 9).startChunkedConversion(zlibSink);
      var compressedSize = 0;
      encryptor.onEncryptedLength = (n) => compressedSize += n;

      final input = file.openSync();
      try {
        var read = 0;
        while (true) {
          final chunk = input.readSync(chunkSize);
          if (chunk.isEmpty) break;
          hashConverter.add(chunk);
          zlibConverter.add(chunk);
          read += chunk.length;
          onProgress?.call(
            0.5 * read / originalSize.clamp(1, originalSize),
            'Compressing…',
          );
          // Yield so progress paints on large files.
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        input.closeSync();
      }
      hashConverter.close();
      zlibConverter.close();
      encryptor.finish();
      raf.closeSync();
      final sha = Uint8List.fromList(hashSink.events.single.bytes);

      // --- Pass 2: frame the temp file. ---
      onProgress?.call(0.55, 'Framing…');
      final chunks = <Uint8List>[];
      final streamIn = tempFile.openSync();
      try {
        var framed = 0;
        while (true) {
          final chunk = streamIn.readSync(maxPayload);
          if (chunk.isEmpty) break;
          chunks.add(chunk);
          framed += chunk.length;
          onProgress?.call(
            0.55 + 0.35 * framed / compressedSize.clamp(1, compressedSize),
            'Framing…',
          );
        }
      } finally {
        streamIn.closeSync();
      }
      if (chunks.isEmpty) chunks.add(Uint8List(0));
      final frames = Encoder.buildFrames(
        chunks: chunks,
        sha256Bytes: sha,
        originalSize: originalSize,
        compressedSize: compressedSize,
        salt: salt,
        nonce: nonce,
        encrypted: encrypted,
        barcode: barcode,
      );
      final totalGroups =
          (chunks.length + kGroupDataFrames - 1) ~/ kGroupDataFrames;
      onProgress?.call(0.95, 'Framing…');
      return EncodeResult(
        frames: frames,
        stats: EncodeStats(
          originalSize: originalSize,
          compressedSize: compressedSize,
          frameCount: frames.length,
          groupCount: totalGroups,
          sha256Hex:
              sha.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        ),
        barcode: barcode,
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }
}

/// Collects zlib output chunks and forwards them to [onChunk].
class _ZlibSink extends ByteConversionSink {
  /// Creates a zlib sink forwarding to [onChunk].
  _ZlibSink(this.onChunk);

  /// Called with each compressed chunk.
  final void Function(List<int> chunk) onChunk;

  @override
  void add(List<int> chunk) => onChunk(chunk);

  @override
  void close() {}
}

/// Encrypts a byte stream incrementally with ChaCha20, keeping the
/// keystream aligned to 64-byte blocks across chunk boundaries.
///
/// ChaCha20 block N covers stream bytes [N*64, N*64+64); a chunk that
/// starts mid-block must continue the previous block's keystream. This
/// class buffers a partial tail and only encrypts whole blocks until
/// [finish], which encrypts the final partial block.
class _BlockEncryptor {
  /// Creates an incremental encryptor.
  _BlockEncryptor({
    required this.key,
    required this.nonce,
    required this.enabled,
    required this.onEncrypted,
  });

  /// ChaCha20 key (empty when [enabled] is false).
  final Uint8List key;

  /// ChaCha20 nonce (zeroed when [enabled] is false).
  final Uint8List nonce;

  /// False for plain encodes — bytes pass through unencrypted.
  final bool enabled;

  /// Called with each encrypted (or plain) output chunk.
  final void Function(List<int> chunk) onEncrypted;

  /// Called with the length of each output chunk (for size accounting).
  void Function(int length)? onEncryptedLength;

  final _pending = BytesBuilder();
  var _pendingLength = 0;
  var _blockCounter = 0;

  /// Feeds compressed bytes in.
  void add(List<int> chunk) {
    _pending.add(chunk);
    _pendingLength += chunk.length;
    final whole = _pendingLength ~/ 64 * 64;
    if (whole == 0) return;
    final buffered = _pending.toBytes();
    final out = enabled
        ? ChaCha20.xor(
            key,
            nonce,
            Uint8List.sublistView(buffered, 0, whole),
            counter: _blockCounter,
          )
        : Uint8List.sublistView(buffered, 0, whole);
    _blockCounter += whole ~/ 64;
    onEncrypted(out);
    onEncryptedLength?.call(out.length);
    // Keep the partial tail for the next chunk.
    final tail = Uint8List.sublistView(buffered, whole);
    _pending.clear();
    _pending.add(tail);
    _pendingLength = tail.length;
  }

  /// Encrypts the final partial block (if any) and flushes.
  void finish() {
    if (_pendingLength == 0) return;
    final buffered = _pending.toBytes();
    final out = enabled
        ? ChaCha20.xor(key, nonce, buffered, counter: _blockCounter)
        : buffered;
    _blockCounter += (buffered.length + 63) ~/ 64;
    onEncrypted(out);
    onEncryptedLength?.call(out.length);
    _pending.clear();
    _pendingLength = 0;
  }
}
