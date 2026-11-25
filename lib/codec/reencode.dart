/// Shared types for the 10:1 hard rule: the re-encode record, media
/// kind detection, and the [MediaReencoder] interface.
///
/// The record is the "frame manifest" for a re-encoded file: it is
/// carried on the encode result ([EncodeStats.reencode]), persisted in
/// the history record, printed on the PDF cover, and shown on the
/// result + decode screens. It is NOT stored in the frame headers —
/// the 100-byte v2 header has no room for it — so a PDF decoded on
/// another device only carries the [kFlagReencoded] bit: the decoder
/// knows the bytes are a re-encoded copy (and verifies them against
/// the header SHA, which describes the RE-ENCODED bytes), but the
/// original file's name/size/SHA are only visible on the cover and in
/// the encoding device's history. That is a deliberate, documented
/// limit — never present the original hash as the decoded hash.
library;

import 'dart:typed_data';

/// The 10:1 ratio target: the finished PDF must land at or below
/// `originalSize / kRatioTarget`.
const double kRatioTarget = 10.0;

/// Kind of media a file is, for the re-encode decision.
enum MediaKind {
  /// Video (mp4, webm, mov, ...).
  video,

  /// Still image (jpg, png, webp, ...).
  image,

  /// Audio (mp3, wav, ...). Re-encode only if it falls out naturally;
  /// never the reason to build an audio encoder.
  audio,

  /// Anything else (documents, archives, executables, unknown).
  other,
}

/// Detects a file's media kind from its extension, falling back to
/// magic bytes when the extension is missing or lying. Extension-only
/// when [bytes] is null (the picker often gives only a name).
MediaKind detectMediaKind(String fileName, [Uint8List? bytes]) {
  final lower = fileName.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot >= 0 ? lower.substring(dot + 1) : '';
  switch (ext) {
    case 'mp4':
    case 'm4v':
    case 'webm':
    case 'mov':
    case 'avi':
    case 'mkv':
      return MediaKind.video;
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'webp':
    case 'gif':
    case 'heic':
    case 'heif':
    case 'bmp':
      return MediaKind.image;
    case 'mp3':
    case 'wav':
    case 'ogg':
    case 'm4a':
    case 'flac':
      return MediaKind.audio;
  }
  if (bytes != null && bytes.length >= 12) {
    // ftyp box at offset 4: MP4/MOV.
    if (bytes[4] == 0x66 && // f
        bytes[5] == 0x74 && // t
        bytes[6] == 0x79 && // y
        bytes[7] == 0x70) {
      return MediaKind.video;
    }
    // WebM/Matroska EBML header.
    if (bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF &&
        bytes[3] == 0xA3) {
      return MediaKind.video;
    }
    // JPEG / PNG / WebP.
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return MediaKind.image;
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 && // P
        bytes[2] == 0x4E && // N
        bytes[3] == 0x47) {
      return MediaKind.image;
    }
    if (bytes.length >= 12 &&
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50) {
      return MediaKind.image;
    }
  }
  return MediaKind.other;
}

/// The record of a lossy re-encode, kept with the encode result.
///
/// [originalSha256Hex] is the SHA-256 of the ORIGINAL file; the frame
/// headers carry the SHA-256 of the RE-ENCODED bytes instead. The two
/// must never be confused in the UI: the decoded file verifies against
/// the header hash, and the original hash is shown only as "the file
/// this copy was made from".
class ReencodeRecord {
  /// Creates a re-encode record.
  const ReencodeRecord({
    required this.originalName,
    required this.originalSizeBytes,
    required this.originalSha256Hex,
    required this.mediaKind,
    required this.encoder,
    required this.settingsLabel,
    required this.reencodedSizeBytes,
    required this.reencodedSha256Hex,
    required this.targetPdfBytes,
  });

  /// Name of the original file.
  final String originalName;

  /// Bytes of the original file.
  final int originalSizeBytes;

