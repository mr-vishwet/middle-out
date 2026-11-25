/// Fixture loader, non-web implementation: unsupported.
///
/// Chrome-only tests are skipped off the web, so this is never called.
library;

import 'dart:typed_data';

/// Never called (guarded by the test's `skip`); throws if reached.
Future<Uint8List> loadFixture(String fileName) async =>
    throw UnsupportedError('Fixtures load over HTTP, on the web only.');
