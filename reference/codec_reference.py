#!/usr/bin/env python3
"""Middle Out codec — Python reference implementation (stdlib + PIL/reportlab).

This is a byte-for-byte mirror of the Dart codec in lib/codec/. It exists so
the wire format, erasure coding, encryption and PDF assembly can be validated
without a Flutter toolchain. The Dart side and this file MUST agree on:

  * the 97-byte frame header layout (see HEADER below),
  * zlib level-9 compression of the whole file before chunking,
  * ChaCha20 (RFC 8439) with a PBKDF2-HMAC-SHA256 derived key,
  * XOR parity: 6 DATA + 2 PARITY per group, trios (0,1,2) and (3,4,5),
  * the Middle Out Code grid geometry and the stacked-row barcode format.

Run the test suite:  python3 test_codec_reference.py
CLI:                  python3 codec_reference.py encode in.bin out.pdf
                      python3 codec_reference.py decode-pdf out.pdf in.bin
"""

from __future__ import annotations

import hashlib
import io
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Constants (mirrors lib/core/constants.dart — keep in sync)
# ---------------------------------------------------------------------------

MAGIC = b"MO01"
VERSION = 1
HEADER_SIZE = 97
HEADER_STRUCT = ">4sBBBBBBBH I Q Q 32s 16s 12s I".replace(" ", "")
assert struct.calcsize(HEADER_STRUCT) == HEADER_SIZE

KIND_DATA = 0
KIND_PARITY = 1

FLAG_ENCRYPTED = 0x01
FLAG_LAST_GROUP = 0x02
FLAG_BARCODE = 0x04

GROUP_DATA_FRAMES = 6
GROUP_PARITY_FRAMES = 2
GROUP_SIZE = 8
PARITY_A_TRIO = (0, 1, 2)
PARITY_B_TRIO = (3, 4, 5)
PARITY_A_SLOT = 6
PARITY_B_SLOT = 7

DEFAULT_MAX_PAYLOAD = 65536
MAX_FRAMES = 256

PBKDF2_ITERATIONS = 100_000
SALT_LEN = 16
NONCE_LEN = 12
KEY_LEN = 32


class CodecError(Exception):
    """Base class for all Middle Out codec failures."""


class CorruptFrameError(CodecError):
    """A frame failed its header or payload CRC."""


class UnrecoverableError(CodecError):
    """Too many frames lost in one parity trio to rebuild the file."""


class VerificationError(CodecError):
    """Reassembled bytes failed the SHA-256 / size check (wrong passphrase,
    tampered payload, or a decompression failure)."""


# ---------------------------------------------------------------------------
# ChaCha20 (RFC 8439) — pure Python, validated against the RFC test vector.
# ---------------------------------------------------------------------------

_CHACHA_CONSTANTS = (0x61707865, 0x3320646e, 0x79622D32, 0x6B206574)
_MASK32 = 0xFFFFFFFF


def _rotl32(value: int, bits: int) -> int:
    return ((value << bits) | (value >> (32 - bits))) & _MASK32


def _quarter_round(state: list[int], a: int, b: int, c: int, d: int) -> None:
    state[a] = (state[a] + state[b]) & _MASK32
    state[d] ^= state[a]
    state[d] = _rotl32(state[d], 16)
    state[c] = (state[c] + state[d]) & _MASK32
    state[b] ^= state[c]
    state[b] = _rotl32(state[b], 12)
    state[a] = (state[a] + state[b]) & _MASK32
    state[d] ^= state[a]
    state[d] = _rotl32(state[d], 8)
    state[c] = (state[c] + state[d]) & _MASK32
    state[b] ^= state[c]
    state[b] = _rotl32(state[b], 7)


