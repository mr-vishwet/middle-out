#!/usr/bin/env python3
"""Tests for the Middle Out Python reference codec.

Run:  python3 test_codec_reference.py

Covers: ChaCha20 RFC 8439 vector, encode/decode round-trip (plain +
encrypted, grid + barcode), parity recovery (one lost frame per trio),
failure modes (two lost in a trio, wrong passphrase, tampered payload),
rectangular grid geometry (capacity formula proven against an
independent count), grid/bar-grid image round-trips, polarity detection,
and full PDF build + decode-back (light/dark x QR/barcode, full 64 KiB
frames, plus the golden old-format fixtures).
"""

import hashlib
import os
import re
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


def _v1_frame_bytes(
    frame_index,
    kind,
    group_index,
    slot,
    flags,
    total_groups,
    total_data_frames,
    original_size,
    compressed_size,
    sha256,
    payload,
):
    """Serialise one frame in the legacy v1 wire format (97-byte header,
    uint8 indices) so the decoder's v1 compatibility can be tested.
    Encoders never write v1 — only this helper does."""
    header_wo_crc = struct.pack(
        ">4sBBBBBBBHIQQ32s16s12s",
        mo.MAGIC,
        1,
        frame_index,
        kind,
        group_index,
        slot,
        flags,
        total_groups,
        total_data_frames,
        len(payload),
        original_size,
        compressed_size,
        sha256,
        bytes(16),
        bytes(12),
    )
    header = header_wo_crc + struct.pack(
        ">I", zlib.crc32(header_wo_crc) & 0xFFFFFFFF
    )
    return (
        header
        + payload
        + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
    )


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

    def test_v2_header_roundtrips_indices_above_255(self):
        frame = mo.Frame(
            frame_index=300,
            kind=mo.KIND_DATA,
            group_index=40,
            slot=3,
            flags=mo.FLAG_ENCRYPTED,
            total_groups=50,
            total_data_frames=300,
            original_size=123456789,
            compressed_size=98765432,
            original_sha256=bytes(32),
            salt=bytes(16),
            nonce=bytes(12),
            payload=bytes(100),
        )
        raw = frame.to_bytes()
        self.assertEqual(raw[4], mo.VERSION)
        self.assertEqual(len(raw), mo.HEADER_SIZE + 100 + 4)
        parsed = mo.Frame.from_bytes(raw)
        self.assertEqual(parsed.frame_index, 300)
        self.assertEqual(parsed.group_index, 40)
        self.assertEqual(parsed.total_groups, 50)
        self.assertEqual(parsed.total_data_frames, 300)
        self.assertEqual(parsed.original_size, 123456789)
        self.assertEqual(parsed.compressed_size, 98765432)

    def test_v1_frame_parses(self):
        raw = _v1_frame_bytes(
            200, mo.KIND_DATA, 30, 2, mo.FLAG_LAST_GROUP, 40, 200,
            1234567, 765432, bytes(32), b"\x01\x02\x03\x04",
        )
        parsed = mo.Frame.from_bytes(raw)
        self.assertEqual(parsed.frame_index, 200)
        self.assertEqual(parsed.group_index, 30)
        self.assertEqual(parsed.total_groups, 40)
        self.assertEqual(parsed.total_data_frames, 200)
        self.assertEqual(parsed.original_size, 1234567)
        self.assertEqual(parsed.payload, b"\x01\x02\x03\x04")

    def test_v1_blobs_decode(self):
        # A tiny one-group encode in the v1 wire format still decodes.
        data = _sample_text(40)
        compressed = zlib.compress(data, 9)
        sha = hashlib.sha256(data).digest()
        blobs = [
            _v1_frame_bytes(
                0, mo.KIND_DATA, 0, 0, mo.FLAG_LAST_GROUP, 1, 1,
                len(data), len(compressed), sha, compressed,
            ),
            _v1_frame_bytes(
                1, mo.KIND_PARITY, 0, mo.PARITY_A_SLOT, mo.FLAG_LAST_GROUP,
                1, 1, len(data), len(compressed), sha, compressed,
            ),
            _v1_frame_bytes(
                2, mo.KIND_PARITY, 0, mo.PARITY_B_SLOT, mo.FLAG_LAST_GROUP,
                1, 1, len(data), len(compressed), sha, b"",
            ),
        ]
        self.assertEqual(mo.decode(blobs), data)

    def test_more_than_256_frames_roundtrip(self):
        # 13 MiB of incompressible data needs ~279 frames at the default
        # 64 KiB payload — over the old 256 cap, under the 4096 cap.
        data = os.urandom(13 * 1024 * 1024)
        result = mo.encode(data)
        self.assertGreater(len(result.frames), 256)
        self.assertEqual(
            mo.decode([f.to_bytes() for f in result.frames]), data
        )

    def test_over_cap_raises(self):
        # A 1 KiB payload forces ~6,800 frames out of 5 MiB.
        data = os.urandom(5 * 1024 * 1024)
        with self.assertRaises(mo.CodecError) as ctx:
            mo.encode(data, max_payload=1024)
        self.assertIn("4096", str(ctx.exception))
        self.assertIn("Split", str(ctx.exception))


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


