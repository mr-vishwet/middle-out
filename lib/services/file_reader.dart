/// Reads a picked file from its native path. Web never calls this (web
/// picks carry bytes directly); the stub throws if it ever is.
library;
export 'file_reader_stub.dart' if (dart.library.io) 'file_reader_io.dart';
