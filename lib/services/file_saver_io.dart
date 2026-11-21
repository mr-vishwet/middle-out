import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Saves [bytes] into the app's documents directory and returns the path.
Future<String> saveFileBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final dir = await getApplicationDocumentsDirectory();
  final safeName = fileName.replaceAll(RegExp(r'[^\w\-.]+'), '_');
  final file = File('${dir.path}/$safeName');
  await file.writeAsBytes(bytes);
  return file.path;
}
