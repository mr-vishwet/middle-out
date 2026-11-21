import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Downloads [bytes] via a browser anchor element. Returns the file name.
Future<String> saveFileBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
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
