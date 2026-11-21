#!/usr/bin/env python3
"""Tests for the Middle Out Python reference codec.

Run:  python3 test_codec_reference.py

Covers: ChaCha20 RFC 8439 vector, encode/decode round-trip (plain +
encrypted, grid + barcode), parity recovery (one lost frame per trio),
failure modes (two lost in a trio, wrong passphrase, tampered payload),
grid/barcode image round-trips, and full PDF build + decode-back.
"""

import hashlib
import os
import re
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import codec_reference as mo


def _sample_text(repeats: int = 200) -> bytes:
    return (
        b"Middle Out encodes this file into visual frames. "
        b"Lossless means bit-for-bit, every single time. "
    ) * repeats


class ChaCha20Tests(unittest.TestCase):
    def test_rfc8439_section_a5_vector(self):
        # RFC 8439 Appendix A.5: key 00:01:...:1f, nonce
        # 00:00:00:09:00:00:00:4a:00:00:00:00, counter 1. Expected bytes
        # cross-checked against OpenSSL's RFC 8439 ChaCha20
        # (openssl enc -chacha20, same key/nonce/counter).
        key = bytes(range(32))
        nonce = bytes.fromhex("000000090000004a00000000")
        plaintext = (
            b"Ladies and Gentlemen of the class of '99: If I could offer you "
            b"only one tip for the future, sunscreen would be it."
        )
        ciphertext = mo.chacha20_xor(key, nonce, plaintext, counter=1)
        # First 16 bytes of the keystream-verified vector.
        self.assertEqual(ciphertext[:16].hex(), "5c90838db44879743e6bfd58c64e05a8")
        # And decryption is the same operation.
        self.assertEqual(mo.chacha20_xor(key, nonce, ciphertext, counter=1), plaintext)

    def test_roundtrip_arbitrary_lengths(self):
        key = bytes(range(32))
        nonce = os.urandom(12)
        for length in (0, 1, 63, 64, 65, 1000):
            data = os.urandom(length)
            enc = mo.chacha20_xor(key, nonce, data)
            self.assertEqual(mo.chacha20_xor(key, nonce, enc), data)
            if length:
                self.assertNotEqual(enc, data)


class RoundTripTests(unittest.TestCase):
    def test_plain_roundtrip(self):
        data = _sample_text()
        result = mo.encode(data)
        # Highly compressible sample -> 1 DATA frame + 2 PARITY = 3 frames.
        self.assertEqual(len(result.frames), 3)
        self.assertEqual(result.stats.group_count, 1)
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_encrypted_roundtrip(self):
        data = _sample_text(50)
        result = mo.encode(data, "correct horse battery staple")
        blobs = [f.to_bytes() for f in result.frames]
        self.assertEqual(mo.decode(blobs, "correct horse battery staple"), data)
        # Encrypted payload is not human-readable when scanned.
        self.assertNotIn(b"Middle Out encodes", b"".join(blobs))

    def test_plain_payload_is_readable(self):
        # Unencrypted frames carry compressed (not encrypted) bytes; the
        # compressed stream is opaque, but the frame headers are plain and
        # the payload is recoverable without a secret.
        data = _sample_text(5)
        result = mo.encode(data)
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_empty_file(self):
        self.assertEqual(mo.decode([f.to_bytes() for f in mo.encode(b"").frames]), b"")

    def test_random_data_multi_group(self):
        # Incompressible data forces several groups; use a small payload so
        # the test stays fast.
        data = os.urandom(200_000)
        result = mo.encode(data, max_payload=16_384)
        self.assertGreater(result.stats.group_count, 1)
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_frame_header_fields(self):
        data = _sample_text()
        frame = mo.encode(data).frames[0]
        self.assertEqual(frame.original_size, len(data))
        self.assertEqual(frame.original_sha256, hashlib.sha256(data).digest())
        self.assertEqual(frame.total_groups, 1)
        self.assertEqual(frame.total_data_frames, 1)
        self.assertEqual(len(frame.to_bytes()), mo.HEADER_SIZE + len(frame.payload) + 4)


