import 'dart:html' as html;
import 'dart:typed_data';

/// Downloads [bytes] via a browser anchor element. Returns the file name.
Future<String> saveFileBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(url);
  anchor.remove();
  return fileName;
}
