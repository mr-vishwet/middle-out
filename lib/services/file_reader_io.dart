import 'dart:io';
import 'dart:typed_data';

/// Reads the file at [path] into memory. Callers enforce the platform
/// limit BEFORE calling this — a file larger than the mode allows is
/// never read.
Future<Uint8List> readPickedFile(String path) => File(path).readAsBytes();
