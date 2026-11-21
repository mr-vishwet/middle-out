# Python reference implementation

A byte-for-byte mirror of the Dart codec in `lib/codec/`, written in
stdlib-only Python (+ PIL and reportlab for image/PDF rendering). It
exists so the wire format, erasure coding, encryption and PDF assembly
can be validated without a Flutter toolchain.

**Rule: the Dart side and this file MUST agree.** Change the frame
header, the parity layout, the grid geometry or the crypto in one, and
change the other in the same commit, then re-run both test suites.

## Run the tests

```sh
python3 test_codec_reference.py
```

26 tests: ChaCha20 (RFC 8439 vector, cross-checked against OpenSSL),
plain + encrypted round-trips, multi-group round-trip, parity recovery
and failure modes, verification failures, grid/barcode image
round-trips, and full PDF build + decode-back in both modes.

Requires Python 3.10+, `Pillow` and `reportlab` (for the image/PDF
tests), and `pdfimages` from poppler (for the PDF decode-back tests —
skipped if absent).

## CLI

```sh
# Encode a file to an 8-frame-group PDF (1 cover + 1 page per frame).
python3 codec_reference.py encode in.bin out.pdf \
    [--passphrase SECRET] [--barcode] [--frames-dir DIR]

# Decode a Middle Out PDF back to the original file (SHA-256 verified).
python3 codec_reference.py decode-pdf out.pdf in.bin [--passphrase SECRET]
```

`--frames-dir` also writes each frame as a `.bin` file — the same format
the Flutter app's decode screen imports in v0.1.

## What it mirrors

| Python | Dart |
|---|---|
| `Frame` | `lib/codec/frame.dart` |
| `chacha20_xor`, `derive_key` | `lib/codec/chacha20.dart` |
| `encode`, `decode` (+ parity) | `lib/codec/encoder.dart`, `decoder.dart`, `erasure.dart` |
| `build_grid`, `parse_grid` | `lib/codec/code_grid.dart` |
| `build_barcode_rows`, `parse_barcode_rows` | `lib/codec/code_grid.dart` |
| `render_grid_image`, `sample_grid_image` | `lib/widgets/frame_grid.dart` (render only) |
| `build_pdf`, `decode_pdf` | `lib/codec/pdf_document.dart` (build only) |

Differences are deliberate and documented in the code: the Python side
renders images with PIL and builds PDFs with reportlab; the Dart side
renders with a `CustomPainter` and builds PDFs with `package:pdf`. The
wire bytes — frames, grids, barcodes — are identical.
