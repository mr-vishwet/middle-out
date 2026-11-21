import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'file_reader.dart';
import 'platform_limits.dart';

/// Thrown when a picked file exceeds the current mode's limit. The message
/// already contains the routing advice (which mode can hold it).
class FileTooLargeException implements Exception {
  /// Creates an over-limit error with routing advice in [message].
  const FileTooLargeException(this.message);

  /// Human-readable message, including which mode can hold the file.
  final String message;
  @override
  String toString() => 'FileTooLargeException: $message';
}

/// A picked file, as a reference — bytes are loaded lazily.
///
/// On native platforms the file is referenced by [path] and read only
/// when needed (or streamed, for large files); on web there is no path,
/// so [bytes] is loaded by the picker. The platform limit is enforced
/// BEFORE any bytes are read.
class PickedRef {
  /// Creates a picked-file reference.
  const PickedRef({
    required this.name,
    required this.size,
    this.path,
    this.bytes,
  });

  /// File name.
  final String name;

  /// File size in bytes.
  final int size;

  /// Native file path (null on web).
  final String? path;

  /// File bytes (set on web; null on native until read).
  final Uint8List? bytes;

  /// True when the bytes are already in memory.
  bool get hasBytes => bytes != null;

  /// True when the file can be read or streamed from disk.
  bool get hasPath => path != null;
}

/// File picking + limit-gated reading.
///
/// The platform limit is enforced BEFORE the bytes are read: a file larger
/// than the mode allows is never loaded into memory — the picker reports
/// the routing advice instead.
class FilePickerService {
  /// Opens the system picker for one file. Returns null on cancel.
  /// Throws [FileTooLargeException] when the file exceeds [mode]'s limit.
  Future<PickedRef?> pickFileMeta(EncodeMode mode) async {
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
    return PickedRef(name: file.name, size: file.size, path: file.path, bytes: file.bytes);
  }

  /// Opens the system picker for several files (batch queue).
  /// Returns the accepted references plus one rejection message per
  /// over-limit file (those files are skipped, not loaded).
  Future<(List<PickedRef>, List<String>)> pickFilesMeta(
    EncodeMode mode,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: kIsWeb,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return (<PickedRef>[], <String>[]);
    final accepted = <PickedRef>[];
    final rejected = <String>[];
    for (final file in result.files) {
      if (!PlatformLimitsService.fits(file.size, mode)) {
        rejected.add(
          '${file.name}: '
          '${PlatformLimitsService.overLimitAdvice(file.size, mode)}',
        );
        continue;
      }
      accepted.add(
        PickedRef(
          name: file.name,
          size: file.size,
          path: file.path,
          bytes: file.bytes,
        ),
      );
    }
    return (accepted, rejected);
  }

  /// Reads a referenced file's bytes (native path or in-memory bytes).
  Future<Uint8List> readRef(PickedRef ref) async {
    if (ref.bytes != null) return ref.bytes!;
    if (ref.path != null) return readPickedFile(ref.path!);
    throw const FileTooLargeException('Could not read the picked file.');
  }

  /// Reads the first [maxBytes] of a referenced file, for estimates.
  Future<Uint8List> readRefHead(PickedRef ref, int maxBytes) async {
    if (ref.bytes != null) {
      return ref.bytes!.length <= maxBytes
          ? ref.bytes!
          : Uint8List.sublistView(ref.bytes!, 0, maxBytes);
    }
    if (ref.path != null) return readFileHead(ref.path!, maxBytes);
    throw const FileTooLargeException('Could not read the picked file.');
  }
}
