/// Saves an encoded PDF to the device. Platform implementations live in
/// `pdf_saver_io.dart` (mobile/desktop: app documents directory) and
/// `pdf_saver_web.dart` (web: browser download).
export 'pdf_saver_stub.dart'
    if (dart.library.io) 'pdf_saver_io.dart'
    if (dart.library.html) 'pdf_saver_web.dart';