def chacha20_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    """One 64-byte ChaCha20 keystream block (RFC 8439 section 2.3)."""
    if len(key) != KEY_LEN:
        raise ValueError("ChaCha20 key must be 32 bytes")
    if len(nonce) != NONCE_LEN:
        raise ValueError("ChaCha20 nonce must be 12 bytes")
    state = list(_CHACHA_CONSTANTS)
    state += list(struct.unpack("<8I", key))
    state += [counter & _MASK32]
    state += list(struct.unpack("<3I", nonce))
    working = state[:]
    for _ in range(10):  # 20 rounds = 10 double rounds
        _quarter_round(working, 0, 4, 8, 12)
        _quarter_round(working, 1, 5, 9, 13)
        _quarter_round(working, 2, 6, 10, 14)
        _quarter_round(working, 3, 7, 11, 15)
        _quarter_round(working, 0, 5, 10, 15)
        _quarter_round(working, 1, 6, 11, 12)
        _quarter_round(working, 2, 7, 8, 13)
        _quarter_round(working, 3, 4, 9, 14)
    out = [(working[i] + state[i]) & _MASK32 for i in range(16)]
    return struct.pack("<16I", *out)


def chacha20_xor(key: bytes, nonce: bytes, data: bytes, counter: int = 0) -> bytes:
    """ChaCha20 encrypt/decrypt (identical operation — a stream cipher)."""
    out = bytearray()
    for offset in range(0, len(data), 64):
        block = chacha20_block(key, counter, nonce)
        counter += 1
        chunk = data[offset : offset + 64]
        out += bytes(b ^ k for b, k in zip(chunk, block))
    return bytes(out)


def derive_key(passphrase: str, salt: bytes) -> bytes:
    """PBKDF2-HMAC-SHA256, 100k iterations -> 32-byte ChaCha20 key."""
    return hashlib.pbkdf2_hmac(
        "sha256", passphrase.encode("utf-8"), salt, PBKDF2_ITERATIONS, KEY_LEN
    )


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------


@dataclass
class Frame:
    """One Middle Out frame: a 97-byte header + payload + 4-byte payload CRC."""

    frame_index: int
    kind: int
    group_index: int
    slot: int
    flags: int
    total_groups: int
    total_data_frames: int
    original_size: int
    compressed_size: int
    original_sha256: bytes
    salt: bytes
    nonce: bytes
    payload: bytes
    payload_corrupt: bool = False

    @property
    def is_data(self) -> bool:
        return self.kind == KIND_DATA

    @property
    def is_encrypted(self) -> bool:
        return bool(self.flags & FLAG_ENCRYPTED)

    @property
    def is_barcode(self) -> bool:
        return bool(self.flags & FLAG_BARCODE)

    def to_bytes(self) -> bytes:
        header_wo_crc = struct.pack(
            ">4sBBBBBBBH I Q Q 32s 16s 12s".replace(" ", ""),
            MAGIC,
            VERSION,
            self.frame_index,
            self.kind,
            self.group_index,
            self.slot,
            self.flags,
            self.total_groups,
            self.total_data_frames,
            len(self.payload),
            self.original_size,
            self.compressed_size,
            self.original_sha256,
            self.salt,
            self.nonce,
        )
        header_crc = zlib.crc32(header_wo_crc) & _MASK32
        header = header_wo_crc + struct.pack(">I", header_crc)
        payload_crc = zlib.crc32(self.payload) & _MASK32
        return header + self.payload + struct.pack(">I", payload_crc)

    @classmethod
    def from_bytes(cls, raw: bytes) -> "Frame":
        if len(raw) < HEADER_SIZE + 4:
            raise CorruptFrameError("frame shorter than header + CRC")
        header = raw[:HEADER_SIZE]
        fields = struct.unpack(HEADER_STRUCT, header)
        (
            magic,
            version,
            frame_index,
            kind,
            group_index,
            slot,
            flags,
            total_groups,
            total_data_frames,
            payload_len,
            original_size,
            compressed_size,
            sha256,
            salt,
            nonce,
            header_crc,
        ) = fields
        if magic != MAGIC:
            raise CorruptFrameError("bad magic")
        if version != VERSION:
            raise CorruptFrameError(f"unsupported frame version {version}")
        if zlib.crc32(header[: HEADER_SIZE - 4]) & _MASK32 != header_crc:
            raise CorruptFrameError("header CRC mismatch")
        if len(raw) != HEADER_SIZE + payload_len + 4:
            raise CorruptFrameError(
                f"frame length {len(raw)} != header + {payload_len} + CRC"
            )
        payload = raw[HEADER_SIZE : HEADER_SIZE + payload_len]
        (payload_crc,) = struct.unpack(">I", raw[HEADER_SIZE + payload_len :])
        corrupt = zlib.crc32(payload) & _MASK32 != payload_crc
        return cls(
            frame_index=frame_index,
            kind=kind,
            group_index=group_index,
            slot=slot,
            flags=flags,
            total_groups=total_groups,
            total_data_frames=total_data_frames,
            original_size=original_size,
            compressed_size=compressed_size,
            original_sha256=sha256,
            salt=salt,
            nonce=nonce,
            payload=payload,
            payload_corrupt=corrupt,
        )


