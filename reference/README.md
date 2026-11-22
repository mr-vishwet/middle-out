# Python reference implementation

A byte-for-byte mirror of the Dart codec in `lib/codec/`, written in
stdlib-only Python (+ PIL for the image round-trip tests only). It
exists so the wire format, erasure coding, encryption and PDF assembly
can be validated without a Flutter toolchain. The PDF writer is
hand-rolled (no reportlab) and the extractor parses image XObjects
directly (no `pdfimages`).

**Rule: the Dart side and this file MUST agree.** Change the frame
header, the parity layout, the grid geometry or the crypto in one, and
change the other in the same commit, then re-run both test suites.

## Run the tests

```sh
python3 test_codec_reference.py
```

50 tests: ChaCha20 (RFC 8439 vector, cross-checked against OpenSSL),
plain + encrypted round-trips, multi-group round-trip, parity recovery
and failure modes, verification failures, rectangular grid geometry
(capacity formula proven against an independent count), grid/bar-grid
image round-trips, polarity detection, and full PDF build + decode-back
in all 4 combinations (light/dark x QR/barcode, full 64 KiB frames)
plus the golden old-format fixtures.

Requires Python 3.10+ and `Pillow` (for the image round-trip tests
only — the codec, PDF builder and extractor are stdlib-only).

## CLI

```sh
# Encode a file to an 8-frame-group PDF (1 cover + 1 page per frame).
python3 codec_reference.py encode in.bin out.pdf \
    [--passphrase SECRET] [--barcode] [--dark] [--frames-dir DIR]

# Decode a Middle Out PDF back to the original file (SHA-256 verified).
# Light/dark and QR/barcode are auto-detected per page; old-format PDFs
# decode too.
python3 codec_reference.py decode-pdf out.pdf in.bin [--passphrase SECRET]
```

`--frames-dir` also writes each frame as a `.bin` file — the same format
the Flutter app's decode screen imports in v0.1.

## Format

- **Grids are rectangular (w x h).** QR grids match the A4 landscape
  aspect (~1.41421); bar-grids stretch it 4x (~5.65685), so each module
  draws as a tall thin rectangle and adjacent black modules merge into
  vertical bars. Both use the same layout code (same bit order, same
  finders/timing, same centre-tile rule). `choose_grid_size`
  steps h by 2 from 32 with w = round(h * aspect). Reserved cells are
  the three 8x8 finder blocks (192), the timing row (w-16) and column
  (h-16), and the centre tile (tileW x tileH) — disjoint for w,h >= 32,
  so capacity is pure arithmetic. The centre tile is square AS DRAWN
  (~148.8 pt per side): square grids use side = max(8, n//4);
  landscape grids use tileW = halfUp(w * 595.28 / (4 * 841.89)) and
  tileH = halfUp(h / 4), so the logo fills the tile in both formats.
- **Code pages are A4 landscape, full-bleed:** the code image spans the
  entire 841.89 x 595.28 pt rect — no margins, no caption, no quiet
  zone. The cover stays portrait with its manifest text. Dark pages
  invert the code pixels and paint the background black; polarity is
  auto-detected per page from the top-left finder (guard bars for
  stacked barcodes).
- **Logo tile:** one shared 64x64 RGB image XObject, drawn over the
  centre tile of every code page (the app icon: black tile, white
  pixel-M, green dot), embedded as a base64 constant. It is drawn
  SQUARE, filling the tile (the tile is square as drawn) inside a
  rounded-rectangle clip, so it is never stretched and never
  covers live data modules. It is decorative overlay, never decoded;
  the extractor prefers the 1-bit code images and never attempts it.
- **Legacy formats still decode:** old square grids (quiet zone 4),
  stacked-row barcodes (528 bars/row, 8-bit row index with the
  positional fallback past 256 rows), and 8-bit RGB XObjects from the
  pre-RawPdfWriter builder (see `test/fixtures/old_format_*.pdf`).

## What it mirrors

| Python | Dart |
|---|---|
| `Frame` | `lib/codec/frame.dart` |
| `chacha20_xor`, `derive_key` | `lib/codec/chacha20.dart` |
| `encode`, `decode` (+ parity) | `lib/codec/encoder.dart`, `decoder.dart`, `erasure.dart` |
| `build_grid`, `parse_grid`, `is_reserved`, `choose_grid_size`, `grid_capacity_bits` | `lib/codec/code_grid.dart` |
| `build_barcode_grid` | `lib/codec/code_grid.dart` (bar-grid) |
| `build_barcode_rows`, `parse_barcode_rows` | `lib/codec/code_grid.dart` (legacy stacked rows, decode-only) |
| `pack_1bit`, `deflate_1bit` | `lib/codec/png_encode.dart` |
| `RawPdfWriter`, `build_pdf` | `lib/codec/pdf_writer.dart`, `lib/codec/pdf_document.dart` |
| `extract_pdf_frames`, `decode_pdf` | `lib/services/pdf_frame_extractor.dart` |
| `render_grid_image`, `sample_grid_image` | `lib/widgets/frame_grid.dart` (render only) |

Differences are deliberate and documented in the code: the Python side
renders test images with PIL; the Dart side renders with a
`CustomPainter`. The wire bytes — frames, grids, barcodes, PDF image
payloads — are identical. The Python PDF builder is ~20x slower per
frame than Dart (~260-350 ms vs ~14 ms, pure-Python bit loops) — fast
enough for a reference, not for production encodes.
