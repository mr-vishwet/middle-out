<p align="left">
  <img src="docs/screenshots/app-icon.png" alt="Middle Out app icon — a pixel M built from code modules on a dark tile" width="96">
</p>

# Middle Out

**Send small, open big.** Pied Piper-style lossless compression — any file folds into a handful of full-page codes and packs into one small PDF. Decode it and the original comes back bit-for-bit.

Files keep getting bigger and the ways we move them keep getting in the way. Middle Out folds the whole file — every byte of it — into full-page visual codes, one big code per page, packed as a single PDF small enough to send anywhere a PDF goes. The demo's example encode: a 1.04 GB film master becomes a 14.2 MB PDF, 73× smaller. Open it in Middle Out and the full file comes back, verified byte-for-byte before anything is shown as decoded.

- **Encode** — pick a file and see the estimate up front: frames, PDF size, ratio. Choose QR or barcode, encryption on by default.
- **Frames & PDF** — one cover page plus one page per frame, with extra parity frames that restore a damaged one.
- **Decode** — import the PDF and get the original back, on your device, no upload.
- **Verify** — every decode is checked against the fingerprint stored in the PDF: 0 bytes differ, or it fails loudly.
- **Share & history** — send the PDF itself, or a link that expires in 7 days; the batch queue and history keep every encode.
- **Guest-first** — no account needed. Everything works on-device; signing in adds sync and cloud encode.

<p>
  <img src="docs/screenshots/01-home.jpg" alt="Middle Out home — a gigabyte in eight frames, 73× smaller" width="240">
  <img src="docs/screenshots/02-encode-estimate.jpg" alt="Pre-encode estimate — 8 frames, about 14 MB, QR and encrypted" width="240">
  <img src="docs/screenshots/03-encoding.jpg" alt="Encoding at 62% — frame 5 of 8, middle-out pass 2 of 3" width="240">
  <img src="docs/screenshots/04-encoded-result.jpg" alt="Encoded in 38 seconds — 1.04 GB is now 14.2 MB, with the first two frames" width="240">
  <img src="docs/screenshots/05-verify.jpg" alt="Verify — byte-exact, 0 bytes differ" width="240">
</p>

[**Try the live demo →**](https://mr-vishwet.github.io/middle-out/)