def _xor_bytes(a: bytes, b: bytes) -> bytes:
    return bytes(x ^ y for x, y in zip(a, b))


def _pad(data: bytes, length: int) -> bytes:
    return data + bytes(length - len(data))


# ---------------------------------------------------------------------------
# Encode / decode
# ---------------------------------------------------------------------------


@dataclass
class EncodeStats:
    original_size: int
    compressed_size: int
    frame_count: int
    group_count: int
    ratio: float
    sha256_hex: str


@dataclass
class EncodeResult:
    frames: list[Frame]
    stats: EncodeStats
    barcode: bool = False


def encode(
    data: bytes,
    passphrase: str | None = None,
    *,
    max_payload: int = DEFAULT_MAX_PAYLOAD,
    barcode: bool = False,
) -> EncodeResult:
    """Encode [data] into Middle Out frames.

    Pipeline: SHA-256 -> zlib-9 compress -> (optional ChaCha20 encrypt) ->
    split into <= max_payload chunks -> group into 6 DATA + 2 XOR-parity.
    """
    sha = hashlib.sha256(data).digest()
    compressed = zlib.compress(data, 9)
    encrypted = passphrase is not None
    if encrypted:
        salt = os.urandom(SALT_LEN)
        nonce = os.urandom(NONCE_LEN)
        key = derive_key(passphrase, salt)
        stream = chacha20_xor(key, nonce, compressed)
    else:
        salt = bytes(SALT_LEN)
        nonce = bytes(NONCE_LEN)
        stream = compressed

    chunks = [stream[i : i + max_payload] for i in range(0, len(stream), max_payload)]
    if not chunks:
        chunks = [b""]
    total_data = len(chunks)
    total_groups = (total_data + GROUP_DATA_FRAMES - 1) // GROUP_DATA_FRAMES
    total_frames = total_data + total_groups * GROUP_PARITY_FRAMES
    if total_frames > MAX_FRAMES:
        raise CodecError(
            f"encode needs {total_frames} frames, max is {MAX_FRAMES}; "
            "raise max_payload or split the file"
        )

    base_flags = (FLAG_ENCRYPTED if encrypted else 0) | (FLAG_BARCODE if barcode else 0)
    frames: list[Frame] = []
    for group in range(total_groups):
        group_chunks = chunks[group * GROUP_DATA_FRAMES : (group + 1) * GROUP_DATA_FRAMES]
        group_flags = base_flags | (FLAG_LAST_GROUP if group == total_groups - 1 else 0)
        for slot, chunk in enumerate(group_chunks):
            frames.append(
                Frame(
                    frame_index=group * GROUP_DATA_FRAMES + slot,
                    kind=KIND_DATA,
                    group_index=group,
                    slot=slot,
                    flags=group_flags,
                    total_groups=total_groups,
                    total_data_frames=total_data,
                    original_size=len(data),
                    compressed_size=len(stream),
                    original_sha256=sha,
                    salt=salt,
                    nonce=nonce,
                    payload=chunk,
                )
            )
        for trio, parity_slot in (
            (PARITY_A_TRIO, PARITY_A_SLOT),
            (PARITY_B_TRIO, PARITY_B_SLOT),
        ):
            present = [group_chunks[s] for s in trio if s < len(group_chunks)]
            if present:
                width = max(len(c) for c in present)
                parity = bytes(width)
                for chunk in present:
                    parity = _xor_bytes(parity, _pad(chunk, width))
            else:
                parity = b""
            frames.append(
                Frame(
                    frame_index=total_data
                    + group * GROUP_PARITY_FRAMES
                    + (parity_slot - PARITY_A_SLOT),
                    kind=KIND_PARITY,
                    group_index=group,
                    slot=parity_slot,
                    flags=group_flags,
                    total_groups=total_groups,
                    total_data_frames=total_data,
                    original_size=len(data),
                    compressed_size=len(stream),
                    original_sha256=sha,
                    salt=salt,
                    nonce=nonce,
                    payload=parity,
                )
            )

    stats = EncodeStats(
        original_size=len(data),
        compressed_size=len(stream),
        frame_count=len(frames),
        group_count=total_groups,
        ratio=len(data) / max(1, len(stream)),
        sha256_hex=sha.hex(),
    )
    return EncodeResult(frames=frames, stats=stats, barcode=barcode)