  /// SHA-256 hex of the original file.
  final String originalSha256Hex;

  /// What kind of media was re-encoded.
  final MediaKind mediaKind;

  /// Encoder used, e.g. 'WebCodecs avc1' or 'canvas JPEG'.
  final String encoder;

  /// Human-readable settings, e.g. '640x360 @ 400 kbps, 24 fps'.
  /// Shown on the pre-encode proposal so the user confirms the
  /// quality before anything runs.
  final String settingsLabel;

  /// Bytes of the re-encoded media (the bytes that were framed).
  final int reencodedSizeBytes;

  /// SHA-256 hex of the re-encoded media (== the frame headers' SHA).
  final String reencodedSha256Hex;

  /// PDF size the re-encode was budgeted for (<= original / 10).
  final int targetPdfBytes;

  /// Ratio the re-encode achieved (original / re-encoded).
  double get ratio => originalSizeBytes / reencodedSizeBytes.clamp(1, reencodedSizeBytes);

  /// Serialises to JSON (history persistence).
  Map<String, dynamic> toJson() => {
        'originalName': originalName,
        'originalSizeBytes': originalSizeBytes,
        'originalSha256Hex': originalSha256Hex,
        'mediaKind': mediaKind.name,
        'encoder': encoder,
        'settingsLabel': settingsLabel,
        'reencodedSizeBytes': reencodedSizeBytes,
        'reencodedSha256Hex': reencodedSha256Hex,
        'targetPdfBytes': targetPdfBytes,
      };