class ParityTests(unittest.TestCase):
    def _multi_frame_encode(self):
        # Random (incompressible) data sized to compress into exactly 6 data
        # frames: one full group = 6 DATA + 2 PARITY = 8 frames. The -64
        # leaves room for zlib's stored-block overhead so no 7th frame
        # appears.
        data = os.urandom(6 * 1024 - 64)
        result = mo.encode(data, max_payload=1024)
        self.assertEqual(result.stats.frame_count, 8)
        self.assertEqual(result.frames[0].total_data_frames, 6)
        return data, result

    def test_lose_one_data_frame_per_trio(self):
        data, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames]
        # Drop data frame 1 (trio A) and data frame 4 (trio B).
        kept = [b for i, b in enumerate(blobs) if i not in (1, 4)]
        self.assertEqual(mo.decode(kept), data)

    def test_lose_last_frame(self):
        data, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames]
        kept = blobs[:5] + blobs[6:]  # drop data frame 5 (last, short)
        self.assertEqual(mo.decode(kept), data)

    def test_lose_first_frame(self):
        data, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames]
        self.assertEqual(mo.decode(blobs[1:]), data)

    def test_corrupt_payload_recovers(self):
        data, result = self._multi_frame_encode()
        blobs = [bytearray(f.to_bytes()) for f in result.frames]
        # Flip a payload byte in data frame 2 (CRC will fail -> treated lost).
        blobs[2][mo.HEADER_SIZE + 10] ^= 0xFF
        self.assertEqual(mo.decode([bytes(b) for b in blobs]), data)

    def test_lose_two_in_one_trio_fails(self):
        _, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames]
        kept = [b for i, b in enumerate(blobs) if i not in (0, 2)]
        with self.assertRaises(mo.UnrecoverableError):
            mo.decode(kept)

    def test_lose_data_and_its_parity_fails(self):
        _, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames]
        # Data frame 0 + parity A (index 6) both gone.
        kept = [b for i, b in enumerate(blobs) if i not in (0, 6)]
        with self.assertRaises(mo.UnrecoverableError):
            mo.decode(kept)

    def test_lose_parity_only_is_fine(self):
        data, result = self._multi_frame_encode()
        blobs = [f.to_bytes() for f in result.frames if f.is_data]
        self.assertEqual(len(blobs), 6)
        self.assertEqual(mo.decode(blobs), data)


class VerificationTests(unittest.TestCase):
    def test_wrong_passphrase_fails(self):
        data = _sample_text(20)
        result = mo.encode(data, "right-passphrase")
        with self.assertRaises(mo.VerificationError):
            mo.decode([f.to_bytes() for f in result.frames], "wrong-passphrase")

    def test_missing_passphrase_fails(self):
        data = _sample_text(20)
        result = mo.encode(data, "secret")
        with self.assertRaises(mo.VerificationError):
            mo.decode([f.to_bytes() for f in result.frames])

    def test_tampered_header_crc_rejected(self):
        data = _sample_text(5)
        blobs = [bytearray(f.to_bytes()) for f in mo.encode(data).frames]
        blobs[0][20] ^= 0xFF  # inside the header
        # Header-corrupt frame is dropped as unreadable; parity rebuilds it.
        self.assertEqual(mo.decode([bytes(b) for b in blobs]), data)

    def test_no_frames_fails(self):
        with self.assertRaises(mo.UnrecoverableError):
            mo.decode([])


class CodeImageTests(unittest.TestCase):
    def test_grid_image_roundtrip(self):
        data = _sample_text(10)
        frame = mo.encode(data).frames[0]
        raw = frame.to_bytes()
        grid = mo.build_grid(raw)
        img = mo.render_grid_image(grid, module_px=4)
        self.assertEqual(mo.parse_grid(mo.sample_grid_image(img, module_px=4)), raw)

    def test_grid_roundtrip_no_image(self):
        raw = os.urandom(5000)
        self.assertEqual(mo.parse_grid(mo.build_grid(raw)), raw)

    def test_barcode_image_roundtrip(self):
        data = _sample_text(10)
        frame = mo.encode(data).frames[0]
        raw = frame.to_bytes()
        rows = mo.build_barcode_rows(raw)
        img = mo.render_barcode_image(rows)
        self.assertEqual(mo.parse_barcode_rows(mo.sample_barcode_image(img)), raw)

    def test_barcode_rows_reorder(self):
        raw = os.urandom(300)
        rows = mo.build_barcode_rows(raw)
        rows.reverse()
        self.assertEqual(mo.parse_barcode_rows(rows), raw)

    def test_centre_tile_is_clear(self):
        grid = mo.build_grid(os.urandom(100))
        n = len(grid)
        r0, c0, side = mo._centre_tile(n)
        for r in range(r0, r0 + side):
            for c in range(c0, c0 + side):
                self.assertEqual(grid[r][c], 0, "centre tile must stay white for the logo")


class PdfTests(unittest.TestCase):
    def test_pdf_build_and_decode_back(self):
        if shutil.which("pdfimages") is None:
            self.skipTest("pdfimages (poppler) not installed")
        data = _sample_text(30)
        result = mo.encode(data, "pdf-passphrase")
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            stats = mo.build_pdf(result, "demo.txt", pdf_path)
            self.assertEqual(stats.pages, 1 + len(result.frames))
            self.assertEqual(stats.frames, 3)  # 1 DATA + 2 PARITY
            # Structural check: the PDF really has 4 pages.
            with open(pdf_path, "rb") as fh:
                pdf_bytes = fh.read()
            pages = len(re.findall(rb"/Type\s*/Page[^s]", pdf_bytes))
            self.assertEqual(pages, 4)
            # Full loop: PDF -> images -> frames -> original bytes.
            self.assertEqual(mo.decode_pdf(pdf_path, "pdf-passphrase"), data)

    def test_pdf_barcode_mode(self):
        if shutil.which("pdfimages") is None:
            self.skipTest("pdfimages (poppler) not installed")
        data = _sample_text(10)
        result = mo.encode(data, barcode=True)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out-bc.pdf")
            stats = mo.build_pdf(result, "demo.txt", pdf_path)
            self.assertEqual(stats.pages, 4)  # 1 cover + 3 frames
            self.assertEqual(mo.decode_pdf(pdf_path), data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
