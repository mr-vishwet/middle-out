import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Saves the PDF into the app's documents directory and returns the path.
/// (v0.2 wires the system share sheet so the file lands in Downloads/Files
/// directly; v0.1 keeps the file inside the app's own storage.)
Future<String> savePdf(Uint8List bytes, String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  final safeName = fileName.replaceAll(RegExp(r'[^\w\-.]+'), '_');
  final file = File('${dir.path}/$safeName');
  await file.writeAsBytes(bytes);
  return file.path;
}
