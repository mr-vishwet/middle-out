/// Loads a test fixture file's bytes, for Chrome-only tests.
///
/// The `--platform chrome` test runner serves the `test/` directory
/// over HTTP but does NOT serve `build/unit_test_assets`, so
/// `rootBundle` hangs in Chrome tests. Fixtures live in
/// `test/fixtures/` and are fetched over HTTP on the web. Off the web
/// the loader throws — Chrome-only tests are skipped there, so it is
/// never called.
library;

import 'dart:typed_data';

import 'fixture_loader_stub.dart'
    if (dart.library.js_interop) 'fixture_loader_web.dart' as impl;

/// Loads `test/fixtures/[fileName]` and returns its bytes.
Future<Uint8List> loadFixture(String fileName) =>
    impl.loadFixture(fileName);
