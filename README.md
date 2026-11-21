# Middle Out

**Lossless file compression into visual frames.** A file encodes into
QR-like frames packaged as a PDF; decoding the PDF reconstructs the
original bit-for-bit — verified by SHA-256.

> **v0.1 — started, not finished.** The compression engine is real and
> tested end-to-end (see [Verification](#verification)). The app shell,
> encode/decode flows and both themes exist. Camera scanning, streaming
> encode of very large files and the share sheet are v0.2 items, listed
> in [Roadmap](#roadmap).

## What it does

1. **Encode** — pick a file. Middle Out compresses it (zlib), optionally
   encrypts it (ChaCha20, passphrase-derived key), splits it into frames,
   protects each group of 6 data frames with 2 XOR parity frames, and
   renders every frame as a full-page code in a PDF: **1 cover page + 1
   page per frame**.
2. **Decode** — import the frames (any order). Lost or corrupt frames are
   rebuilt from parity (one per trio), the stream is decrypted and
   decompressed, and the result is checked against the SHA-256 stored in
   every frame header. A wrong passphrase or a tampered frame fails
   loudly — nothing is ever shown as "decoded" unless it verifies.

## The format

One big code per page — a QR-style 2D grid (default) or a stacked-row
barcode — flat black-and-white, with the Middle Out logo tile in the
centre of each code. Format toggle (QR vs Barcode, default QR) +
encrypted toggle (default ON: encrypted payload is not human-readable
when scanned; plain payload is).

### Frame wire format (v1)

97-byte header + payload + 4-byte payload CRC32. Every frame carries the
full encode metadata, so any single frame identifies the file it belongs
to:

| Bytes | Field |
|---|---|
| 0–3 | Magic `"MO01"` |
| 4 | Version (1) |
| 5 | Frame index (global) |
| 6 | Kind (0 = DATA, 1 = PARITY) |
| 7 | Group index |
| 8 | Slot in group (0–5 DATA, 6–7 PARITY) |
| 9 | Flags (bit0 encrypted, bit1 last group, bit2 barcode) |
| 10 | Total groups |
| 11–12 | Total DATA frames |
| 13–16 | Payload length |
| 17–24 | Original size |
| 25–32 | Compressed (+encrypted) stream size |
| 33–64 | SHA-256 of the original |
| 65–80 | PBKDF2 salt (16 B, zero when plain) |
| 81–92 | ChaCha20 nonce (12 B, zero when plain) |
| 93–96 | Header CRC32 |

**Erasure coding:** parity A = XOR of data slots 0, 1, 2; parity B = XOR
of slots 3, 4, 5. Each trio survives any single lost or corrupt frame.
Two losses in one trio are unrecoverable — the decoder names the group
and trio.

**Encryption:** PBKDF2-HMAC-SHA256 (100k iterations) derives a 32-byte
key from the passphrase; ChaCha20 (RFC 8439, pure Dart, no platform
dependency) encrypts the compressed stream. The passphrase never leaves
the device and is never stored. v0.1 uses raw ChaCha20; tampering is
caught by the payload CRCs + final SHA-256. ChaCha20-Poly1305 (AEAD) is
the planned v0.2 upgrade.

**Visual codes:** a real ISO QR code holds ~3 KB; a Middle Out frame
holds up to 64 KiB, so the 2D mode is a custom grid — QR-style finders,
timing patterns, centre tile reserved for the logo — not an ISO QR code.
The cover page carries a small grid with the decode manifest. Barcode
mode stacks the payload as rows of bars (PDF417-style), each row indexed
so out-of-order scans still decode.

## Limits

| Mode | Max file | Notes |
|---|---|---|
| Native app | **100 GB** | Streaming, local |
| Web · Local | **10 GB** | In-browser, no upload |
| Web · Cloud | **50 GB** | Resumable chunked upload, account needed |

The picker shows the platform limit and routes over-limit files to the
mode that can hold them. The encoded PDF for a 1 GB input must land in
the **5–20 MB** band — the result screen warns when a pathological input
(already-compressed or random data) pushes it over.

## Honest limits

Read this before quoting any number from the demo:

- **The 73× demo is a story, not a measurement.** The V7 design shows a
  1.04 GB podcast master encoding to a 14.2 MB PDF. Real lossless
  compression depends entirely on the input: silence compresses far,
  an encrypted zip barely at all. The demo numbers live in the app as
  seeded demo content, labelled DEMO, and are never presented as a
  measured encode.
- **The 8-page layout is the target density, not v0.1 reality.** v0.1
  frames carry up to 64 KiB each (sized for reliable scanning at print
  resolution), so a large file needs many 8-frame groups — and many PDF
  pages. Reaching the demo's 8-page density for a 1 GB input needs
  higher-density printing (smaller modules, higher DPI) and is a v0.2
  research item. The codec itself is capacity-agnostic: the frame
  format is identical whether an encode is 8 frames or 800.
- **v0.1 loads the whole file into memory** (limit-gated before reading).
  Streaming encode — the only way the 100 GB native limit is real — is
  the v0.2 milestone.
- **v0.1 decodes from exported frame files**, not from a scanned PDF.
  Camera capture, perspective correction and module sampling are the
  v0.2 milestone; the frame-level decoder they feed on is complete and
  tested.

## Verification

Flutter/Dart is not installed on the build VM, so the Dart test suite is
**authored, not yet run** — run `flutter test` on a machine with Flutter
to execute it. Everything below was verified on the build VM via the
Python reference implementation (`reference/`), which mirrors the Dart
codec byte-for-byte:

- **26/26 Python reference tests pass**: ChaCha20 (cross-checked against
  OpenSSL's RFC 8439 implementation), plain + encrypted round-trips,
  multi-group round-trip, parity recovery (lost first/middle/last frame,
  corrupt payload, one loss per trio), failure modes (two losses in a
  trio, lost data + its parity, wrong/missing passphrase), grid and
  barcode image round-trips, and full PDF build + decode-back in both
  modes.
- **CLI end-to-end**: a 50 KB random file encoded to a 4-page A4 PDF
  (1 cover + 3 frames) and decoded back **byte-identical**, SHA-256
  verified (`cmp` clean).

```
python3 reference/test_codec_reference.py   # 26 tests, no Flutter needed
python3 reference/codec_reference.py encode in.bin out.pdf [--passphrase P] [--barcode]
python3 reference/codec_reference.py decode-pdf out.pdf in.bin [--passphrase P]
```

## Run the app

```sh
flutter pub get
flutter run            # mobile / desktop
flutter run -d chrome  # web
flutter test           # Dart test suite
flutter analyze        # lints
```

## Layout

```
lib/
  main.dart                  Entry point
  app.dart                   App shell + dark/light theme scope
  core/
    constants.dart           Wire format, limits, demo fixture
    theme.dart               V7 recoloured palette (lime on deep green)
    format.dart              Byte / ratio / duration formatting
  codec/                     The engine (mirrors reference/codec_reference.py)
    frame.dart               97-byte header, CRC32, frame model
    chacha20.dart            ChaCha20 (RFC 8439) + PBKDF2
    erasure.dart             XOR parity build / recover
    encoder.dart             chunk -> compress -> encrypt -> frames
    decoder.dart             frames -> recover -> decrypt -> verify
    code_grid.dart           2D grid + stacked barcode builders/parsers
    png_encode.dart          Minimal 1-bit PNG encoder (PDF embedding)
    pdf_document.dart        Cover + code pages via package:pdf
  services/
    platform_limits.dart     Mode detection, limits, routing advice
    file_picker_service.dart Limit-gated file picking
    pdf_saver*.dart          Save PDF (native docs dir / web download)
  state/
    encode_controller.dart   Encode + decode state machines
  widgets/
    format_toggle.dart       QR grid vs Barcode
    encryption_toggle.dart   Encrypt switch + passphrase field
    limit_banner.dart        Mode picker + limit + routing advice
    frame_grid.dart          Code painter with centre logo tile
  screens/
    home_screen.dart         Pitch + demo card + limits
    encode_screen.dart       Pick -> toggles -> progress -> preview
    decode_screen.dart       Import frames -> verify -> rebuild
    result_screen.dart       Ratio, frames, hash, PDF size, save
test/                        Dart test suite (flutter test)
reference/                   Python mirror of the codec + tests (runnable here)
web/                         Web entry (index.html, manifest.json)
```

## Roadmap (v0.2)

1. **Camera decode** — scan frames from a printed/on-screen PDF
   (perspective correction + module sampling on the luminance matrix).
2. **Streaming encode** — chunked pipeline so the 100 GB native limit is
   real without loading the file.
3. **Isolate encode** — move compression/framing/PDF off the UI thread.
4. **ChaCha20-Poly1305** — AEAD instead of raw ChaCha20 + SHA-256.
5. **Share sheet + Downloads** — system share for the encoded PDF and the
   rebuilt file.
6. **ISO QR cover code** — manifest readable by any phone camera.
7. **Higher-density printing** — smaller modules / higher DPI toward the
   8-page demo layout for large files.
8. **Cloud mode** — resumable chunked upload + account-gated 50 GB path.
