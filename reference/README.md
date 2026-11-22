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

70 tests: ChaCha20 (RFC 8439 vector, cross-checked against OpenSSL),
plain + encrypted round-trips, equal-split framing (20-frame cap,
zero-padded last chunk, parity only for non-empty trios, 1-data-group
recovery, old-format fixed-chunk frames still decoding), multi-group
round-trip, parity recovery and failure modes, verification failures,
rectangular grid geometry (capacity formula proven against an
independent count), grid/bar-grid image round-trips (including a 5 MB
frame through the raised 32768 grid cap), polarity detection, the cover
QR const (finder patterns, quiet zone, cv2 decode to the app URL), and
full PDF build + decode-back in all 4 combinations (light/dark x
QR/barcode, branded landscape cover with details only, cover-stripped
and coverless PDFs still decoding) plus the golden old-format fixtures
and the Dart-built samples in `docs/samples/`.

Requires Python 3.10+ and `Pillow` (for the image round-trip tests
only — the codec, PDF builder and extractor are stdlib-only).
`opencv-python-headless` is optional: one test uses it to prove the
cover QR decodes to the app URL, and skips without it.

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

- **Equal-split framing.** The (compressed+encrypted) stream is divided
  into N = min(20, ceil(streamLen / 65536)) EQUAL chunks of chunkSize =
  ceil(streamLen / N); the last chunk is zero-padded to chunkSize, so
  every data frame — and every parity frame — is the same width and
  every code page is equally dense (no sparse near-empty last page).
  Every frame carries flag bit 0x08 (`FLAG_EQUAL_SPLIT`); the decoder
  derives chunkSize as ceil(compressedSize / totalDataFrames) from the
  header alone and trims the reassembled stream to compressedSize
  before decrypt/decompress. The 20-frame cap bounds an encode at 28
  frames (20 data + 8 parity). Old fixed-chunk frames (flag unset)
  keep the previous derivation and still decode.
- **Parity is emitted only for non-empty trios.** A group with <= 3
  data frames has no P2 (trio B is empty); the empty-input edge (a
  0-byte stream) yields one empty data frame and no parity at all.
  Parity frameIndex gaps are fine — the decoder keys parity by
  (group, slot), never by index.
- **Grids are rectangular (w x h).** QR grids match the A4 landscape
  aspect (~1.41421); bar-grids stretch it 4x (~5.65685), so each module
  draws as a tall thin rectangle and adjacent black modules merge into
  vertical bars. Both use the same layout code (same bit order, same
  finders/timing, same centre-tile rule). `choose_grid_size`
  steps h by 2 from 32 with w = round(h * aspect), up to the 32768
  height cap (a 5 MB frame needs h ~= 5572). Reserved cells are
  the three 8x8 finder blocks (192), the timing row (w-16) and column
  (h-16), and the centre tile (tileW x tileH) — disjoint for w,h >= 32,
  so capacity is pure arithmetic. The centre tile is square AS DRAWN
  (~148.8 pt per side): square grids use side = max(8, n//4);
  landscape grids use tileW = halfUp(w * 595.28 / (4 * 841.89)) and
  tileH = halfUp(h / 4), so the logo fills the tile in both formats.
- **Code pages are A4 landscape, full-bleed:** the code image spans the
  entire 841.89 x 595.28 pt rect — no margins, no caption, no quiet
  zone. Dark pages invert the code pixels and paint the background
  black; polarity is auto-detected per page from the top-left finder
  (guard bars for stacked barcodes).
- **Cover is landscape, branded, details-only:** logo + "MIDDLE OUT"
  wordmark, five detail lines (file name — truncated at 80 chars so
  it cannot run into the QR — original size, code format, theme, page
  count) and a REAL scannable ISO QR code to the app site (version 3,
  29x29, ECL M, embedded as a base64 const, drawn with a 4-module
  quiet zone — a QR without one fails to scan). NO SHA-256, NO encoded
  payload size, NO ratio, NO frame/group counts, NO decode
  instructions, NO manifest grid: those live in the frame headers
  encoded in the code pages. The cover stays LIGHT in both variants.
  The decoder never depends on the cover: a cover-stripped or
  coverless PDF decodes identically, and the extractor rejects the
  cover QR via the frame check.
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
| `_split_equal` | `lib/codec/encoder.dart` (`_chunk`, including the count re-derivation) |
| `cover_qr_grid`, `cover_qr_grid_with_quiet`, `COVER_QR_MODULES_B64` | `lib/codec/cover_qr.dart` (`CoverQr`, same const bytes) |
| `pack_1bit`, `deflate_1bit` | `lib/codec/png_encode.dart` |
| `RawPdfWriter`, `build_pdf` | `lib/codec/pdf_writer.dart`, `lib/codec/pdf_document.dart` |
| `extract_pdf_frames`, `decode_pdf` | `lib/services/pdf_frame_extractor.dart` |
| `render_grid_image`, `sample_grid_image` | `lib/widgets/frame_grid.dart` (render only) |

Differences are deliberate and documented in the code: the Python side
renders test images with PIL; the Dart side renders with a
`CustomPainter`. The wire bytes — frames, grids, barcodes, PDF image
payloads — are identical, and each side decodes the other's frames
(verified live: Dart-encoded frames decode in Python and vice versa,
including parity recovery of a dropped frame). One allowed difference:
the compressed stream bytes may differ between Dart's pure-Dart
deflate and C zlib at the same level — both are valid zlib streams
that decompress to the same input, so framing, not compression, is
what the two sides must agree on. The Python PDF builder is ~20x
slower per frame than Dart (pure-Python bit loops) — a 5 MB frame
grid builds in ~16-22 s and parses in ~12-19 s on this VM — fast
enough for a reference, not for production encodes.
