import 'dart:html' as html;
import 'dart:typed_data';

/// Downloads the PDF via a browser anchor element. Returns the file name.
Future<String> savePdf(Uint8List bytes, String fileName) async {
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(url);
  anchor.remove();
  return fileName;
}
