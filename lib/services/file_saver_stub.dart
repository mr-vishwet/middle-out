import 'dart:typed_data';

/// No file saving on this platform.
Future<String> saveFileBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  throw UnsupportedError('File saving is not supported on this platform.');
}