def _expected_data_length(
    frame_index: int, total_data_frames: int, compressed_size: int, max_payload: int
) -> int:
    if frame_index < total_data_frames - 1:
        return max_payload
    return compressed_size - max_payload * (total_data_frames - 1)


def decode(frame_blobs: list[bytes], passphrase: str | None = None) -> bytes:
    """Rebuild the original file from raw frame blobs.

    Corrupt (CRC-failing) frames are treated as lost and rebuilt from parity
    where possible. Raises UnrecoverableError when a parity trio lost two or
    more frames, VerificationError when the rebuilt bytes fail SHA-256.
    """
    frames: list[Frame] = []
    for blob in frame_blobs:
        try:
            frames.append(Frame.from_bytes(blob))
        except CorruptFrameError:
            # A frame whose header is unreadable is simply lost.
            continue
    if not frames:
        raise UnrecoverableError("no readable frames")

    meta = frames[0]
    total_data = meta.total_data_frames
    total_groups = meta.total_groups
    compressed_size = meta.compressed_size

    # Derive max_payload from any present non-last data frame.
    max_payload = DEFAULT_MAX_PAYLOAD
    for f in frames:
        if f.is_data and not f.payload_corrupt and f.frame_index < total_data - 1:
            max_payload = len(f.payload)
            break
    else:
        if total_data == 1:
            max_payload = compressed_size

    by_group_slot: dict[tuple[int, int], Frame] = {}
    for f in frames:
        if not f.payload_corrupt:
            by_group_slot[(f.group_index, f.slot)] = f

    recovered: dict[int, bytes] = {}
    for group in range(total_groups):
        group_data_count = min(
            GROUP_DATA_FRAMES, total_data - group * GROUP_DATA_FRAMES
        )
        for trio, parity_slot in (
            (PARITY_A_TRIO, PARITY_A_SLOT),
            (PARITY_B_TRIO, PARITY_B_SLOT),
        ):
            slots = [s for s in trio if s < group_data_count]
            missing = [s for s in slots if (group, s) not in by_group_slot]
            if not missing:
                continue
            if len(missing) > 1:
                raise UnrecoverableError(
                    f"group {group} trio {trio}: {len(missing)} frames lost, "
                    "parity can only rebuild one"
                )
            parity = by_group_slot.get((group, parity_slot))
            if parity is None:
                raise UnrecoverableError(
                    f"group {group} trio {trio}: data slot {missing[0]} lost "
                    "and its parity frame is missing too"
                )
            width = len(parity.payload)
            rebuilt = parity.payload
            for s in slots:
                if s != missing[0]:
                    rebuilt = _xor_bytes(rebuilt, _pad(by_group_slot[(group, s)].payload, width))
            frame_index = group * GROUP_DATA_FRAMES + missing[0]
            want = _expected_data_length(
                frame_index, total_data, compressed_size, max_payload
            )
            recovered[frame_index] = rebuilt[:want]

    stream = bytearray()
    for index in range(total_data):
        if index in recovered:
            stream += recovered[index]
            continue
        group, slot = divmod(index, GROUP_DATA_FRAMES)
        frame = by_group_slot.get((group, slot))
        if frame is None:
            raise UnrecoverableError(f"data frame {index} missing, unrecoverable")
        stream += frame.payload

    if meta.is_encrypted:
        if passphrase is None:
            raise VerificationError("frames are encrypted; a passphrase is required")
        key = derive_key(passphrase, meta.salt)
        try:
            plain = chacha20_xor(key, meta.nonce, bytes(stream))
            data = zlib.decompress(plain)
        except Exception as exc:
            raise VerificationError(
                "decrypt/decompress failed — wrong passphrase or tampered frames"
            ) from exc
    else:
        try:
            data = zlib.decompress(bytes(stream))
        except Exception as exc:
            raise VerificationError("decompress failed — frames are corrupt") from exc

    if len(data) != meta.original_size:
        raise VerificationError(
            f"size mismatch: got {len(data)}, expected {meta.original_size}"
        )
    if hashlib.sha256(data).digest() != meta.original_sha256:
        raise VerificationError("SHA-256 mismatch — rebuilt bytes are not the original")
    return data


