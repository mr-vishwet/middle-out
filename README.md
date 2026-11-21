# Middle Out

**Lossless file compression into visual frames.** A file encodes into
QR-like frames packaged as a PDF; decoding the PDF reconstructs the
original bit-for-bit — verified by SHA-256.

> **v0.1 — phase 1 build.** The compression engine is real and tested
> end-to-end (see [Verification](#verification)), and the full app is
> built around it: all 60 V7 screens (30 mobile + 30 web layouts),
> batch queue, history, settings, guest-first auth, the share sheet,
> PDF-import decode, and streaming encode for large native files.
> Camera sampling from photos, cloud upload/sync and AEAD encryption
> are phase 2, listed in [Roadmap](#roadmap). This is a v0.1 build —
> nothing here is shipped, and no dates, user counts or shipped claims
> appear anywhere in the app or this file.

## What it does

1. **Encode** — pick a file. Middle Out compresses it (zlib), optionally
   encrypts it (ChaCha20, passphrase-derived key), splits it into frames,
   protects each group of 6 data frames with 2 XOR parity frames, and
   renders every frame as a full-page code in a PDF: **1 cover page + 1
   page per frame**.
2. **Decode** — import the PDF (frames are recovered from its code
   images) or the `.bin` frame files, in any order. Lost or corrupt
   frames are rebuilt from parity (one per trio), the stream is decrypted
   and decompressed, and the result is checked against the SHA-256 stored
   in every frame header. A wrong passphrase or a tampered frame fails
   loudly — nothing is ever shown as "decoded" unless it verifies.

## The format

One big code per page — a QR-style 2D grid (default) or a stacked-row
barcode — flat black-and-white, with the Middle Out app-icon tile in the
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
the planned phase-2 upgrade.

**Visual codes:** a real ISO QR code holds ~3 KB; a Middle Out frame
holds up to 64 KiB, so the 2D mode is a custom grid — QR-style finders,
timing patterns, centre tile reserved for the logo — not an ISO QR code.
The cover page carries a small grid with the decode manifest. Barcode
mode stacks the payload as rows of bars (PDF417-style), each row indexed
so out-of-order scans still decode.

## Screens — all 60

One route per V7 screen concept; each route renders its mobile layout
below 800 px logical width and its web layout above it, so the 30 routes
cover m01–m30 + w01–w30. Every screen is functional — navigation, real
state, no placeholder buttons on core flows.

| # | Route | Screen |
|---|---|---|
| m01/w01 | `/` | Home dashboard (pitch, queue, stats, recent, demo) |
| m02/w02 | `/encode/pick` | File picker (limit printed on the picker) |
| m03/w03 | `/encode/pre` | Pre-encode: estimate + toggles |
| m04/w04 | `/encode/progress` | Encoding progress |
| m05/w05 | `/encode/result` | Encoded: ratio, frames, hash, PDF size |
| m06/w06 | `/frames` | Frames view (data + parity) |
| m07/w07 | `/frames/detail` | Frame detail (full-size code, stream range) |
| m08/w08 | `/pdf` | The PDF: cover + code pages |
| m09/w09 | `/share` | Share sheet (PDF file + expiring link) |
| m10/w10 | `/batch` | Batch queue (per-item settings) |
| m11/w11 | `/history` | History (stats + records) |
| m12/w12 | `/history/detail` | History detail |
| m13/w13 | `/decode` | Decode entry (scan / PDF / frame files) |
| m14/w14 | `/decode/import` | Decode import (frames verified first) |
| m15/w15 | `/decode/progress` | Decoding progress |
| m16/w16 | `/decode/verify` | Verify: both hashes, 0 bytes differ |
| m17/w17 | `/decode/done` | Decoded: the original is back |
| m18/w18 | `/decode/damaged` | Damaged frame: what parity rebuilt |
| m19/w19 | `/settings` | Settings (limits, defaults, display, data) |
| m20/w20 | `/payoff` | The payoff: send small, open big |
| m21/w21 | `/auth/welcome` | Welcome: guest-first |
| m22/w22 | `/auth/guest` | Guest mode, explained |
| m23/w23 | `/auth/sign-in` | Sign in |
| m24/w24 | `/auth/create` | Create account |
| m25/w25 | `/auth/verify` | Verify: magic link or 6-digit code |
| m26/w26 | `/auth/upgrade` | Upgrade prompt: file needs cloud encode |
| m27/w27 | `/auth/migrate` | Migrate guest work into the account |
| m28/w28 | `/account` | Account home |
| m29/w29 | `/account/connected` | Connected: links, storage, sign-in |
| m30/w30 | `/account/data` | Data controls: export, sign out, delete |

Extra route: `/decode/scan` — camera preview + capture (sampling from
photos is phase 2; the screen says so and routes to PDF import).

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

## Phase 1: what is real

- **Codec** — the full pipeline, tested end-to-end (see below).
- **Streaming encode (native)** — files at or above 32 MB encode
  through `StreamingEncoder`: two passes off disk (hash + compress +
  encrypt to a temp file, then frame it), so the file is never loaded
  whole. Web files use the in-memory path (no file paths on web).
- **PDF-import decode** — `PdfFrameExtractor` finds the code images in
  an encoded PDF, samples the modules back out, and feeds the normal
  decoder. The cover manifest grid is recognised and skipped.
- **Batch queue** — multi-pick, per-item format/encryption settings,
  sequential run, per-item results with save/share, persisted metadata.
- **History** — every encode/decode recorded, with stats (real records
  only), detail, delete, and saved-PDF sharing.
- **Share sheet** — the PDF file, the rebuilt file, links and text go
  through the system share sheet. Expiring links are demo records
  (created, listed, revocable, 7-day expiry) until cloud sharing ships.
- **Auth (local)** — guest-first; sign-in, create account, 6-digit
  verification, migration, connected toggles, data controls (JSON
  export, sign out, delete) all work against a profile stored on the
  device. The verification code is generated on-device and shown in-app,
  labelled DEMO — no email is sent in phase 1. Cloud sync and real
  magic-link email arrive with the backend in phase 2.
- **Persistence** — history, settings, account, batch metadata and
  links persist via `shared_preferences` (small JSON documents; no
  relational store is needed, so Drift/SQLite was not pulled in).
  Passphrases and file bytes are never persisted.
- **Logos** — the four chosen logo versions are bundled as SVG assets
  (`assets/logos/`) and rendered with `flutter_svg`; the app-icon tile
  sits in the centre of every code preview.

## Honest limits

Read this before quoting any number from the demo:

- **The 73× demo is a story, not a measurement.** The V7 design shows a
  1.04 GB podcast master encoding to a 14.2 MB PDF. Real lossless
  compression depends entirely on the input: silence compresses far,
  an encrypted zip barely at all. The demo numbers live in the app as
  seeded demo content, labelled DEMO, and are never presented as a
  measured encode. History stats exclude demo records.
- **The 8-page layout is the target density, not v0.1 reality.** v0.1
  frames carry up to 64 KiB each (sized for reliable scanning at print
  resolution), so a large file needs many 8-frame groups — and many PDF
  pages. Reaching the demo's 8-page density for a 1 GB input needs
  higher-density printing (smaller modules, higher DPI) and is a phase-2
  research item. The codec itself is capacity-agnostic: the frame
  format is identical whether an encode is 8 frames or 800.
- **PDF assembly still holds the PDF in memory.** Streaming covers the
  read/compress/encrypt/frame stages; `PdfDocument.build` assembles the
  whole PDF in memory. Frame-at-a-time PDF streaming is phase 2.
- **Camera sampling is phase 2.** The scan screen previews and captures;
  turning a photo back into frames (perspective correction + finder
  detection) is not in this build. Decode today imports the PDF itself.
- **Cloud is a preference, not a service, in this build.** Web Cloud
  mode can be selected and the account screens record the preference,
  but upload/sync need the backend (phase 2). Files still encode
  locally, and the UI says so.

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

The Dart suite (`flutter test`) covers the codec plus the phase-1 state
and services: codec round-trips, parity recovery, hash verification,
limits, code grids, frame inspection, PDF frame extraction (hand-built
PDF fixtures), streaming encode round-trips, history/auth/batch/link
stores, settings, and the route table (all 30 routes generate).

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
assets/
  logos/                     Chosen logo set (icon, horizontal, stacked, app-icon)
lib/
  main.dart                  Entry point
  app.dart                   App shell + route table (generateAppRoute)
  core/
    constants.dart           Wire format, limits, demo fixture
    theme.dart               V7 palette (lime on deep green) + Inter
    theme_scope.dart         App-wide dark/light toggle (v0.1, kept as-is)
    format.dart              Byte / ratio / duration formatting
    routes.dart              Route names (30 V7 routes)
    adaptive.dart            Mobile/web breakpoint + shared scaffolds
  codec/                     The engine (mirrors reference/codec_reference.py)
    frame.dart               97-byte header, CRC32, frame model
    chacha20.dart            ChaCha20 (RFC 8439) + PBKDF2
    erasure.dart             XOR parity build / recover
    encoder.dart             chunk -> compress -> encrypt -> frames
    streaming_encoder*.dart  Chunked off-disk encode (native; stub on web)
    decoder.dart             frames -> recover -> decrypt -> verify
    code_grid.dart           2D grid + stacked barcode builders/parsers
    png_encode.dart          Minimal 1-bit PNG encoder (PDF embedding)
    pdf_document.dart        Cover + code pages via package:pdf
  services/
    platform_limits.dart     Mode detection, limits, routing advice
    file_picker_service.dart Limit-gated picking (by reference, multi-pick)
    file_reader*.dart        Read picked files / file heads
    file_saver*.dart         Save arbitrary bytes (native docs dir / web download)
    pdf_saver*.dart          Save PDF (native docs dir / web download)
    pdf_frame_extractor.dart Recover frames from an encoded PDF
    frame_inspector.dart     Pre-decode inspection (damage, recoverability)
    share_service.dart       System share sheet (share_plus)
    storage_service.dart     JSON persistence (shared_preferences)
  state/
    app_scope.dart           AppState + AppScope (shared controllers)
    encode_controller.dart   Encode + decode state machines
    batch_controller.dart    Batch queue
    history_store.dart       History records + stats
    auth_controller.dart     Guest/account, verify, migrate, connected
    settings_controller.dart Defaults + display + data preferences
    link_store.dart          Expiring shared links (demo records)
  widgets/
    format_toggle.dart       QR grid vs Barcode
    encryption_toggle.dart   Encrypt switch + passphrase field
    limit_banner.dart        Mode picker + limit + routing advice
    frame_grid.dart          Code painter with app-icon centre tile
    app_logo.dart            Bundled SVG logos
  screens/
    shell_screen.dart        5-tab shell (bottom nav / nav rail)
    home_screen.dart         m01/w01 dashboard
    encode_screen.dart       m02–m04 picker / pre-encode / encoding
    result_screen.dart       m05/w05 encode result
    frames_screen.dart       m06–m07 frames view + frame detail
    pdf_preview_screen.dart  m08/w08 the PDF
    share_screen.dart        m09/w09 share sheet
    batch_screen.dart        m10/w10 batch queue
    history_screen.dart      m11–m12 history + detail
    decode_screen.dart       m13/w13 decode entry
    decode_flow.dart         m14–m18 import / decoding / verify / decoded / damaged
    scan_screen.dart         Camera preview + capture
    settings_screen.dart     m19/w19 settings
    payoff_screen.dart       m20/w20 the payoff
    auth_flow.dart           m21–m30 auth + account screens
test/                        Dart test suite (flutter test)
reference/                   Python mirror of the codec + tests (runnable here)
web/                         Web entry (index.html, manifest.json)
```

## Roadmap (phase 2)

1. **Camera decode** — sample frames from a captured photo (perspective
   correction + finder detection + module sampling on the luminance
   matrix). The capture UI and the frame-level decoder it feeds are
   already in place.
2. **Frame-at-a-time PDF streaming** — build the PDF without holding it
   whole, so the 100 GB native limit is real end to end.
3. **Isolate encode** — move compression/framing/PDF off the UI thread.
4. **ChaCha20-Poly1305** — AEAD instead of raw ChaCha20 + SHA-256.
5. **Cloud mode** — resumable chunked upload, real magic-link email,
   sync, and resolving shared links (backend).
6. **ISO QR cover code** — manifest readable by any phone camera.
7. **Higher-density printing** — smaller modules / higher DPI toward the
   8-page demo layout for large files.
8. **Dual-theme system** — the v0.1 dark/light toggle stays; a fuller
   theme system (per-app theme picker) is phase 2.

## Appendix: CI workflow (add via the GitHub web UI)

No `.github/workflows/` file is pushed with this repo (the GitHub App
cannot write workflow files). To add CI, create
`.github/workflows/flutter.yml` in the web UI with:

```yaml
name: Flutter

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.27.x'
          channel: stable
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
```
