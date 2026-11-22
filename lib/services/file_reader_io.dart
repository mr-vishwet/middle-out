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

/// Reads up to [maxBytes] starting at byte [offset] of the file at
/// [path], for multi-sample estimates (head / middle / tail). Returns an
/// empty list when [offset] is past the end of the file.
Future<Uint8List> readFileRange(
  String path,
  int offset,
  int maxBytes,
) async {
  final file = File(path);
  final raf = await file.open();
  try {
    final length = await raf.length();
    if (offset >= length) return Uint8List(0);
    await raf.setPosition(offset);
    final remaining = length - offset;
    final count = remaining < maxBytes ? remaining : maxBytes;
    return await raf.read(count);
  } finally {
    await raf.close();
  }
}