  /// Deserialises from JSON (missing/invalid fields -> null).
  static ReencodeRecord? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final kindName = json['mediaKind'] as String?;
      final kind = MediaKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => MediaKind.other,
      );
      return ReencodeRecord(
        originalName: json['originalName'] as String,
        originalSizeBytes: json['originalSizeBytes'] as int,
        originalSha256Hex: json['originalSha256Hex'] as String,
        mediaKind: kind,
        encoder: json['encoder'] as String,
        settingsLabel: json['settingsLabel'] as String,
        reencodedSizeBytes: json['reencodedSizeBytes'] as int,
        reencodedSha256Hex: json['reencodedSha256Hex'] as String,
        targetPdfBytes: json['targetPdfBytes'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Quality floor for re-encoding: the worst quality the app will
/// produce. Below this the output is mush, and the encode must fail
/// honestly ("even the lowest quality can't reach 10:1 for this file")
/// instead of shipping it.
///
/// Video floor: 320x180, 50 kbps video. Set by the WebCodecs spike
/// plus Worker B's corrected budget math (2026-11-25): the brief's
/// flat "input/13.3" media budget is WRONG — a 1-data-page encode
/// carries the stream twice (1 data + 1 parity frame), so the PDF is
/// ~2.08x the media, not 1.33x. The true media budget for the 3.1 MB
/// Sintel clip is 142,519 B (modelled PDF 303,084 <= 310,555), not
/// 233,501 B. Against the true budget, the spike's 240p @ 75 kbps
/// (187,804 B) is 1.32x OVER — only ~50 kbps fits (extrapolated
/// 240p@50k ~= 125 KB, from the spike's accurate low-res rate
/// tracking: 75k->74.8k, 100k->93.8k). 50 kbps at 240p is soft but
/// recognizable; 320x180 is the resolution floor for the same reason
/// (fewer pixels, more bits each). Below this the output is mush,
/// and the encode must fail honestly ("even the lowest quality can't
/// reach 10:1 for this file") instead of shipping it. The proposal
/// screen always shows the exact settings, so the user confirms the
/// quality with eyes open. Audio is re-encoded at low bitrate where
/// the encoder supports it and dropped (labelled) where it does not —
/// audio is never the reason to fail.
/// Image floor: JPEG quality 35, longest edge 640 px.
class ReencodeQualityFloor {
  /// Minimum video width in pixels.
  static const int minVideoWidth = 320;

  /// Minimum video height in pixels.
  static const int minVideoHeight = 180;

  /// Minimum video bitrate in bits per second.
  static const int minVideoBitrate = 50000;

  /// Minimum JPEG quality (0-100) for image re-encode.
  static const int minJpegQuality = 35;

  /// Minimum longest edge in pixels for image re-encode.
  static const int minImageLongestEdge = 640;
}

/// Progress callback for a re-encode: [fraction] 0..1 and a label.
typedef ReencodeProgress = void Function(double fraction, String label);

/// The result of a media re-encode: the new bytes plus how they were
/// made (for the proposal screen and the record).
class ReencodedMedia {
  /// Creates re-encoded media.
  const ReencodedMedia({
    required this.bytes,
    required this.kind,
    required this.encoder,
    required this.settingsLabel,
  });

  /// The re-encoded media bytes.
  final Uint8List bytes;

  /// What kind of media this is.
  final MediaKind kind;

  /// Encoder used, e.g. 'WebCodecs avc1'.
  final String encoder;

  /// Human-readable settings, e.g. '640x360 @ 400 kbps, 24 fps'.
  final String settingsLabel;
}

/// The plan for a re-encode: what the encoder WILL do, described
/// before anything runs, so the pre-encode proposal can show the
/// quality settings the user is confirming.
class ReencodePlan {
  /// Creates a re-encode plan.
  const ReencodePlan({
    required this.encoder,
    required this.settingsLabel,
  });

  /// Encoder that would run, e.g. 'WebCodecs avc1'.
  final String encoder;

  /// Human-readable settings, e.g. '640x360 @ 400 kbps, 24 fps'.
  final String settingsLabel;
}

/// Re-encodes media to a target size. Implemented per platform:
/// WebCodecs on web (see `media_reencoder_web.dart`), stub elsewhere
/// that reports honestly that re-encoding is unavailable.
///
/// The caller (the encode controller) decides WHETHER to re-encode
/// (the ratio engine); this service only decides HOW and reports the
/// honest result. It never silently returns the input unchanged:
/// when the media cannot be shrunk to [targetBytes] even at the
/// quality floor it throws [ReencodeException] with the reason.
abstract class MediaReencoder {
  /// True when this platform can re-encode at all.
  bool get isAvailable;

  /// Human-readable name of the active encoder ('WebCodecs avc1',
  /// 'canvas JPEG', ...). Empty when unavailable.
  String get encoderName;

  /// Describes the re-encode that WOULD run for [bytes] at
  /// [targetBytes], without running it — the proposal screen shows
  /// [ReencodePlan.settingsLabel] so the user confirms the quality
  /// before anything runs. Returns null when the encoder cannot plan
  /// ahead (the proposal then shows a generic line, and the real
  /// settings are reported by [reencode] instead). The default
  /// implementation returns null; override it when the encoder can
  /// describe its settings up front. Implementations using
  /// `implements` must stub this to return null.
  Future<ReencodePlan?> plan(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
  }) async =>
      null;

  /// Re-encodes [bytes] ([fileName] for kind detection) down to at
  /// most [targetBytes], iterating the bitrate/quality until the
  /// output fits or the quality floor is reached. Returns null when
  /// the file is not re-encodable media (kind [MediaKind.other] or
  /// [MediaKind.audio] without a video track to carry it).
  Future<ReencodedMedia?> reencode(
    Uint8List bytes,
    String fileName, {
    required int targetBytes,
    ReencodeProgress? onProgress,
  });
}

/// Thrown when a re-encode cannot meet its target, with the reason
/// for the UI (shown verbatim, so keep it plain).
class ReencodeException implements Exception {
  /// Creates a re-encode failure.
  const ReencodeException(this.message);

  /// Plain-language reason.
  final String message;

  @override
  String toString() => message;
}
