import 'dart:typed_data';

/// Web has no file paths — picks carry bytes. This should never be called.
Future<Uint8List> readPickedFile(String path) async {
  throw UnsupportedError('No file paths on this platform.');
}

/// Web has no file paths — picks carry bytes. This should never be called.
Future<Uint8List> readFileHead(String path, int maxBytes) async {
  throw UnsupportedError('No file paths on this platform.');
}

/// Web has no file paths — picks carry bytes. This should never be called.
Future<Uint8List> readFileRange(
  String path,
  int offset,
  int maxBytes,
) async {
  throw UnsupportedError('No file paths on this platform.');
}
