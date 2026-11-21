import 'dart:io';
import 'dart:typed_data';

/// Reads the file at [path] into memory. Callers enforce the platform
/// limit BEFORE calling this — a file larger than the mode allows is
/// never read.
Future<Uint8List> readPickedFile(String path) => File(path).readAsBytes();

/// Reads the first [maxBytes] of the file at [path], for estimates.
/// Never reads more than [maxBytes], however large the file is.
Future<Uint8List> readFileHead(String path, int maxBytes) async {
  final file = File(path);
  final raf = await file.open();
  try {
    final length = await raf.length();
    final count = length < maxBytes ? length : maxBytes;
    return await raf.read(count);
  } finally {
    await raf.close();
  }
}
