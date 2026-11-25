/// Fixture loader, web implementation: fetch over HTTP from the test
/// server, which serves the `test/` directory at its root.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Fetches `test/fixtures/[fileName]` over HTTP and returns its bytes.
Future<Uint8List> loadFixture(String fileName) async {
  final response = await web.window
      .fetch('fixtures/$fileName'.toJS)
      .toDart
      .timeout(const Duration(seconds: 60));
  if (!response.ok) {
    throw StateError(
      'Fixture $fileName did not load: HTTP ${response.status}',
    );
  }
  final jsBuffer = await response.arrayBuffer().toDart;
  final dartBuffer = jsBuffer.toDart;
  return Uint8List.view(dartBuffer, 0, dartBuffer.lengthInBytes);
}
