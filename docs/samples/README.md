# Middle Out sample PDFs

Two sample encoded PDFs built from the same demo file with the
full-bleed builder (landscape code pages, code filling the whole page,
logo tile in the centre of every code page).

- `middle-out-sample-light.pdf` — black code on a white page.
- `middle-out-sample-dark.pdf` — white code on a black page.

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
