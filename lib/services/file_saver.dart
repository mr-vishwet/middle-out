/// Saves arbitrary bytes to the device. Platform implementations live in
/// `file_saver_io.dart` (mobile/desktop: app documents directory) and
/// `file_saver_web.dart` (web: browser download).
library;
export 'file_saver_stub.dart'
    if (dart.library.io) 'file_saver_io.dart'
    if (dart.library.html) 'file_saver_web.dart';
