import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// System share sheet: encoded PDFs, rebuilt files, links and text.
///
/// Sharing hands bytes to the OS share sheet — nothing is uploaded by
/// Middle Out itself. On web the browser's share UI is used where the
/// platform supports it.
abstract final class ShareService {
  /// Shares an encoded PDF.
  static Future<void> sharePdf(Uint8List bytes, String fileName) =>
      shareBytes(bytes, fileName, 'application/pdf');

  /// Shares arbitrary bytes with a [mimeType].
  static Future<void> shareBytes(
    Uint8List bytes,
    String fileName,
    String mimeType,
  ) async {
    final file = XFile.fromData(
      bytes,
      name: fileName,
      mimeType: mimeType,
    );
    await Share.shareXFiles([file], subject: fileName);
  }

  /// Shares plain text (the payoff story, a link URL).
  static Future<void> shareText(String text, {String? subject}) async {
    await Share.share(text, subject: subject);
  }
}
