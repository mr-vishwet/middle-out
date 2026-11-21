import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'file_reader.dart';
import 'platform_limits.dart';

/// Thrown when a picked file exceeds the current mode's limit. The message
/// already contains the routing advice (which mode can hold it).
class FileTooLargeException implements Exception {
  const FileTooLargeException(this.message);
  final String message;
  @override
  String toString() => 'FileTooLargeException: $message';
}

/// A picked file, with its bytes loaded (limit-checked before reading).
class PickedFile {
  const PickedFile({required this.name, required this.size, required this.bytes});
  final String name;
  final int size;
  final Uint8List bytes;
}

/// File picking + limit-gated reading.
///
/// The platform limit is enforced BEFORE the bytes are read: a file larger
/// than the mode allows is never loaded into memory — the picker reports
/// the routing advice instead.
class FilePickerService {
  /// Opens the system picker. Returns null when the user cancels.
  /// Throws [FileTooLargeException] when the file exceeds [mode]'s limit.
  Future<PickedFile?> pickFile(EncodeMode mode) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: kIsWeb, // web has no file path; read bytes directly
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (!PlatformLimitsService.fits(file.size, mode)) {
      throw FileTooLargeException(
        PlatformLimitsService.overLimitAdvice(file.size, mode),
      );
    }
    final Uint8List bytes;
    if (file.bytes != null) {
      bytes = file.bytes!;
    } else if (file.path != null) {
      bytes = await readPickedFile(file.path!);
    } else {
      throw const FileTooLargeException('Could not read the picked file.');
    }
    return PickedFile(name: file.name, size: file.size, bytes: bytes);
  }
}
