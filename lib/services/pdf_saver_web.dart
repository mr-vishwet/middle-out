import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downloads the PDF via a browser anchor element. Returns the file name.
Future<String> savePdf(Uint8List bytes, String fileName) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..click();
  web.URL.revokeObjectURL(url);
  anchor.remove();
  return fileName;
}
