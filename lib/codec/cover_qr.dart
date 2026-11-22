import 'dart:convert';
import 'dart:typed_data';

/// The scannable QR code printed on every encoded PDF's cover.
///
/// A real ISO QR code (version 3, 29x29 modules, error-correction level
/// M) encoding the Middle Out web app URL — any phone camera can scan
/// it, unlike the custom Middle Out Code grids on the code pages, which
/// only the app reads.
///
/// The modules are packed row-major, MSB first, 1 = black (29x29 = 841
/// bits = 106 bytes). The cover draws it with a 4-module quiet zone —
/// REQUIRED: a QR without a quiet zone fails to scan (verified: OpenCV's
/// QRCodeDetector returns nothing without one and decodes the exact URL
/// with one).
///
/// Generated at development time by a throwaway script (Python `qrcode`,
/// version 3, ECL M, `box_size=1`, `border=0`) and verified decodable by
/// OpenCV to [url]. The codec stays dependency-free: no QR encoder at
/// runtime, just this const.
abstract final class CoverQr {
  /// The URL the QR code encodes.
  static const String url = 'https://mr-vishwet.github.io/middle-out/';

  /// QR edge in modules (version 3 is 29x29).
  static const int size = 29;

  /// Packed modules (row-major, MSB first, 1 = black), base64-encoded.
  /// 29x29 modules = 841 bits = 106 bytes.
  static const String base64Modules =
      '/iIj/Bd1EG6+6rt1y4XbpaGuwTVFB/qqr+AaUACCn1Z2SsmNntjbgclhe4l4K6DsQv/NXB0X'
      'jYYGpWORUGdm75Xzyn9Ta5kRCno0+4BJvGP4Z2uQREMQuj6/1dIfq26Z9P0EZA/f70UyAA==';

  /// Decoded packed bytes, cached after first use.
  static final Uint8List bytes = base64Decode(base64Modules);

  /// The QR as a [size] x [size] module matrix (0 = white, 1 = black),
  /// unpacked from [bytes].
  static List<Uint8List> get modules {
    final rows = List<Uint8List>.generate(size, (_) => Uint8List(size));
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        final i = r * size + c;
        rows[r][c] = (bytes[i ~/ 8] >> (7 - i % 8)) & 1;
      }
    }
    return rows;
  }
}
