#!/usr/bin/env python3
"""Tests for the Middle Out Python reference codec.

Run:  python3 test_codec_reference.py

Covers: ChaCha20 RFC 8439 vector, encode/decode round-trip (plain +
encrypted, grid + barcode), equal-split framing (30-frame cap, zero-
padded last chunk, parity only for non-empty trios, 1-data-group
recovery, old-format fixed-chunk frames still decoding), parity
recovery (one lost frame per trio), failure modes (two lost in a trio,
wrong passphrase, tampered payload), rectangular grid geometry
(capacity formula proven against an independent count), grid/bar-grid
image round-trips, polarity detection, the cover QR const (finder
patterns, quiet zone, cv2 decode to the app URL), and full PDF build +
decode-back (light/dark x QR/barcode, branded landscape cover with
details only, cover-stripped and coverless PDFs still decoding, plus
the golden old-format fixtures and the Dart-built samples).
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
        # Highly compressible sample -> 1 DATA frame + P1 only (trio B
        # is empty, so there is no P2) = 2 frames.
        self.assertEqual(len(result.frames), 2)
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
        result = mo.encode(b"")
        # Empty input compresses to an 8-byte zlib stream: 1 data frame
        # + P1, no P2 (trio B empty).
        self.assertEqual(len(result.frames), 2)
        self.assertEqual(
            [(f.kind, f.slot) for f in result.frames],
            [(mo.KIND_DATA, 0), (mo.KIND_PARITY, mo.PARITY_A_SLOT)],
        )
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), b"")
        # The 0-byte stream edge itself: one empty chunk, and parity of
        # nothing is nothing — no parity frame is emitted for it.
        self.assertEqual(mo._split_equal(b"", mo.DEFAULT_MAX_PAYLOAD), [b""])

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

    def test_reencoded_flag_parses_and_decodes_identically(self):
        # FLAG_REENCODED (0x10) marks a lossy re-encoded copy: the
        # flag must survive a serialise/parse round-trip, the payload
        # must decode byte-identically, and unflagged frames must be
        # unaffected (old-format compatibility).
        self.assertEqual(mo.FLAG_REENCODED, 0x10)
        data = _sample_text()
        flagged = mo.encode(data, reencoded=True)
        plain = mo.encode(data)
        self.assertEqual(len(flagged.frames), len(plain.frames))
        for f_flag, f_plain in zip(flagged.frames, plain.frames):
            self.assertTrue(f_flag.is_reencoded)
            self.assertTrue(f_flag.flags & mo.FLAG_REENCODED)
            self.assertFalse(f_plain.is_reencoded)
            self.assertEqual(f_flag.flags & ~mo.FLAG_REENCODED,
                             f_plain.flags)
            self.assertEqual(f_flag.payload, f_plain.payload)
            raw = f_flag.to_bytes()
            parsed = mo.Frame.from_bytes(raw)
            self.assertTrue(parsed.is_reencoded)
            self.assertEqual(parsed.flags, f_flag.flags)
        self.assertEqual(
            mo.decode([f.to_bytes() for f in flagged.frames]), data)
        self.assertEqual(
            mo.decode([f.to_bytes() for f in plain.frames]), data)
        # The flag composes with the other flags (encrypted + barcode).
        enc = mo.encode(data, passphrase='pw', barcode=True, reencoded=True)
        self.assertTrue(all(f.is_reencoded for f in enc.frames))
        self.assertTrue(all(f.is_encrypted for f in enc.frames))
        self.assertTrue(all(f.is_barcode for f in enc.frames))
        self.assertEqual(
            mo.decode([f.to_bytes() for f in enc.frames], 'pw'), data)

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

    def test_large_file_caps_at_thirty_data_frames(self):
        # Equal-split caps an encode at 30 data frames: 5 MiB of
        # incompressible data with a 1 KiB unit would need ~5,120
        # chunks, but the cap holds it to 30 equal chunks (plus
        # parity), NOT ~5,120 fixed 64 KiB frames — every code page
        # is equally dense. (The old >256-frame test is obsolete: the
        # cap makes it unreachable through encode(); uint16 indices
        # above 255 are still covered by
        # test_v2_header_roundtrips_indices_above_255.)
        # The cap is forced with an explicit small max_payload: under
        # the default adaptive rule a 4.3 GB input would be needed to
        # reach it, which no unit test should allocate.
        data = os.urandom(5 * 1024 * 1024)
        result = mo.encode(data, max_payload=1024)
        data_frames = [f for f in result.frames if f.is_data]
        self.assertEqual(len(data_frames), 30)
        chunk_size = (result.stats.compressed_size + 29) // 30
        self.assertTrue(all(len(f.payload) == chunk_size for f in data_frames))
        self.assertEqual(result.stats.group_count, 5)
        # 5 full groups (2 parities each) = 30 data + 10 parity.
        self.assertEqual(len(result.frames), 40)
        self.assertEqual(
            mo.decode([f.to_bytes() for f in result.frames]), data
        )

    def test_small_max_payload_still_caps_at_thirty(self):
        # Even a 1 KiB max_payload cannot force more than 30 data
        # frames: the cap, not the payload size, bounds the frame count.
        # (The old over-cap test is obsolete for the same reason.)
        data = os.urandom(5 * 1024 * 1024)
        result = mo.encode(data, max_payload=1024)
        data_frames = [f for f in result.frames if f.is_data]
        self.assertEqual(len(data_frames), 30)
        self.assertEqual(
            mo.decode([f.to_bytes() for f in result.frames]), data
        )

    def test_data_page_count_grows_sublinearly(self):
        # Pure function — the whole adaptive rule, table-driven. The
        # 20,971,530 case is the zlib-overhead trap: a 20 MiB
        # incompressible file compresses to a hair over 20,971,520
        # bytes, and round (not ceil) keeps it on 2 pages. Must agree
        # with Dart's Encoder.dataPageCount exactly — byte-identical
        # chunking depends on it.
        cases = {
            0: 1,
            100 * 1024: 1,
            5 * 1024 * 1024: 1,
            15 * 1024 * 1024: 2,
            20 * 1024 * 1024: 2,
            20971530: 2,
            35 * 1024 * 1024: 3,
            100 * 1024 * 1024: 4,
            1073741824: 14,
            4566548480: 30,
            10737418240: 30,
            53687091200: 30,
        }
        for size, want in cases.items():
            self.assertEqual(
                mo.data_page_count(size), want, f"compressedSize {size}"
            )

    def test_twenty_mib_file_lands_on_two_data_pages(self):
        # The acceptance case: a real 20.1 MB mp4 encoded to 28 PDF
        # pages under the old 64 KiB-unit rule; under the adaptive rule
        # it is 2 data + 1 parity = 3 code pages + cover = 4 PDF pages.
        data = os.urandom(20 * 1024 * 1024)
        result = mo.encode(data)
        data_frames = [f for f in result.frames if f.is_data]
        self.assertEqual(len(data_frames), 2)
        # One group of 6 slots, 2 used: P1 emitted, P2 skipped
        # (empty trio) — 3 frames total.
        self.assertEqual(len(result.frames), 3)
        self.assertEqual(result.stats.group_count, 1)
        chunk_size = (result.stats.compressed_size + 1) // 2
        self.assertTrue(all(len(f.payload) == chunk_size for f in data_frames))
        self.assertEqual(
            mo.decode([f.to_bytes() for f in result.frames]), data
        )


def _old_style_encode(data, max_payload=mo.DEFAULT_MAX_PAYLOAD):
    """Hand-build frames the OLD way (fixed <= max_payload chunks, last
    frame short, NO equal-split flag, both parity frames always emitted
    — even an empty P2) so the decoder's legacy path can be tested.
    The encoder never writes this format any more."""
    sha = hashlib.sha256(data).digest()
    stream = zlib.compress(data, 9)
    chunks = [stream[i : i + max_payload] for i in range(0, len(stream), max_payload)]
    if not chunks:
        chunks = [b""]
    total_data = len(chunks)
    total_groups = (total_data + mo.GROUP_DATA_FRAMES - 1) // mo.GROUP_DATA_FRAMES
    frames = []
    for group in range(total_groups):
        group_chunks = chunks[
            group * mo.GROUP_DATA_FRAMES : (group + 1) * mo.GROUP_DATA_FRAMES
        ]
        group_flags = mo.FLAG_LAST_GROUP if group == total_groups - 1 else 0
        for slot, chunk in enumerate(group_chunks):
            frames.append(
                mo.Frame(
                    frame_index=group * mo.GROUP_DATA_FRAMES + slot,
                    kind=mo.KIND_DATA,
                    group_index=group,
                    slot=slot,
                    flags=group_flags,
                    total_groups=total_groups,
                    total_data_frames=total_data,
                    original_size=len(data),
                    compressed_size=len(stream),
                    original_sha256=sha,
                    salt=bytes(16),
                    nonce=bytes(12),
                    payload=chunk,
                )
            )
        for trio, parity_slot in (
            (mo.PARITY_A_TRIO, mo.PARITY_A_SLOT),
            (mo.PARITY_B_TRIO, mo.PARITY_B_SLOT),
        ):
            present = [group_chunks[s] for s in trio if s < len(group_chunks)]
            if present:
                width = max(len(c) for c in present)
                parity = bytes(width)
                for chunk in present:
                    parity = bytes(
                        x ^ y for x, y in zip(parity, chunk + bytes(width - len(chunk)))
                    )
            else:
                parity = b""
            frames.append(
                mo.Frame(
                    frame_index=total_data
                    + group * mo.GROUP_PARITY_FRAMES
                    + (parity_slot - mo.PARITY_A_SLOT),
                    kind=mo.KIND_PARITY,
                    group_index=group,
                    slot=parity_slot,
                    flags=group_flags,
                    total_groups=total_groups,
                    total_data_frames=total_data,
                    original_size=len(data),
                    compressed_size=len(stream),
                    original_sha256=sha,
                    salt=bytes(16),
                    nonce=bytes(12),
                    payload=parity,
                )
            )
    return frames


class EqualSplitTests(unittest.TestCase):
    def test_equal_split_chunking(self):
        # 200 KiB of random data with an explicit 64 KiB unit:
        # N = ceil(compressed/65536) = 4 equal chunks of
        # ceil(compressed/4); the last is padded to the same width, so
        # all four data payloads are equal. (The default adaptive rule
        # gives 1 page for 200 KiB; the unit is explicit here so the
        # test still exercises multi-page equal splitting.)
        data = os.urandom(200_000)
        result = mo.encode(data, max_payload=65536)
        data_frames = [f for f in result.frames if f.is_data]
        self.assertEqual(len(data_frames), 4)
        chunk_size = (result.stats.compressed_size + 3) // 4
        self.assertTrue(all(len(f.payload) == chunk_size for f in data_frames))
        # The flag is set on EVERY frame, data and parity alike.
        self.assertTrue(all(f.is_equal_split for f in result.frames))
        # The last chunk really is zero-padded (not short).
        last = data_frames[-1]
        real = result.stats.compressed_size - chunk_size * 3
        self.assertEqual(last.payload[real:], bytes(chunk_size - real))
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_equal_split_multi_page_roundtrip(self):
        # 1 MiB random with an explicit 64 KiB unit -> 17 data frames
        # in 3 groups (6+6+5), 6 parity frames: every group has both
        # trios non-empty, so P2 exists in all three groups. (N is
        # computed from the actual compressed size — stored-block
        # overhead pushes 1 MiB of random data just past 16 x 64 KiB.
        # The default adaptive rule gives 1 page for 1 MiB; the unit
        # is explicit here so the test still exercises multi-group
        # equal splitting.)
        data = os.urandom(1024 * 1024)
        result = mo.encode(data, max_payload=65536)
        data_frames = [f for f in result.frames if f.is_data]
        parity_frames = [f for f in result.frames if not f.is_data]
        expect_n = min(
            30,
            (result.stats.compressed_size + mo.DEFAULT_MAX_PAYLOAD - 1)
            // mo.DEFAULT_MAX_PAYLOAD,
        )
        self.assertEqual(len(data_frames), expect_n)
        self.assertEqual(result.stats.group_count, 3)
        self.assertEqual(len(parity_frames), 6)
        self.assertEqual(len(result.frames), expect_n + 6)
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_single_page_small_file(self):
        # A small file is 1 data frame + P1 only: trio B has no data
        # slot, so P2 is ABSENT (the old encoder always emitted an
        # empty P2 — that sparse page is gone).
        data = _sample_text(3)
        result = mo.encode(data)
        self.assertEqual(len(result.frames), 2)
        self.assertEqual(
            [(f.kind, f.slot) for f in result.frames],
            [(mo.KIND_DATA, 0), (mo.KIND_PARITY, mo.PARITY_A_SLOT)],
        )
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_three_data_frames_have_no_p2(self):
        # Exactly 3 data frames fill trio A and leave trio B empty:
        # P1 yes, P2 no. (Explicit 64 KiB unit: the default adaptive
        # rule gives 1 page for ~186 KiB.)
        data = os.urandom(3 * mo.DEFAULT_MAX_PAYLOAD - 10_000)
        result = mo.encode(data, max_payload=65536)
        data_frames = [f for f in result.frames if f.is_data]
        self.assertEqual(len(data_frames), 3)
        self.assertEqual(len(result.frames), 4)  # 3 data + P1
        self.assertEqual(
            sorted(f.slot for f in result.frames if not f.is_data),
            [mo.PARITY_A_SLOT],
        )
        self.assertEqual(mo.decode([f.to_bytes() for f in result.frames]), data)

    def test_lose_padded_last_frame_recovers(self):
        # Dropping the last (zero-padded) data frame must rebuild it
        # and trim it to its true short length — the padded bytes must
        # never reach the decompressor. (Explicit 64 KiB unit so there
        # are 4 data frames and the dropped index 3 is the padded last
        # one; the default adaptive rule gives 1 page for 200 KiB.)
        data = os.urandom(200_000)
        result = mo.encode(data, max_payload=65536)
        blobs = [
            f.to_bytes()
            for f in result.frames
            if not (f.is_data and f.frame_index == 3)
        ]
        self.assertEqual(mo.decode(blobs), data)

    def test_one_data_group_parity_recovery(self):
        # 1 data frame + P1: losing the only data frame rebuilds from
        # parity (the 1-data group case).
        data = _sample_text(10)
        result = mo.encode(data)
        self.assertEqual(len(result.frames), 2)
        blobs = [f.to_bytes() for f in result.frames if not f.is_data]
        self.assertEqual(mo.decode(blobs), data)

    def test_old_format_fixed_chunks_still_decode(self):
        # Old-format frames (fixed 64 KiB chunks, short last frame, NO
        # equal-split flag, empty P2 emitted) still decode through the
        # legacy derivation — including parity recovery of the short
        # last frame.
        data = os.urandom(200_000)
        frames = _old_style_encode(data)
        self.assertEqual(len([f for f in frames if f.is_data]), 4)
        self.assertFalse(any(f.is_equal_split for f in frames))
        self.assertEqual(mo.decode([f.to_bytes() for f in frames]), data)
        # Drop the short last data frame: the old derivation
        # (max_payload from a non-last frame) must rebuild it.
        blobs = [
            f.to_bytes()
            for f in frames
            if not (f.is_data and f.frame_index == 3)
        ]
        self.assertEqual(mo.decode(blobs), data)

    def test_big_frame_grid_roundtrip(self):
        # A 5 MB frame builds and parses through the raised 131072
        # grid cap. (The equal-split scale: a 20 MB file splits into
        # ~10.5 MB frames, a 1 GB file into ~77 MB frames.) Timed — the
        # build time is reported, not asserted, so a slow machine fails
        # loudly by timeout instead of silently passing on a small grid.
        import time

        raw = os.urandom(5 * 1024 * 1024)
        t0 = time.time()
        grid = mo.build_grid(raw)
        build_s = time.time() - t0
        w, h = len(grid[0]), len(grid)
        self.assertLessEqual(h, mo.GRID_MAX_HEIGHT)
        print(f"\n5 MB frame grid {w}x{h}, build {build_s:.1f}s")
        t0 = time.time()
        self.assertEqual(mo.parse_grid(grid), raw)
        print(f"5 MB frame grid parse {time.time() - t0:.1f}s")


class CoverQrTests(unittest.TestCase):
    def test_cover_qr_const_finders(self):
        # The const unpacks to a 29x29 module matrix with the three
        # 7x7 finder patterns (outer ring black, middle ring white,
        # 3x3 core black) in the right corners.
        grid = mo.cover_qr_grid()
        self.assertEqual(len(grid), mo.COVER_QR_SIZE)
        self.assertTrue(all(len(row) == mo.COVER_QR_SIZE for row in grid))
        self.assertEqual(len(mo.COVER_QR_MODULES), 106)
        for r0, c0 in ((0, 0), (0, 22), (22, 0)):
            for dr in range(7):
                for dc in range(7):
                    on_ring = dr in (0, 6) or dc in (0, 6)
                    in_core = 2 <= dr <= 4 and 2 <= dc <= 4
                    self.assertEqual(
                        grid[r0 + dr][c0 + dc],
                        1 if (on_ring or in_core) else 0,
                        f"finder cell {(dr, dc)} at {(r0, c0)}",
                    )

    def test_cover_qr_quiet_zone(self):
        # The drawn QR carries a >= 4-module white quiet zone on every
        # side (37x37 at the default 4) — a QR without one fails to
        # scan.
        grid = mo.cover_qr_grid_with_quiet()
        n = mo.COVER_QR_SIZE + 2 * mo.COVER_QR_QUIET_MODULES
        self.assertEqual((len(grid[0]), len(grid)), (n, n))
        q = mo.COVER_QR_QUIET_MODULES
        for r in range(n):
            for c in range(n):
                if r < q or r >= n - q or c < q or c >= n - q:
                    self.assertEqual(grid[r][c], 0, f"quiet-zone cell {(r, c)}")

    def test_cover_qr_decodes_to_app_url(self):
        # The const is a REAL ISO QR code for the app site, verified
        # with cv2's QRCodeDetector when it is installed.
        try:
            import cv2
            import numpy as np
        except ImportError:
            self.skipTest("cv2 not installed")
        grid = mo.cover_qr_grid_with_quiet()
        # Render at 8 px/module so the detector has real pixels.
        scale = 8
        n = len(grid) * scale
        img = np.full((n, n), 255, dtype=np.uint8)
        for r, row in enumerate(grid):
            for c, v in enumerate(row):
                if v:
                    img[r * scale : (r + 1) * scale, c * scale : (c + 1) * scale] = 0
        data, _points, _straight = cv2.QRCodeDetector().detectAndDecode(img)
        self.assertEqual(data, mo.COVER_QR_URL)


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


def _full_frame_bytes() -> bytes:
    """Serialise one frame with a full 64 KiB payload, built directly
    (encode() equal-splits now, so it no longer yields a 64 KiB frame
    from a 64 KiB input). Header fields are arbitrary — only the
    65,640-byte wire length matters for the grid-size pins."""
    frame = mo.Frame(
        frame_index=0,
        kind=mo.KIND_DATA,
        group_index=0,
        slot=0,
        flags=mo.FLAG_EQUAL_SPLIT,
        total_groups=1,
        total_data_frames=1,
        original_size=65536,
        compressed_size=65536,
        original_sha256=bytes(32),
        salt=bytes(16),
        nonce=bytes(12),
        payload=os.urandom(65536),
    )
    return frame.to_bytes()


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
        # A full 64 KiB frame, built directly: encode() no longer
        # produces 64 KiB frames for a 64 KiB input (equal-split
        # halves it), but the pinned 1776x314 bar-grid size must stay.
        raw = _full_frame_bytes()
        self.assertEqual(len(raw), 65640)  # a full 64 KiB frame
        grid = mo.build_barcode_grid(raw)
        self.assertEqual((len(grid[0]), len(grid)), (1776, 314))
        self.assertEqual(mo.parse_grid(grid), raw)

    def test_grid_full_frame_roundtrip(self):
        raw = _full_frame_bytes()
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
        raw = _full_frame_bytes()
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
            self.assertEqual(stats.frames, 2)  # 1 DATA + P1 (no P2)
            with open(pdf_path, "rb") as fh:
                pdf_bytes = fh.read()
            # Structural check: the PDF really has 3 pages.
            pages = len(re.findall(rb"/Type\s*/Page[^s]", pdf_bytes))
            self.assertEqual(pages, 3)
            # Full loop: PDF -> images -> frames -> original bytes.
            self.assertEqual(mo.decode_pdf(pdf_path, "pdf-passphrase"), data)

    def test_pdf_barcode_mode(self):
        data = _sample_text(10)
        result = mo.encode(data, barcode=True)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out-bc.pdf")
            stats = mo.build_pdf(result, "demo.txt", pdf_path)
            self.assertEqual(stats.pages, 3)  # 1 cover + 2 frames
            self.assertEqual(mo.decode_pdf(pdf_path), data)

    def test_pdf_full_bleed_structure(self):
        # ALL pages are landscape now — the cover is a branded
        # landscape page too. Code pages carry the image over the
        # whole rect; every page carries the RGB logo.
        data = _sample_text(10)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            with open(pdf_path, "rb") as fh:
                pdf_bytes = fh.read()
        mediaboxes = re.findall(rb"/MediaBox \[[^\]]*\]", pdf_bytes)
        self.assertEqual(len(mediaboxes), 3)
        for box in mediaboxes:
            self.assertEqual(box, b"/MediaBox [0 0 841.89 595.28]")
        # The code image is drawn over the entire 841.89 x 595.28 rect.
        operators = b"\n".join(_pdf_content_streams(pdf_bytes))
        self.assertEqual(operators.count(b"841.89 0 0 595.28 0 0 cm /Im0 Do"), 2)
        # No caption text on code pages: the only text operators are
        # the cover's (wordmark + 5 detail lines = 6).
        self.assertEqual(operators.count(b" Tj ET"), 6)
        # One 1-bit code image per frame page + the cover QR (37x37
        # with its quiet zone) + ONE shared 64x64 RGB logo.
        self.assertEqual(pdf_bytes.count(b"/BitsPerComponent 1 /ColorSpace /DeviceGray"), 3)
        self.assertEqual(
            pdf_bytes.count(b"/Width 37 /Height 37 /BitsPerComponent 1"),
            1,
        )
        self.assertEqual(
            pdf_bytes.count(b"/Width 64 /Height 64 /BitsPerComponent 8 /ColorSpace /DeviceRGB"),
            1,
        )
        # The logo is drawn once per page (cover + frames), inside a
        # rounded-rect clip.
        self.assertEqual(operators.count(b"/Im1 Do"), 3)
        self.assertEqual(operators.count(b"h W n"), 3)
        # The QR is drawn once, on the cover.
        self.assertEqual(operators.count(b"/ImQR Do"), 1)

    def test_pdf_cover_has_details_only(self):
        # The cover carries branding + simple details and NOTHING else:
        # no SHA-256, no encoded payload size, no ratio, no frame or
        # group counts, no decode instructions, no manifest grid.
        data = _sample_text(10)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            pdf_bytes = open(pdf_path, "rb").read()
        operators = b"\n".join(_pdf_content_streams(pdf_bytes))
        for wanted in (
            b"(MIDDLE OUT)",
            b"(File: demo.txt)",
            b"(Original size: 960 bytes)",
            b"(Format: QR-style grid)",
            b"(Theme: Light)",
            b"(Pages: 3)",
        ):
            self.assertIn(wanted, operators)
        for banned in (
            b"SHA-256",
            result.stats.sha256_hex.encode("ascii"),
            b"Encoded payload",
            b"Ratio",
            b"Frames:",
            b"group(s)",
            b"Decode with",
            b"scan the frames",
        ):
            self.assertNotIn(banned, operators)
            self.assertNotIn(banned, pdf_bytes)

    def test_pdf_dark_pages_have_black_background(self):
        data = _sample_text(5)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            light = os.path.join(tmp, "light.pdf")
            dark = os.path.join(tmp, "dark.pdf")
            mo.build_pdf(result, "demo.txt", light, dark=False)
            mo.build_pdf(result, "demo.txt", dark, dark=True)
            light_bytes = open(light, "rb").read()
            dark_bytes = open(dark, "rb").read()
            light_ops = b"\n".join(_pdf_content_streams(light_bytes))
            dark_ops = b"\n".join(_pdf_content_streams(dark_bytes))
            self.assertNotIn(b"0 g 0 0 841.89 595.28 re f", light_ops)
            # 2 frame pages painted black; the cover stays light (3
            # pages total, only 2 background rects).
            self.assertEqual(dark_ops.count(b"0 g 0 0 841.89 595.28 re f"), 2)
            self.assertIn(b"(Theme: Dark)", dark_ops)
            # The cover QR is identical in both variants (never inverted).
            qr_re = re.compile(
                rb"/Width 37 /Height 37 /BitsPerComponent 1 /ColorSpace "
                rb"/DeviceGray /Filter /FlateDecode /Length (\d+) >>\nstream\n"
            )

            def qr_stream(pdf):
                m = qr_re.search(pdf)
                self.assertIsNotNone(m, "cover QR image not found")
                length = int(m.group(1))
                return pdf[m.end() : m.end() + length]

            self.assertEqual(qr_stream(light_bytes), qr_stream(dark_bytes))
            self.assertEqual(mo.decode_pdf(dark), data)

    def test_pdf_logo_tile_is_skipped_by_extractor(self):
        data = _sample_text(5)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            pdf_bytes = open(pdf_path, "rb").read()
        extraction = mo.extract_pdf_frames(pdf_bytes)
        # One code image per frame page + one shared RGB logo + the
        # cover QR; the 1-bit images (code + QR) are attempted, the
        # logo is never parsed, and the QR fails the _is_frame check.
        self.assertEqual(extraction.images_found, len(result.frames) + 2)
        self.assertEqual(extraction.images_parsed, len(result.frames) + 1)
        self.assertEqual(len(extraction.frames), len(result.frames))

    def test_pdf_cover_stripped_still_decodes(self):
        # Blank the cover QR image in place (zero its Flate stream, same
        # length — no xref changes) and the frames still decode: the
        # decoder has NO dependency on the cover.
        data = _sample_text(10)
        result = mo.encode(data)
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "out.pdf")
            mo.build_pdf(result, "demo.txt", pdf_path)
            pdf_bytes = bytearray(open(pdf_path, "rb").read())
        qr_re = re.compile(
            rb"/Width 37 /Height 37 /BitsPerComponent 1 /ColorSpace "
            rb"/DeviceGray /Filter /FlateDecode /Length (\d+) >>\nstream\n"
        )
        m = qr_re.search(bytes(pdf_bytes))
        self.assertIsNotNone(m, "cover QR image not found")
        length = int(m.group(1))
        pdf_bytes[m.end() : m.end() + length] = bytes(length)
        with tempfile.TemporaryDirectory() as tmp:
            stripped = os.path.join(tmp, "stripped.pdf")
            with open(stripped, "wb") as fh:
                fh.write(bytes(pdf_bytes))
            self.assertEqual(mo.decode_pdf(stripped), data)

    def test_pdf_no_cover_still_decodes(self):
        # A PDF built with NO cover page at all still decodes — the
        # cover is branding, not data.
        data = _sample_text(10)
        result = mo.encode(data)
        writer = mo.RawPdfWriter()
        for frame in result.frames:
            raw = frame.to_bytes()
            grid = mo.build_grid(raw)
            writer.add_frame_page(
                image_width=len(grid[0]),
                image_height=len(grid),
                image_deflate=mo.deflate_1bit(grid),
                logo_rect=mo.logo_rect_for_grid(len(grid[0]), len(grid)),
            )
        with tempfile.TemporaryDirectory() as tmp:
            pdf_path = os.path.join(tmp, "nocover.pdf")
            with open(pdf_path, "wb") as fh:
                fh.write(writer.build())
            self.assertEqual(mo.decode_pdf(pdf_path), data)

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

    def test_pdf_equal_split_roundtrips_light_dark_qr_barcode(self):
        # All 4 combinations, with equal-split frames: 64 KiB of random
        # data compresses to ~64 KiB, which splits (explicit 64 KiB
        # unit — the default adaptive rule gives 1 page for 64 KiB)
        # into 2 equal ~32 KiB data frames + P1 (trio B empty, no P2)
        # = 3 frames.
        data = os.urandom(64 * 1024)
        for barcode in (False, True):
            for dark in (False, True):
                with self.subTest(barcode=barcode, dark=dark):
                    result = mo.encode(data, max_payload=65536, barcode=barcode)
                    self.assertEqual(len(result.frames), 3)
                    data_frames = [f for f in result.frames if f.is_data]
                    self.assertEqual(len(data_frames), 2)
                    self.assertEqual(len(data_frames[0].payload),
                                     len(data_frames[1].payload))
                    with tempfile.TemporaryDirectory() as tmp:
                        pdf_path = os.path.join(tmp, "out.pdf")
                        stats = mo.build_pdf(result, "full.bin", pdf_path, dark=dark)
                        self.assertEqual(stats.pages, 4)
                        self.assertEqual(mo.decode_pdf(pdf_path), data)

    def test_pdf_dart_samples_decode(self):
        # Cross-check: the Dart-built samples in docs/samples/ decode
        # through the Python extractor + decoder to the demo file
        # documented in docs/samples/README.md (1,023,420 bytes,
        # SHA-256 158094c2... — the repo README as it was when the
        # samples were built, repeated 461 times; passphrase published
        # there on purpose). The expected size + SHA are read from
        # that README, NOT recomputed from the live repo README:
        # README edits must not break this test (a 2026-11-25 README
        # rewrite grew it 2,220 -> 3,030 bytes and broke the old
        # compute-from-README version). When the samples are rebuilt,
        # docs/samples/README.md is updated with them and this test
        # tracks it.
        samples_readme = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "..", "docs", "samples", "README.md",
        )
        with open(samples_readme, "r", encoding="utf-8") as fh:
            doc = fh.read()
        size_match = re.search(r"exactly ([\d,]+) bytes", doc)
        sha_match = re.search(r"SHA-256 `([0-9a-f]{64})`", doc)
        self.assertIsNotNone(size_match, "samples README states demo size")
        self.assertIsNotNone(sha_match, "samples README states demo SHA")
        demo_size = int(size_match.group(1).replace(",", ""))
        demo_sha = sha_match.group(1)
        for name in ("middle-out-sample-light.pdf", "middle-out-sample-dark.pdf"):
            fixture = os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                "..", "docs", "samples", name,
            )
            with self.subTest(sample=name):
                if not os.path.exists(fixture):
                    self.skipTest("Dart sample not present")
                data = mo.decode_pdf(fixture, "middle-out-sample-2026")
                self.assertEqual(len(data), demo_size)
                self.assertEqual(hashlib.sha256(data).hexdigest(), demo_sha)

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
