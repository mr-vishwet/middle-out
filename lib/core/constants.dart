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

/// Frame format version. Encoders write this version; decoders accept it
/// and v1 (see [kHeaderSizeV1]) so PDFs encoded before the v2 widening
/// still decode.
const int kFrameVersion = 2;

/// Fixed header size in bytes (v2). Layout (all integers big-endian):
///
/// ```
///  0..3    magic            "MO01"
///  4       version          2
///  5..6    frameIndex       global index of this frame in the encode (uint16)
///  7       kind             0 = DATA, 1 = PARITY
///  8..9    groupIndex       which 8-frame group this frame belongs to (uint16)
/// 10       slot             0..7 position inside its group (0-5 DATA, 6-7 PARITY)
/// 11       flags            bit0 = encrypted, bit1 = last group, bit2 = barcode
/// 12..13   totalGroups      number of 8-frame groups in the encode (uint16)
/// 14..15   totalDataFrames  number of DATA frames in the encode (uint16)
/// 16..19   payloadLength    bytes of payload in this frame (uint32)
/// 20..27   originalSize     bytes of the original file (uint64)
/// 28..35   compressedSize   bytes of the compressed (and encrypted, if
///                           flagged) stream (uint64)
/// 36..67   originalSha256   SHA-256 of the original file
/// 68..83   salt             PBKDF2 salt, 16 bytes (zero when not encrypted)
/// 84..95   nonce            ChaCha20 nonce, 12 bytes (zero when not encrypted)
/// 96..99   headerCrc        CRC32 of header bytes 0..95
/// ```
///
/// The payload follows the header, then a 4-byte CRC32 of the payload.
/// Frame total size = [kHeaderSize] + payloadLength + 4.
///
/// v2 widened frameIndex, groupIndex and totalGroups from uint8 to uint16:
/// a v1 frame could only address 256 frames, and a real 67 MB mp4 already
/// needs 1,125. The magic and version keep their positions so a parser
/// can tell v1 from v2 from the first five bytes.
const int kHeaderSize = 100;

/// v1 header size in bytes. v1 layout: frameIndex @5, kind @6, groupIndex
/// @7, slot @8, flags @9, totalGroups @10 (all uint8), totalDataFrames
/// @11..12, payloadLength @13..16, originalSize @17..24, compressedSize
/// @25..32, SHA-256 @33..64, salt @65..80, nonce @81..92, header CRC
/// @93..96. Decoders still parse it; encoders never write it.
const int kHeaderSizeV1 = 97;

/// Frame kind: a data frame carrying compressed-stream bytes.
const int kFrameKindData = 0;

/// Frame kind: a parity frame carrying XOR recovery bytes.
const int kFrameKindParity = 1;

/// Flag: the payload is ChaCha20-encrypted.
const int kFlagEncrypted = 0x01;

/// Flag: this frame is in the last parity group.
const int kFlagLastGroup = 0x02;

/// Set when the frames were rendered as bar-grid barcodes rather than
/// 2D grids. Recorded so the decode UI knows which scanner to offer; the
/// image parser itself auto-detects by aspect ratio.
const int kFlagBarcode = 0x04;

/// Frames per group: 6 DATA + 2 PARITY. Every group is exactly 8 frames so
/// the encoded PDF layout is uniform (1 cover + 8 pages per group).
const int kGroupDataFrames = 6;

/// Parity frames per group (slots 6 and 7).
const int kGroupParityFrames = 2;

/// Total frames per group (data + parity).
const int kGroupSize = kGroupDataFrames + kGroupParityFrames;

/// Parity slot 6 protects data slots 0, 1, 2; parity slot 7 protects
/// slots 3, 4, 5. Each trio can lose any ONE frame and still recover.
const List<int> kParityATrio = [0, 1, 2];

/// Data slots protected by parity slot 7.
const List<int> kParityBTrio = [3, 4, 5];

/// Group slot of the parity frame protecting [kParityATrio].
const int kParityASlot = 6;

/// Group slot of the parity frame protecting [kParityBTrio].
const int kParityBSlot = 7;

/// Default maximum payload per frame (64 KiB). Sized for reliable scanning
/// of a full-page code at print resolution — see README "Honest limits".
const int kDefaultMaxPayload = 65536;

/// Maximum frames in one encode.
///
/// This is a policy guardrail, not a format limit: v2 widened frameIndex
/// to uint16, so the format itself can address 65,535 frames, and this
/// cap can be raised later without another format change. 4096 covers the
/// 1 GB hero case (~300 frames) 13x over and the largest real-world
/// report so far (a 67 MB mp4 needing 1,125 frames) 3.6x over, while
/// bounding the PDF at ~250 MB (4,096 full-page codes) and in-memory
/// frame payloads at ~256 MB. Beyond that the PDF itself is unusable, and
/// the estimate screen warns before encoding starts.
const int kMaxFrames = 4096;

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

/// Maximum encoded-PDF size per GB of input (20 MB).
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
  /// Demo file name shown in the seeded demo.
  static const String fileName = 'Podcast — Ep. 14 Master.wav';

  /// Demo original size in bytes (1.04 GB).
  static const int originalBytes = 1040000000; // 1.04 GB

  /// Demo encoded-PDF size in bytes (14.2 MB).
  static const int encodedBytes = 14200000; // 14.2 MB

  /// Demo compression ratio label.
  static const String ratioLabel = '73×';

  /// Demo SHA-256 prefix shown on the cover (not a real hash).
  static const String sha256Prefix = '9f2c41be 7d03a81d 5c19e2f4 08b6d3a7';

  /// Demo data frame count.
  static const int dataFrames = 6;

  /// Demo parity frame count.
  static const int parityFrames = 2;

  /// Demo frame sizes in MB (6 DATA frames summing to 1,040 MB).
  static const List<int> frameSizesMb = [174, 173, 174, 173, 173, 173];
}