# ---------------------------------------------------------------------------
# Visual codes: Middle Out Code grid + stacked-row barcode
#
# The frames are rendered as full-page codes. A real ISO QR code holds ~3 KB;
# a Middle Out frame holds up to 64 KiB, so the 2D mode is a custom grid
# (QR-style finders, timing patterns, centre tile reserved for the logo)
# rather than an ISO QR code. Barcode mode stacks the payload as rows of
# bars, PDF417-style. Both carry a 4-byte big-endian length prefix so the
# parser knows where the payload ends and the padding begins.
# ---------------------------------------------------------------------------

GRID_MIN_SIZE = 32
GRID_STEP = 4
GRID_QUIET_MODULES = 4
BARCODE_ROW_BYTES = 64
BARCODE_BAR_PX = 2
BARCODE_ROW_PX = 24
BARCODE_GAP_PX = 4


def _finder_cells(n: int) -> set[tuple[int, int]]:
    """All cells reserved by the three 8x8 finder zones (7x7 + separator)."""
    cells: set[tuple[int, int]] = set()
    for r0, c0 in ((0, 0), (0, n - 8), (n - 8, 0)):
        for r in range(r0, r0 + 8):
            for c in range(c0, c0 + 8):
                cells.add((r, c))
    return cells


def _timing_cells(n: int) -> set[tuple[int, int]]:
    cells: set[tuple[int, int]] = set()
    for i in range(8, n - 8):
        cells.add((6, i))
        cells.add((i, 6))
    return cells