def _reserved_cells_independent(w, h):
    """Reserved cells by brute-force enumeration of the three regions
    (finders, timing, centre tile) — an INDEPENDENT implementation of
    the geometry, used to prove the arithmetic capacity formula and the
    O(1) is_reserved checks. Returns (finders, timing, centre) sets."""
    finders = set()
    for r0, c0 in ((0, 0), (0, w - 8), (h - 8, 0)):
        for r in range(r0, r0 + 8):
            for c in range(c0, c0 + 8):
                finders.add((r, c))
    timing = set()
    for i in range(8, w - 8):
        timing.add((6, i))
    for i in range(8, h - 8):
        timing.add((i, 6))
    if w == h:
        # Square grids keep the original rule: side = max(8, n//4).
        side = max(8, min(w, h) // 4)
        sr, sc = (h - side) // 2, (w - side) // 2
        centre = {(r, c) for r in range(sr, sr + side)
                  for c in range(sc, sc + side)}
    else:
        # Landscape grids: the tile is square AS DRAWN (in points).
        # Half-up rounding, re-derived here (not via mo._half_up) so
        # this stays an independent implementation.
        tw = max(8, int(w * mo.CODE_PAGE_HEIGHT
                        / (mo.BARCODE_STRETCH * mo.CODE_PAGE_WIDTH) + 0.5))
        th = max(8, int(h / 4 + 0.5))
        sr, sc = (h - th) // 2, (w - tw) // 2
        centre = {(r, c) for r in range(sr, sr + th)
                  for c in range(sc, sc + tw)}
    return finders, timing, centre


class GeometryTests(unittest.TestCase):
    def test_capacity_formula_matches_independent_count(self):
        # The three reserved regions never overlap for w,h >= 32, so the
        # capacity is pure arithmetic. Prove it against the brute-force
        # enumeration at every stepped height (square + QR + bar aspect)
        # and at full-frame sizes.
        sizes = []
        for h in range(32, 130, 2):
            sizes.append((h, h))  # old square
            sizes.append((max(32, int(h * mo.QR_ASPECT + 0.5)), h))
            sizes.append((max(32, int(h * mo.BARCODE_ASPECT + 0.5)), h))
        sizes += [(885, 626), (1742, 308), (1776, 314)]  # full 64 KiB frame grids
        for w, h in sizes:
            finders, timing, centre = _reserved_cells_independent(w, h)
            self.assertFalse(finders & timing, f"finder/timing overlap at {w}x{h}")
            self.assertFalse(finders & centre, f"finder/centre overlap at {w}x{h}")
            self.assertFalse(timing & centre, f"timing/centre overlap at {w}x{h}")
            union = finders | timing | centre
            self.assertEqual(len(finders), 192)
            self.assertEqual(len(timing), (w - 16) + (h - 16))
            self.assertEqual(
                w * h - len(union), mo.grid_capacity_bits(w, h), f"at {w}x{h}"
            )

    def test_is_reserved_matches_regions(self):
        # The O(1) range checks must agree with the enumerated regions at
        # EVERY cell, for a small grid of each aspect.
        for w, h in ((32, 32), (45, 32), (181, 32), (100, 70)):
            finders, timing, centre = _reserved_cells_independent(w, h)
            reserved = finders | timing | centre
            sr, sc, tw, th = mo._centre_tile(w, h)
            for r in range(h):
                for c in range(w):
                    self.assertEqual(
                        mo.is_reserved(r, c, w, h, sr, sc, tw, th),
                        (r, c) in reserved,
                        f"cell {(r, c)} at {w}x{h}",
                    )

    def test_choose_grid_size_rectangular(self):
        # Aspect, minimality, and the pinned full-frame sizes (the Dart
        # side must produce these exact numbers too).
        for payload_len, aspect in (
            (0, mo.QR_ASPECT),
            (100, mo.QR_ASPECT),
            (5000, mo.QR_ASPECT),
            (65640, mo.QR_ASPECT),
            (100, mo.BARCODE_ASPECT),
            (65640, mo.BARCODE_ASPECT),
        ):
            w, h = mo.choose_grid_size(payload_len, aspect)
            self.assertGreaterEqual(w, 32)
            self.assertGreaterEqual(h, 32)
            self.assertAlmostEqual(w / h, aspect, delta=aspect * 0.02)
            need = (payload_len + 4) * 8
            self.assertGreaterEqual(mo.grid_capacity_bits(w, h), need)
            if h > 32:
                w_prev = max(32, int((h - 2) * aspect + 0.5))
                self.assertLess(
                    mo.grid_capacity_bits(w_prev, h - 2), need,
                    "a smaller grid must not fit (minimality)",
                )
        # A full frame is header 100 + payload 65536 + CRC 4 = 65640 bytes.
        # The bar grid grew (1742x308 -> 1776x314) when the centre tile
        # went square-as-drawn: the bar tile is now 308x77 = 23,716
        # cells instead of 77x77 = 5,929, so the old size no longer fits.
        self.assertEqual(mo.choose_grid_size(65640), (885, 626))
        self.assertEqual(mo.choose_grid_size(65640, mo.BARCODE_ASPECT), (1776, 314))

    def test_centre_tile_geometry(self):
        # Landscape QR: tile 156x157, nearly unchanged from the old
        # 156x156 rule.
        sr, sc, tw, th = mo._centre_tile(885, 626)
        self.assertEqual((tw, th), (156, 157))
        self.assertEqual((sr, sc), ((626 - 157) // 2, (885 - 156) // 2))
        # Small landscape grid: both dimensions clamp to the 8 minimum.
        sr, sc, tw, th = mo._centre_tile(45, 32)
        self.assertEqual((tw, th), (8, 8))
        self.assertEqual((sr, sc), (12, 18))
        # Landscape bar grid at the old full-frame size: 308x77 modules.
        sr, sc, tw, th = mo._centre_tile(1742, 308)
        self.assertEqual((tw, th), (308, 77))
        self.assertEqual((sr, sc), (115, 717))

    def test_centre_tile_square_rule_unchanged(self):
        # Square grids (w == h — the old format) keep the original
        # rule, side = max(8, n//4), tileW = tileH = side. Pinned so a
        # future change to the landscape rule cannot silently move
        # old-format goldens.
        for n, side in ((32, 8), (100, 25), (200, 50), (626, 156)):
            sr, sc, tw, th = mo._centre_tile(n, n)
            self.assertEqual((tw, th), (side, side), f"at {n}x{n}")
            self.assertEqual((sr, sc), ((n - side) // 2, (n - side) // 2))

    def test_half_up_rounding(self):
        # Half-up, not banker's: .5 rounds UP, matching Dart's
        # double.round(). Python's round() would give 78 for both.
        self.assertEqual(mo._half_up(77.5), 78)
        self.assertEqual(mo._half_up(78.5), 79)
        self.assertEqual(round(78.5), 78)  # the trap this avoids
        # And it shows up in real tile heights: h=310 -> 77.5 -> 78.
        self.assertEqual(mo._centre_tile(1754, 310)[3], 78)
        self.assertEqual(mo._centre_tile(1776, 314)[3], 79)

    def test_centre_tile_square_as_drawn(self):
        # The tile must be square IN POINTS on the page for both
        # formats — this is the fix for the tall white pillar. Module
        # quantisation leaves up to ~1 pt of slack (the QR tile is
        # 156x157 modules = 148.4x149.3 pt, 0.6% off square).
        for w, h in ((885, 626), (1742, 308), (1776, 314)):
            _, _, tw, th = mo._centre_tile(w, h)
            tile_w_pt = tw / w * mo.CODE_PAGE_WIDTH
            tile_h_pt = th / h * mo.CODE_PAGE_HEIGHT
            self.assertAlmostEqual(tile_w_pt, tile_h_pt, delta=1.0,
                                   msg=f"tile not square as drawn at {w}x{h}")
        # Bar tile is ~148.8 pt square (was a 37x149 pt pillar).
        _, _, tw, th = mo._centre_tile(1742, 308)
        self.assertAlmostEqual(tw / 1742 * mo.CODE_PAGE_WIDTH, 148.8, delta=0.5)
        self.assertAlmostEqual(th / 308 * mo.CODE_PAGE_HEIGHT, 148.8, delta=0.5)

    def test_bar_tile_far_from_finders_and_timing(self):
        # Explicit no-overlap proof for the new wide bar tile at both
        # the old and new full-frame sizes: finders live in the 8-cell
        # corners, timing on row/col 6 — the tile is far from all of
        # them. (The capacity test also proves it by enumeration.)
        for w, h, (sr, sc, tw, th) in (
            (1742, 308, (115, 717, 308, 77)),
            (1776, 314, (117, 731, 314, 79)),
        ):
            self.assertEqual(mo._centre_tile(w, h), (sr, sc, tw, th))
            # Tile rows 115-192 / 117-196: clear of row 6 and the
            # 8-cell finder bands (rows 0-7 and h-8..h-1).
            self.assertGreater(sr, 8)
            self.assertLess(sr + th, h - 8)
            # Tile cols 717-1025 / 731-1045: clear of col 6 and the
            # finder bands (cols 0-7 and w-8..w-1).
            self.assertGreater(sc, 8)
            self.assertLess(sc + tw, w - 8)


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

    def test_grid_roundtrip_empty_payload(self):
        self.assertEqual(mo.parse_grid(mo.build_grid(b"")), b"")

    def test_grid_roundtrip_square_aspect(self):
        # Old square grids (aspect 1.0) parse through the same code path.
        raw = os.urandom(3000)
        grid = mo.build_grid(raw, aspect=1.0)
        self.assertEqual(len(grid), len(grid[0]))
        self.assertEqual(mo.parse_grid(grid), raw)

    def test_barcode_grid_roundtrip(self):
        raw = os.urandom(5000)
        grid = mo.build_barcode_grid(raw)
        w, h = len(grid[0]), len(grid)
        self.assertAlmostEqual(w / h, mo.BARCODE_ASPECT, delta=mo.BARCODE_ASPECT * 0.02)
        self.assertEqual(mo.parse_grid(grid), raw)

    def test_barcode_grid_full_frame_roundtrip(self):
        frame = mo.encode(os.urandom(64 * 1024)).frames[0]
        raw = frame.to_bytes()
        self.assertEqual(len(raw), 65640)  # a full 64 KiB frame
        grid = mo.build_barcode_grid(raw)
        self.assertEqual((len(grid[0]), len(grid)), (1776, 314))
        self.assertEqual(mo.parse_grid(grid), raw)

    def test_grid_full_frame_roundtrip(self):
        frame = mo.encode(os.urandom(64 * 1024)).frames[0]
        raw = frame.to_bytes()
        grid = mo.build_grid(raw)
        self.assertEqual((len(grid[0]), len(grid)), (885, 626))
        self.assertEqual(mo.parse_grid(grid), raw)

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

    def test_barcode_full_frame_roundtrip(self):
        # A full 64 KiB frame needs 1,026 barcode rows; the 8-bit row
        # index wraps at 256, so reassembly must fall back to list
        # order (parity with the Dart fix in lib/codec/code_grid.dart).
        frame = mo.encode(os.urandom(64 * 1024)).frames[0]
        raw = frame.to_bytes()
        rows = mo.build_barcode_rows(raw)
        self.assertEqual(len(rows), 1026)
        self.assertEqual(mo.parse_barcode_rows(rows), raw)

    def test_centre_tile_is_clear(self):
        for grid in (mo.build_grid(os.urandom(100)),
                     mo.build_barcode_grid(os.urandom(100))):
            h, w = len(grid), len(grid[0])
            r0, c0, tw, th = mo._centre_tile(w, h)
            for r in range(r0, r0 + th):
                for c in range(c0, c0 + tw):
                    self.assertEqual(grid[r][c], 0, "centre tile must stay white for the logo")

    def test_polarity_detection_grid(self):
        grid = mo.build_grid(b"polarity probe")
        self.assertFalse(mo.grid_is_dark(grid))
        inverted = mo._invert_matrix(grid)
        self.assertTrue(mo.grid_is_dark(inverted))
        # An inverted grid must not parse to the payload — polarity
        # detection (not luck) is what makes dark pages decode.
        with self.assertRaises(mo.CodecError):
            mo.parse_grid(inverted)

    def test_pack_1bit_roundtrip(self):
        grid = mo.build_grid(os.urandom(1000))
        packed = mo.pack_1bit(grid)
        w = len(grid[0])
        stride = (w + 7) // 8
        rows = [packed[y * stride:(y + 1) * stride] for y in range(len(grid))]
        back = [bytearray(b"".join(mo._BIT_EXPAND[b] for b in row)[:w]) for row in rows]
        self.assertEqual(back, grid)
        # Dark (inverted) packing expands to the inverted grid.
        packed_dark = mo.deflate_1bit(grid, invert=True)
        raw_dark = zlib.decompress(packed_dark)
        rows_dark = [raw_dark[y * stride:(y + 1) * stride] for y in range(len(grid))]
        back_dark = [bytearray(b"".join(mo._BIT_EXPAND[b] for b in row)[:w])
                     for row in rows_dark]
        self.assertEqual(back_dark, mo._invert_matrix(grid))

    def test_logo_const_matches_app_icon(self):
        # The embedded 64x64 logo pixels: black corners, a white M block,
        # and the green dot at the centre.
        px = mo.LOGO_RGB_PIXELS
        self.assertEqual(len(px), 64 * 64 * 3)
        self.assertEqual(px[0:3], b"\x00\x00\x00")  # top-left corner: black
        centre = (32 * 64 + 32) * 3
        r, g, b = px[centre], px[centre + 1], px[centre + 2]
        self.assertGreater(g, 200)  # green dot: strong green channel
        self.assertGreater(r, 150)
        self.assertLess(b, 120)


def _golden_original() -> bytes:
    # Mirrors goldenOriginal() in test/pdf_build_roundtrip_test.dart.
    return ("Middle Out golden fixture \u2014 old-format PDF. " * 600).encode("utf-8")


def _pdf_content_streams(pdf_bytes: bytes) -> list[bytes]:
    """All FlateDecode content streams, decompressed (page operators)."""
    streams = []
    for m in re.finditer(rb"stream\n(.*?)endstream", pdf_bytes, re.S):
        try:
            streams.append(zlib.decompress(m.group(1).rstrip(b"\n")))
        except zlib.error:
            pass  # image streams are packed bits, not operators
    return streams


class PdfTests(unittest.TestCase):
    def test_pdf_build_and_decode_back(self):
        data = _sample_text(30)
        result = mo.encode(data, "pdf-passphrase")
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            stats = mo.build_pdf(result, "demo.txt", pdf_path)
            self.assertEqual(stats.pages, 1 + len(result.frames))
            self.assertEqual(stats.frames, 3)  # 1 DATA + 2 PARITY
            with open(pdf_path, "rb") as fh:
                pdf_bytes = fh.read()
            # Structural check: the PDF really has 4 pages.
            pages = len(re.findall(rb"/Type\s*/Page[^s]", pdf_bytes))
            self.assertEqual(pages, 4)
            # Full loop: PDF -> images -> frames -> original bytes.
            self.assertEqual(mo.decode_pdf(pdf_path, "pdf-passphrase"), data)

    def test_pdf_barcode_mode(self):
        data = _sample_text(10)
        result = mo.encode(data, barcode=True)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out-bc.pdf")
            stats = mo.build_pdf(result, "demo.txt", pdf_path)
            self.assertEqual(stats.pages, 4)  # 1 cover + 3 frames
            self.assertEqual(mo.decode_pdf(pdf_path), data)

    def test_pdf_full_bleed_structure(self):
        # Code pages are landscape with the image over the whole rect;
        # the cover stays portrait; every frame page carries the RGB logo.
        data = _sample_text(10)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            with open(pdf_path, "rb") as fh:
                pdf_bytes = fh.read()
        mediaboxes = re.findall(rb"/MediaBox \[[^\]]*\]", pdf_bytes)
        self.assertEqual(mediaboxes[0], b"/MediaBox [0 0 595.28 841.89]")  # cover
        for box in mediaboxes[1:]:
            self.assertEqual(box, b"/MediaBox [0 0 841.89 595.28]")  # code pages
        # The code image is drawn over the entire 841.89 x 595.28 rect.
        operators = b"\n".join(_pdf_content_streams(pdf_bytes))
        self.assertEqual(operators.count(b"841.89 0 0 595.28 0 0 cm /Im0 Do"), 3)
        # No caption text on code pages: the only text operators are the
        # cover's (title + subtitle + 8 manifest lines = 10).
        self.assertEqual(operators.count(b" Tj ET"), 10)
        # One 1-bit code image per frame page + ONE shared 64x64 RGB logo.
        self.assertEqual(pdf_bytes.count(b"/BitsPerComponent 1 /ColorSpace /DeviceGray"), 3)
        self.assertEqual(
            pdf_bytes.count(b"/Width 64 /Height 64 /BitsPerComponent 8 /ColorSpace /DeviceRGB"),
            1,
        )
        # The logo is drawn once per frame page, inside a rounded-rect clip.
        self.assertEqual(operators.count(b"/Im1 Do"), 3)
        self.assertEqual(operators.count(b"h W n"), 3)

    def test_pdf_dark_pages_have_black_background(self):
        data = _sample_text(5)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            light = os.path.join(tmp, "light.pdf")
            dark = os.path.join(tmp, "dark.pdf")
            mo.build_pdf(result, "demo.txt", light, dark=False)
            mo.build_pdf(result, "demo.txt", dark, dark=True)
            light_ops = b"\n".join(_pdf_content_streams(open(light, "rb").read()))
            dark_ops = b"\n".join(_pdf_content_streams(open(dark, "rb").read()))
            self.assertNotIn(b"0 g 0 0 841.89 595.28 re f", light_ops)
            self.assertEqual(dark_ops.count(b"0 g 0 0 841.89 595.28 re f"), 3)
            self.assertEqual(mo.decode_pdf(dark), data)

    def test_pdf_logo_tile_is_skipped_by_extractor(self):
        data = _sample_text(5)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            pdf_bytes = open(pdf_path, "rb").read()
        extraction = mo.extract_pdf_frames(pdf_bytes)
        # One code image per frame page + one shared RGB logo, but only
        # the 1-bit code images are attempted — the logo is never parsed.
        self.assertEqual(extraction.images_found, len(result.frames) + 1)
        self.assertEqual(extraction.images_parsed, len(result.frames))
        self.assertEqual(len(extraction.frames), len(result.frames))

    def test_logo_rect_is_square_and_inside_tile(self):
        # QR grid: the tile is square, the logo fills it exactly.
        x, y, w, h = mo.logo_rect_for_grid(885, 626)
        self.assertAlmostEqual(w, h, places=6)
        self.assertAlmostEqual(w, 148.4, delta=0.5)
        # Bar-grid: the tile is square AS DRAWN (308x77 modules =
        # 148.8x148.8 pt), so the logo fills the whole tile — no more
        # 37 pt square in a 149 pt tall pillar.
        x, y, w, h = mo.logo_rect_for_grid(1742, 308)
        self.assertAlmostEqual(w, h, places=6)
        self.assertAlmostEqual(w, 148.8, delta=0.5)
        sr, sc, tw, th = mo._centre_tile(1742, 308)
        tile_x = sc / 1742 * mo.CODE_PAGE_WIDTH
        tile_w = tw / 1742 * mo.CODE_PAGE_WIDTH
        tile_bottom = mo.CODE_PAGE_HEIGHT - (sr + th) / 308 * mo.CODE_PAGE_HEIGHT
        tile_h = th / 308 * mo.CODE_PAGE_HEIGHT
        self.assertAlmostEqual(x, tile_x + (tile_w - w) / 2, places=6)
        self.assertAlmostEqual(y, tile_bottom + (tile_h - w) / 2, places=6)

    def test_pdf_full_frame_roundtrips_light_dark_qr_barcode(self):
        # All 4 combinations, with full 64 KiB frames: 64 KiB of random
        # data compresses to 2 data frames (the first a full 65536-byte
        # payload) + 2 parity in one group = 4 frames.
        data = os.urandom(64 * 1024)
        for barcode in (False, True):
            for dark in (False, True):
                with self.subTest(barcode=barcode, dark=dark):
                    result = mo.encode(data, barcode=barcode)
                    self.assertEqual(len(result.frames), 4)
                    self.assertEqual(len(result.frames[0].payload), 65536)
                    with tempfile.TemporaryDirectory() as tmp:
                        pdf_path = os.path.join(tmp, "out.pdf")
                        stats = mo.build_pdf(result, "full.bin", pdf_path, dark=dark)
                        self.assertEqual(stats.pages, 5)
                        self.assertEqual(mo.decode_pdf(pdf_path), data)

    def test_pdf_old_format_grid_still_decodes(self):
        fixture = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "test", "fixtures", "old_format_grid.pdf",
        )
        if not os.path.exists(fixture):
            self.skipTest("golden fixture not present")
        with open(fixture, "rb") as fh:
            pdf_bytes = fh.read()
        # Prove this is genuinely old-format: 8-bit RGB + SMask.
        self.assertIn(b"/BitsPerComponent 8", pdf_bytes)
        self.assertIn(b"/DeviceRGB", pdf_bytes)
        extraction = mo.extract_pdf_frames(pdf_bytes)
        self.assertTrue(extraction.frames)
        self.assertEqual(mo.decode_pdf(fixture), _golden_original())

    def test_pdf_old_format_barcode_still_decodes(self):
        fixture = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "test", "fixtures", "old_format_barcode.pdf",
        )
        if not os.path.exists(fixture):
            self.skipTest("golden fixture not present")
        with open(fixture, "rb") as fh:
            pdf_bytes = fh.read()
        self.assertIn(b"/BitsPerComponent 8", pdf_bytes)
        self.assertIn(b"/DeviceRGB", pdf_bytes)
        extraction = mo.extract_pdf_frames(pdf_bytes)
        self.assertTrue(extraction.frames)
        self.assertEqual(mo.decode_pdf(fixture), _golden_original())


if __name__ == "__main__":
    unittest.main(verbosity=2)
