import 'dart:typed_data';

/// Fallback for platforms with no saver: reports that saving is unavailable.
Future<String> savePdf(Uint8List bytes, String fileName) async {
  throw UnsupportedError('Saving PDFs is not supported on this platform.');
}
