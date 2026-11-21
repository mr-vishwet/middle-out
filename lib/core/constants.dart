/// Canonical constants for the Middle Out codec, platform limits and the
/// seeded demo fixture.
///
/// The wire format defined here is shared byte-for-byte with the Python
/// reference implementation in `reference/codec_reference.py`. Change one,
/// change the other, and re-run both test suites.
library;

/// ---------------------------------------------------------------------------
/// Frame wire format
/// ---------------------------------------------------------------------------

/// Magic bytes at the start of every frame: ASCII "MO01".
const List<int> kFrameMagic = [0x4D, 0x4F, 0x30, 0x31];

/// Frame format version. Decoders must reject any other version.
const int kFrameVersion = 1;

/// Fixed header size in bytes. Layout (all integers big-endian):
///
/// ```
///  0..3    magic            "MO01"
///  4       version          1
///  5       frameIndex       global index of this frame in the encode
///  6       kind             0 = DATA, 1 = PARITY
///  7       groupIndex       which 8-frame group this frame belongs to
///  8       slot             0..7 position inside its group (0-5 DATA, 6-7 PARITY)
///  9       flags            bit0 = encrypted, bit1 = last group
/// 10       totalGroups      number of 8-frame groups in the encode
/// 11..12   totalDataFrames  number of DATA frames in the encode (uint16)
/// 13..16   payloadLength    bytes of payload in this frame (uint32)
/// 17..24   originalSize     bytes of the original file (uint64)
/// 25..32   compressedSize   bytes of the compressed (and encrypted, if
///                           flagged) stream (uint64)
/// 33..64   originalSha256   SHA-256 of the original file
/// 65..80   salt             PBKDF2 salt, 16 bytes (zero when not encrypted)
/// 81..92   nonce            ChaCha20 nonce, 12 bytes (zero when not encrypted)
/// 93..96   headerCrc        CRC32 of header bytes 0..92
/// ```
///
/// The payload follows the header, then a 4-byte CRC32 of the payload.
/// Frame total size = [kHeaderSize] + payloadLength + 4.
const int kHeaderSize = 97;

/// Frame kinds.
const int kFrameKindData = 0;
const int kFrameKindParity = 1;

/// Flags.
const int kFlagEncrypted = 0x01;
const int kFlagLastGroup = 0x02;

/// Set when the frames were rendered as stacked-row barcodes rather than
/// 2D grids. Recorded so the decode UI knows which scanner to offer; the
/// image parser itself auto-detects by aspect ratio.
const int kFlagBarcode = 0x04;

/// Frames per group: 6 DATA + 2 PARITY. Every group is exactly 8 frames so
/// the encoded PDF layout is uniform (1 cover + 8 pages per group).
const int kGroupDataFrames = 6;
const int kGroupParityFrames = 2;
const int kGroupSize = kGroupDataFrames + kGroupParityFrames;

/// Parity slot 6 protects data slots 0, 1, 2; parity slot 7 protects
/// slots 3, 4, 5. Each trio can lose any ONE frame and still recover.
const List<int> kParityATrio = [0, 1, 2];
const List<int> kParityBTrio = [3, 4, 5];
const int kParityASlot = 6;
const int kParityBSlot = 7;

/// Default maximum payload per frame (64 KiB). Sized for reliable scanning
/// of a full-page code at print resolution — see README "Honest limits".
const int kDefaultMaxPayload = 65536;

/// Maximum frames in one encode (frameIndex is a single byte).
const int kMaxFrames = 256;

/// ---------------------------------------------------------------------------
/// Encryption (ChaCha20, RFC 8439 — pure Dart, no platform dependency)
/// ---------------------------------------------------------------------------

/// PBKDF2-HMAC-SHA256 iterations for passphrase -> key derivation.
const int kPbkdf2Iterations = 100000;

/// Salt length in bytes.
const int kSaltLength = 16;

/// ChaCha20 nonce length in bytes (96-bit nonce, 32-bit counter).
const int kNonceLength = 12;

/// ChaCha20 key length in bytes.
const int kKeyLength = 32;

/// ---------------------------------------------------------------------------
/// Platform limits (per the V7 product spec)
/// ---------------------------------------------------------------------------

/// Maximum single-file size per encode mode, in bytes.
class PlatformLimits {
  /// Native app: 100 GB per file (streaming, local).
  static const int nativeMaxBytes = 100 * 1024 * 1024 * 1024;

  /// Web, local mode: 10 GB (in-browser, no upload).
  static const int webLocalMaxBytes = 10 * 1024 * 1024 * 1024;

  /// Web, cloud mode: 50 GB (resumable chunked upload).
  static const int webCloudMaxBytes = 50 * 1024 * 1024 * 1024;
}

/// The encoded PDF for a 1 GB input must land in this band — never hundreds
/// of MB. v0.1 enforces it as a post-encode check and surfaces a warning
/// when a pathological input (already-compressed or random data) would
/// exceed it.
const int kPdfSizeMinPerGb = 5 * 1024 * 1024;
const int kPdfSizeMaxPerGb = 20 * 1024 * 1024;

/// ---------------------------------------------------------------------------
/// Demo fixture (SEEDED DEMO CONTENT — labelled as demo everywhere it shows)
///
/// The 1.04 GB podcast master is the product's demo story from the V7
/// design. Real compression ratios depend entirely on the input: a WAV of
/// silence compresses enormously, an encrypted zip barely at all. The demo
/// numbers below are NEVER presented as a measured encode.
/// ---------------------------------------------------------------------------

class DemoFixture {
  static const String fileName = 'Podcast — Ep. 14 Master.wav';
  static const int originalBytes = 1040000000; // 1.04 GB
  static const int encodedBytes = 14200000; // 14.2 MB
  static const String ratioLabel = '73×';
  static const String sha256Prefix = '9f2c41be 7d03a81d 5c19e2f4 08b6d3a7';
  static const int dataFrames = 6;
  static const int parityFrames = 2;

  /// Demo frame sizes in MB (6 DATA frames summing to 1,040 MB).
  static const List<int> frameSizesMb = [174, 173, 174, 173, 173, 173];
}