def _centre_tile(n: int) -> tuple[int, int, int]:
    """(start_row, start_col, side) of the logo tile, centred, side = n//4."""
    side = max(8, n // 4)
    start = (n - side) // 2
    return start, start, side


def _centre_cells(n: int) -> set[tuple[int, int]]:
    r0, c0, side = _centre_tile(n)
    return {(r, c) for r in range(r0, r0 + side) for c in range(c0, c0 + side)}


def _reserved_cells(n: int) -> set[tuple[int, int]]:
    return _finder_cells(n) | _timing_cells(n) | _centre_cells(n)


def grid_capacity_bits(n: int) -> int:
    return n * n - len(_reserved_cells(n))


def choose_grid_size(payload_len: int) -> int:
    """Smallest grid (multiple of 4, >= 32) whose data cells fit the payload
    plus its 4-byte length prefix."""
    need_bits = (payload_len + 4) * 8
    n = GRID_MIN_SIZE
    while grid_capacity_bits(n) < need_bits:
        n += GRID_STEP
        if n > 4096:
            raise CodecError("payload too large for a single code grid")
    return n


def build_grid(payload: bytes) -> list[bytearray]:
    """Render [payload] into an n x n module matrix (1 = black, 0 = white)."""
    blob = struct.pack(">I", len(payload)) + payload
    n = choose_grid_size(len(payload))
    grid: list[bytearray] = [bytearray(n) for _ in range(n)]
    reserved = _reserved_cells(n)

    # Finder patterns: 7x7, outer ring black, middle ring white, core 3x3 black.
    for r0, c0 in ((0, 0), (0, n - 7), (n - 7, 0)):
        for dr in range(7):
            for dc in range(7):
                on_ring = dr in (0, 6) or dc in (0, 6)
                in_core = 2 <= dr <= 4 and 2 <= dc <= 4
                grid[r0 + dr][c0 + dc] = 1 if (on_ring or in_core) else 0
    # Timing row/column 6, alternating black/white starting black.
    for i in range(8, n - 8):
        grid[6][i] = 1 if i % 2 == 0 else 0
        grid[i][6] = 1 if i % 2 == 0 else 0

    # Data bits, row-major over the placeable cells, MSB first.
    bit_iter = (bit for byte in blob for bit in [(byte >> k) & 1 for k in range(7, -1, -1)])
    for r in range(n):
        for c in range(n):
            if (r, c) in reserved:
                continue
            try:
                grid[r][c] = next(bit_iter)
            except StopIteration:
                return grid
    return grid


def parse_grid(grid: list[bytearray]) -> bytes:
    """Inverse of build_grid: read the length prefix, then the payload."""
    n = len(grid)
    reserved = _reserved_cells(n)
    bits = [grid[r][c] for r in range(n) for c in range(n) if (r, c) not in reserved]
    if len(bits) < 32:
        raise CodecError("grid too small to hold a length prefix")
    length = 0
    for bit in bits[:32]:
        length = (length << 1) | bit
    if length * 8 + 32 > len(bits):
        raise CodecError("grid length prefix exceeds grid capacity")
    out = bytearray()
    for i in range(length):
        byte = 0
        for bit in bits[32 + i * 8 : 40 + i * 8]:
            byte = (byte << 1) | bit
        out.append(byte)
    return bytes(out)


def build_barcode_rows(payload: bytes) -> list[bytearray]:
    """Stacked-row barcode: each row is a bar strip carrying 64 payload bytes
    plus a 1-byte row index. Row layout (bars, 1 = black):
    [4 start guard][8 row index][512 data][4 stop guard] = 528 bars."""
    blob = struct.pack(">I", len(payload)) + payload
    rows: list[bytearray] = []
    for row_index in range(0, (len(blob) + BARCODE_ROW_BYTES - 1) // BARCODE_ROW_BYTES):
        chunk = blob[row_index * BARCODE_ROW_BYTES : (row_index + 1) * BARCODE_ROW_BYTES]
        chunk = chunk + bytes(BARCODE_ROW_BYTES - len(chunk))
        bars = bytearray([1, 1, 1, 1])
        bars += bytearray((row_index >> k) & 1 for k in range(7, -1, -1))
        for byte in chunk:
            bars += bytearray((byte >> k) & 1 for k in range(7, -1, -1))
        bars += bytearray([1, 1, 1, 1])
        rows.append(bars)
    return rows


def parse_barcode_rows(rows: list[bytearray]) -> bytes:
    """Inverse of build_barcode_rows. Rows are reassembled by their index."""
    if not rows:
        raise CodecError("no barcode rows")
    width = len(rows[0])
    if width != 4 + 8 + BARCODE_ROW_BYTES * 8 + 4:
        raise CodecError(f"unexpected barcode row width {width}")
    chunks: dict[int, bytes] = {}
    for bars in rows:
        if list(bars[:4]) != [1, 1, 1, 1] or list(bars[-4:]) != [1, 1, 1, 1]:
            raise CodecError("barcode row guard pattern missing")
        index = 0
        for bit in bars[4:12]:
            index = (index << 1) | bit
        data = bytearray()
        for i in range(BARCODE_ROW_BYTES):
            byte = 0
            for bit in bars[12 + i * 8 : 20 + i * 8]:
                byte = (byte << 1) | bit
            data.append(byte)
        chunks[index] = bytes(data)
    blob = b"".join(chunks[i] for i in sorted(chunks))
    (length,) = struct.unpack(">I", blob[:4])
    if length + 4 > len(blob):
        raise CodecError("barcode length prefix exceeds payload")
    return blob[4 : 4 + length]


# ---------------------------------------------------------------------------
# Image rendering / sampling (PIL) + PDF assembly (reportlab)
# ---------------------------------------------------------------------------


def render_grid_image(grid: list[bytearray], module_px: int = 4):
    """Render a module matrix to a 1-bit PIL image with a quiet zone."""
    from PIL import Image

    n = len(grid)
    quiet = GRID_QUIET_MODULES
    size = (n + 2 * quiet) * module_px
    img = Image.new("1", (size, size), 1)
    px = img.load()
    for r in range(n):
        for c in range(n):
            if grid[r][c]:
                x0 = (c + quiet) * module_px
                y0 = (r + quiet) * module_px
                for y in range(y0, y0 + module_px):
                    for x in range(x0, x0 + module_px):
                        px[x, y] = 0
    return img


def sample_grid_image(img, module_px: int = 4) -> list[bytearray]:
    """Sample a rendered grid image back to a module matrix (module centres)."""
    quiet = GRID_QUIET_MODULES
    n = img.width // module_px - 2 * quiet
    if n <= 0 or img.width != img.height:
        raise CodecError("not a square grid image")
    grey = img.convert("L")
    px = grey.load()
    grid: list[bytearray] = []
    for r in range(n):
        row = bytearray(n)
        for c in range(n):
            x = (c + quiet) * module_px + module_px // 2
            y = (r + quiet) * module_px + module_px // 2
            row[c] = 1 if px[x, y] < 128 else 0
        grid.append(row)
    return grid


def render_barcode_image(rows: list[bytearray]):
    """Render barcode rows to a 1-bit PIL image."""
    from PIL import Image

    width = len(rows[0]) * BARCODE_BAR_PX
    height = len(rows) * (BARCODE_ROW_PX + BARCODE_GAP_PX)
    img = Image.new("1", (width, height), 1)
    px = img.load()
    for ri, bars in enumerate(rows):
        y0 = ri * (BARCODE_ROW_PX + BARCODE_GAP_PX)
        for bi, bit in enumerate(bars):
            if bit:
                x0 = bi * BARCODE_BAR_PX
                for y in range(y0, y0 + BARCODE_ROW_PX):
                    for x in range(x0, x0 + BARCODE_BAR_PX):
                        px[x, y] = 0
    return img


def sample_barcode_image(img) -> list[bytearray]:
    """Sample a rendered barcode image back to bar rows."""
    n_rows = round(img.height / (BARCODE_ROW_PX + BARCODE_GAP_PX))
    n_bars = img.width // BARCODE_BAR_PX
    grey = img.convert("L")
    px = grey.load()
    rows: list[bytearray] = []
    for ri in range(n_rows):
        y = ri * (BARCODE_ROW_PX + BARCODE_GAP_PX) + BARCODE_ROW_PX // 2
        row = bytearray(n_bars)
        for bi in range(n_bars):
            x = bi * BARCODE_BAR_PX + BARCODE_BAR_PX // 2
            row[bi] = 1 if px[x, y] < 128 else 0
        rows.append(row)
    return rows


def detect_code_kind(img) -> str:
    """'grid' for a square code image, 'barcode' for a wide strip."""
    return "grid" if abs(img.width - img.height) <= max(img.width, img.height) // 10 else "barcode"


@dataclass
class PdfStats:
    pages: int
    size_bytes: int
    frames: int


def build_pdf(
    result: EncodeResult,
    file_name: str,
    out_path: str,
    module_px: int = 3,
) -> PdfStats:
    """Assemble the encoded PDF: 1 cover page + 1 full-page code page per
    frame. Returns page count and file size (the 5-20 MB-per-GB band is
    checked by the caller against the original size)."""
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    width, height = A4
    stats = result.stats
    pdf = canvas.Canvas(out_path, pagesize=A4)

    # --- Cover page ---
    pdf.setFont("Helvetica-Bold", 34)
    pdf.drawString(20 * mm, height - 30 * mm, "MIDDLE OUT")
    pdf.setFont("Helvetica", 12)
    pdf.drawString(20 * mm, height - 42 * mm, "Lossless file, printed as code.")
    pdf.setFont("Helvetica", 11)
    lines = [
        f"File: {file_name}",
        f"Original size: {stats.original_size:,} bytes",
        f"Encoded payload: {stats.compressed_size:,} bytes",
        f"Ratio: {stats.ratio:.1f}x",
        f"SHA-256: {stats.sha256_hex}",
        f"Frames: {stats.frame_count} "
        f"({stats.group_count} group(s) of 6 DATA + 2 PARITY)",
        f"Format: {'Barcode' if result.barcode else 'QR-style grid'}",
        "Decode with the Middle Out app — scan the frames in order.",
    ]
    y = height - 60 * mm
    for line in lines:
        pdf.drawString(20 * mm, y, line)
        y -= 7 * mm
    pdf.showPage()

    # --- One full-page code page per frame ---
    for frame in result.frames:
        raw = frame.to_bytes()
        if result.barcode:
            img = render_barcode_image(build_barcode_rows(raw))
        else:
            img = render_grid_image(build_grid(raw), module_px=module_px)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        max_w, max_h = width - 20 * mm, height - 30 * mm
        scale = min(max_w / img.width, max_h / img.height)
        iw, ih = img.width * scale, img.height * scale
        from reportlab.lib.utils import ImageReader

        pdf.drawImage(
            ImageReader(buf), (width - iw) / 2, (height - ih) / 2 + 5 * mm,
            width=iw, height=ih, preserveAspectRatio=True,
        )
        kind = "DATA" if frame.is_data else "PARITY"
        pdf.setFont("Helvetica", 10)
        pdf.drawCentredString(
            width / 2, 12 * mm,
            f"Frame {frame.frame_index + 1} of {stats.frame_count}  ·  "
            f"{kind}  ·  Group {frame.group_index + 1}  ·  "
            f"{len(frame.payload):,} bytes",
        )
        pdf.showPage()
    pdf.save()

    return PdfStats(
        pages=1 + len(result.frames),
        size_bytes=os.path.getsize(out_path),
        frames=len(result.frames),
    )


def extract_pdf_images(pdf_path: str, out_dir: str) -> list[str]:
    """Extract embedded images from a PDF with poppler's pdfimages.
    Returns paths in page order. (Used by the CLI decode path and tests.)"""
    prefix = os.path.join(out_dir, "frame")
    proc = subprocess.run(
        ["pdfimages", "-png", pdf_path, prefix],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        raise CodecError(f"pdfimages failed: {proc.stderr.strip()}")
    return sorted(
        os.path.join(out_dir, f)
        for f in os.listdir(out_dir)
        if f.startswith("frame-") and f.endswith(".png")
    )


def decode_pdf(pdf_path: str, passphrase: str | None = None, module_px: int = 3) -> bytes:
    """Full loop: PDF -> frame images -> frames -> original bytes."""
    from PIL import Image

    with tempfile.TemporaryDirectory() as tmp:
        images = extract_pdf_images(pdf_path, tmp)
        if not images:
            raise CodecError("no code images found in PDF")
        blobs: list[bytes] = []
        for path in images:
            img = Image.open(path)
            if detect_code_kind(img) == "grid":
                blobs.append(parse_grid(sample_grid_image(img, module_px)))
            else:
                blobs.append(parse_barcode_rows(sample_barcode_image(img)))
    return decode(blobs, passphrase)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "encode" and len(argv) >= 4:
        src, pdf_path = argv[2], argv[3]
        passphrase = None
        barcode = False
        frames_dir = None
        i = 4
        while i < len(argv):
            if argv[i] == "--passphrase":
                passphrase = argv[i + 1]
                i += 2
            elif argv[i] == "--barcode":
                barcode = True
                i += 1
            elif argv[i] == "--frames-dir":
                frames_dir = argv[i + 1]
                i += 2
            else:
                print(f"unknown option {argv[i]}")
                return 2
        with open(src, "rb") as fh:
            data = fh.read()
        result = encode(data, passphrase, barcode=barcode)
        pdf_stats = build_pdf(result, os.path.basename(src), pdf_path)
        print(f"encoded {len(data):,} bytes -> {result.stats.frame_count} frames "
              f"({result.stats.ratio:.1f}x) -> {pdf_path} "
              f"({pdf_stats.pages} pages, {pdf_stats.size_bytes:,} bytes)")
        if frames_dir:
            os.makedirs(frames_dir, exist_ok=True)
            for frame in result.frames:
                kind = "data" if frame.is_data else "parity"
                with open(
                    os.path.join(frames_dir, f"frame-{frame.frame_index:02d}-{kind}.bin"),
                    "wb",
                ) as fh:
                    fh.write(frame.to_bytes())
            print(f"frames written to {frames_dir}")
        return 0
    if cmd == "decode-pdf" and len(argv) >= 4:
        pdf_path, dst = argv[2], argv[3]
        passphrase = None
        if len(argv) >= 6 and argv[4] == "--passphrase":
            passphrase = argv[5]
        data = decode_pdf(pdf_path, passphrase)
        with open(dst, "wb") as fh:
            fh.write(data)
        print(f"decoded {len(data):,} bytes -> {dst} (SHA-256 verified)")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
