# Middle Out sample PDFs

Two sample encoded PDFs built from the same demo file with the
full-bleed builder (landscape cover + landscape code pages, code filling
the whole page, logo tile in the centre of every code page).

- `middle-out-sample-light.pdf` — black code on a white page.
- `middle-out-sample-dark.pdf` — white code on a black page.

Each is 3 pages: 1 cover + 2 code pages (1 data frame + 1 parity
frame — the demo compresses to 8,303 bytes, a single chunk, and the
empty second trio emits no second parity, so there is no sparse page).
The cover carries branding, file details only (name, size, format,
theme, page count) and a scannable QR code to the Middle Out web app;
no SHA-256, payload size, ratio or frame counts appear on it.

Demo file: exactly 1,048,576 bytes of deterministic text (the repo
README repeated 461 times with section markers),
SHA-256 `e78a38dc1faafa0f9f8028feb41632503beae935517f31afac8e3ee32d42df55`.

Settings: QR mode, encrypted ON. Sample passphrase:
`middle-out-sample-2026` (needed to decode; the demo content is public
README text, so the passphrase is published here on purpose).

Decode them with the app (Decode → import PDF) or the Python CLI:

```
python3 reference/codec_reference.py decode-pdf \
  docs/samples/middle-out-sample-light.pdf out.bin \
  --passphrase middle-out-sample-2026
```

Both samples decode back byte-identical to the demo file
(SHA-256 verified with the Dart extractor and the Python CLI).
