import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:middle_out/codec/code_grid.dart';
import 'package:middle_out/codec/decoder.dart';
import 'package:middle_out/codec/encoder.dart';
import 'package:middle_out/codec/png_encode.dart';

/// VM-ONLY benchmark (uses dart:io for RSS): a single 5 MB frame through
/// the QR grid build + deflate, timed, with peak memory reported.
///
/// The two-phase PDF build holds every frame image before binding, so a
/// big frame's grid (5 MB -> ~7,700 x 5,450 modules, ~42M cells) is the
/// memory hotspot of the equal-split design. These numbers are reported,
/// not asserted on a threshold — the grid size is inherent to the frame
/// size — but the round-trip IS asserted: the built grid must parse back
/// to the frame bytes, and the encode must decode byte-identically.
///
/// Do NOT run under `flutter test -d chrome` (dart:io is unavailable
/// there); the codec round-trip itself is covered on Chrome by
/// codec_roundtrip_test.dart.
void main() {
  test('big-frame probe: 5 MB frame builds + round-trips', () async {
    final random = Random(11);
    final data = Uint8List.fromList(
      List<int>.generate(5 * 1024 * 1024, (_) => random.nextInt(256)),
    );
    final rssBefore = ProcessInfo.currentRss;

    final encodeSw = Stopwatch()..start();
    final result = Encoder.encode(data, maxPayload: 8 * 1024 * 1024);
    encodeSw.stop();
    final dataFrame =
        result.frames.firstWhere((f) => f.isData);
    expect(dataFrame.payload.length, greaterThan(5 * 1024 * 1024));
    final rssAfterEncode = ProcessInfo.currentRss;

    final raw = dataFrame.toBytes();
    final gridSw = Stopwatch()..start();
    final grid = CodeGrid.buildFrameGrid(raw, barcode: false);
    gridSw.stop();
    final w = grid[0].length;
    final h = grid.length;
    final rssAfterGrid = ProcessInfo.currentRss;

    final deflateSw = Stopwatch()..start();
    final deflate = PngEncode.deflate1Bit(grid, w, h);
    deflateSw.stop();
    final rssAfterDeflate = ProcessInfo.currentRss;

    final parseSw = Stopwatch()..start();
    expect(CodeGrid.parseGrid(grid), raw);
    parseSw.stop();

    expect(
      Decoder.decode([for (final f in result.frames) f.toBytes()]),
      data,
    );

    // Peak RSS from /proc (VmHWM) — currentRss is a point sample, the
    // high-water mark is the honest peak.
    var peakRss = rssAfterDeflate;
    try {
      final status = await File('/proc/self/status').readAsString();
      final match = RegExp(r'VmHWM:\s+(\d+) kB').firstMatch(status);
      if (match != null) peakRss = int.parse(match.group(1)!) * 1024;
    } catch (_) {
      // Non-Linux runners: fall back to the sampled peak.
    }

    String mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    // ignore: avoid_print — benchmark output is the point of this test.
    print('--- big-frame probe (5 MB frame, QR mode) ---');
    // ignore: avoid_print
    print('grid: $w x $h modules (${(w * h / 1000000).toStringAsFixed(1)}M cells)');
    // ignore: avoid_print
    print('encode: ${encodeSw.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('grid build: ${gridSw.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('deflate: ${deflateSw.elapsedMilliseconds} ms '
        '(-> ${mb(deflate.length)})');
    // ignore: avoid_print
    print('grid parse: ${parseSw.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print('RSS: before ${mb(rssBefore)}, after encode '
        '${mb(rssAfterEncode)}, after grid ${mb(rssAfterGrid)}, '
        'after deflate ${mb(rssAfterDeflate)}, peak (VmHWM) ${mb(peakRss)}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
