#!/usr/bin/env python3
"""Middle Out codec — Python reference implementation (stdlib-only, + PIL
for the image round-trip tests only).

This is a byte-for-byte mirror of the Dart codec in lib/codec/. It exists so
the wire format, erasure coding, encryption and PDF assembly can be validated
without a Flutter toolchain. The Dart side and this file MUST agree on:

  * the 100-byte v2 frame header layout (v1's 97-byte header still parses),
  * zlib level-9 compression of the whole file before chunking,
  * ChaCha20 (RFC 8439) with a PBKDF2-HMAC-SHA256 derived key,
  * XOR parity: 6 DATA + 2 PARITY per group, trios (0,1,2) and (3,4,5),
  * the rectangular Middle Out Code grid geometry (QR aspect ~1.41421,
    bar-grid aspect ~5.65685) and the legacy stacked-row barcode format,
  * the full-bleed PDF: landscape code pages, light/dark variants, and
    the centre logo-tile overlay.

Run the test suite:  python3 test_codec_reference.py
CLI:                  python3 codec_reference.py encode in.bin out.pdf
                      python3 codec_reference.py decode-pdf out.pdf in.bin
"""

from __future__ import annotations

import base64
import hashlib
import math
import os
import re
import struct
import sys
import zlib
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Constants (mirrors lib/core/constants.dart — keep in sync)
# ---------------------------------------------------------------------------

MAGIC = b"MO01"
VERSION = 2
HEADER_SIZE = 100
# v2 layout: magic 4s, version B, frame_index H, kind B, group_index H,
# slot B, flags B, total_groups H, total_data_frames H, payload_len I,
# original_size Q, compressed_size Q, sha256 32s, salt 16s, nonce 12s,
# header_crc I. v2 widened the three indices from uint8 to uint16: v1
# could only address 256 frames, and a real 67 MB mp4 needs 1,125.
HEADER_STRUCT = ">4sBHBHBBHHIQQ32s16s12sI"
assert struct.calcsize(HEADER_STRUCT) == HEADER_SIZE
# v1 layout (still parsed, never written): frame_index/group_index/
# total_groups are uint8, everything after them sits 3 bytes earlier.
HEADER_SIZE_V1 = 97
HEADER_STRUCT_V1 = ">4sBBBBBBBHIQQ32s16s12sI"
assert struct.calcsize(HEADER_STRUCT_V1) == HEADER_SIZE_V1

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
# Policy guardrail, not a format limit: v2 frame_index is uint16, so the
# format can address 65,535 frames. 4096 covers the 1 GB hero case
# (~300 frames) 13x over and the largest real-world report so far (a
# 67 MB mp4 needing 1,125 frames) 3.6x over, while bounding the PDF at
# ~250 MB and in-memory frame payloads at ~256 MB.
MAX_FRAMES = 4096

PBKDF2_ITERATIONS = 100_000
SALT_LEN = 16
NONCE_LEN = 12
KEY_LEN = 32

# --- Full-bleed code-page geometry (mirrors lib/codec/code_grid.dart) ---
# Code pages are A4 LANDSCAPE and the code image spans the ENTIRE page
# rect — no margins, no caption, no quiet zone. The cover stays portrait.
CODE_PAGE_WIDTH = 841.89
CODE_PAGE_HEIGHT = 595.28
COVER_PAGE_WIDTH = 595.28
COVER_PAGE_HEIGHT = 841.89
# QR grids match the page aspect; the bar-grid stretches it 4x, so each
# module draws as a tall thin rectangle and adjacent black modules merge
# into vertical bars.
QR_ASPECT = CODE_PAGE_WIDTH / CODE_PAGE_HEIGHT  # ~1.41421
BARCODE_STRETCH = 4
BARCODE_ASPECT = BARCODE_STRETCH * QR_ASPECT  # ~5.65685
GRID_MIN_HEIGHT = 32
GRID_HEIGHT_STEP = 2
GRID_MAX_HEIGHT = 4096

# --- Centre logo tile (docs/screenshots/app-icon.png, verified by eye:
# black rounded-square tile, white pixel-M, green dot) ---
# The reference is stdlib-only, so the 64x64 RGB pixels are embedded as a
# base64 constant (decoded once from the PNG at development time with PIL,
# composited on black, BOX-resampled 256 -> 64) instead of being read from
# the PNG at runtime. The logo is a decorative overlay — never decoded —
# so a pixel-exact match with the Dart side is not required.
LOGO_SIZE = 64
LOGO_RGB_PIXELS_B64 = (
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAUECg0LDxMQEhgUExoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "ExoWEhgUDxMQCg0LBAUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABggHEBUSFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEBUSBggHAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgMCDhMQFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWDhMQAgMCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAUEEhgUFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "EhgUBAUEAAAAAAAAAAAAAAAAAAAAAAAAAAAABAUFExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVBAUFAAAAAAAAAAAAAAAAAAAAAgMCEhgUFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWEhgUAgMCAAAAAAAAAAAAAAAADhMQFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWDhMQAAAAAAAAAAAABggH"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWBggHAAAAAAAAEBUSFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUEhgUEhgU"
    "EhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUEhgUEhgUEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEBUS"
    "AAAABAUEFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWcXVyys7Ky87Ky87Ky87KmZ6aFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "mZ6ay87Ky87Ky87Kys7KcXZyFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWBAUECg0LFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L"
    "8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy87KEhgUFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWCg0LDxMRFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWDxMQEhgUFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWmZ2Z8fTw8vXx8vXx8vXxyczIFRsXFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXyczI8vXx8vXx8vXx8fTw"
    "mZ2ZFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWGiAcQkhEQ0hEQ0hEQ0hEIykl"
    "FBoWKC4qO0E9O0E9O0E9OT87FhwYFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFhwYOT87O0E9O0E9O0E9KC4qFBoWIyklQ0hEQ0hEQ0hEQkhEGiAcFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWrrKv9Pfz9Pfz9Pfz9Pfz3eDcKS8r7vDt9Pfz9Pfz9Pfz9PfzjJCMFRsXFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXjJCM9Pfz9Pfz9Pfz9Pfz7vHtKS8r3eDc9Pfz"
    "9Pfz9Pfz9PfzrrKvFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx"
    "8vXx8vXx8vXxQ0hE9Pfz8vXx8vXx8vXx8vXxp6qnFRsXFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFRsXp6qn8vXx8vXx8vXx8vXx9PfzQ0hE8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxQ0hE9Pfz8vXx8vXx8vXx8vXxp6qnFRsX"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXp6qn8vXx8vXx8vXx8vXx9Pfz"
    "Q0hE8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgU"
    "y8/L8vXx8vXx8vXx8vXx8vXxQ0hE9Pfz8vXx8vXx8vXx8vXxp6qnFRsXFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXp6qn8vXx8vXx8vXx8vXx9PfzQ0hE8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUyczI8vXx8vXx8vXx8vXx8fTwP0RA9Pfz8vXx8vXx8vXx"
    "8vXxpKekFRsXFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXpKil8vXx8vXx"
    "8vXx8vXx9PfzP0RA8fTw8vXx8vXx8vXx8vXxyczIEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWVltXqKuoqaypqaypqaypdnp3FRsXi46LqayoqayoqayopailQ0hEFBoWFRsXFRsXFRsXFRsXFRsXFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFRsXFRsXFRsXFRsXFRsXFBoWQ0hEpailqayoqayoqayoi4+LFRsXdnt4qaypqaypqaypqKuoVlpXFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWRktHkJWRkZWRkZWRkZWRYmZjFBoWFRsX"
    "FRsXFRsXFRsXFRsXFBoWKjAsi5CMkJWRkJWRkJWRfoJ/Fx0ZFBoWFBoWFBoWFBoWFBoWFBoWFx0ZfoN/kJWRkJWRkJWRi5CMKjAs"
    "FBoWFRsXFRsXFRsXFRsXFRsXFBoWYmdjkZWRkZWRkZWRkJWRRktHFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWExkVxsnG8vXx8vXx8vXx8vXx8PPvGR8bFBoWFBoWFBoWFBoWFBoWFRsXio6K8vXx8vXx8vXx8vXx8vXx"
    "UFZRFBoWFBoWFBoWFBoWFBoWFBoWUVZS8vXx8vXx8vXx8vXx8vXxio6KFRsXFBoWFBoWFBoWFBoWFBoWGR8b8PLv8vXx8vXx8vXx"
    "8vXxxsnFExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx"
    "8vXxHCIeFBoWFBoWFBoWFBoWFBoWFRsXj5OP8vXx8vXx8vXx8vXx8vXxVltXFBoWFBoWFBoWFBoWFBoWFBoWVltX8vXx8vXx8vXx"
    "8vXx8vXxj5OPFRsXFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFRsXj5OP8vXx8vXx"
    "8vXx8vXx8vXxVltXFBoWFBoWFBoWFBoWFBoWFBoWVltX8vXx8vXx8vXx8vXx8vXxj5OPFRsXFBoWFBoWFBoWFBoWFBoWHCIe8vXx"
    "8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx"
    "8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFRsXj5OP8vXx8vXx8vXx8vXx8vXxVltXFBoWFBoWFBoWFBoWFBoWFBoWVltX"
    "8vXx8vXx8vXx8vXx8vXxj5OPFRsXFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVuby58vXx8vXx8vXx8vXx5unlFx0ZFBoWFBoWFBoWFBoWFBoWFRsX"
    "foJ+8vXx8vXx8vXx8vXx8/byQ0lFFBoWFBoWFBoWFBoWFBoWFBoWQ0lE8/by8vXx8vXx8vXx8vXxfoJ+FRsXFBoWFBoWFBoWFBoW"
    "FBoWFx0Z5unl8vXx8vXx8vXx8vXxuby5ExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWJComVFlVVFlVVFlVVFlVMTYyFBoWFBoWFBoWFBoWFBoWFBoWFBoWGB4aUlZTVltXVltXVltXRElFFBoWFBoWFBoWFRsWFRsW"
    "FBoWFBoWFBoWRElFVltXVltXVltXUlZSGB4aFBoWFBoWFBoWFBoWFBoWFBoWFBoWMTYyVFlVVFlVVFlVVFlVJComFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWhYmG4+Xi4+Xi4+Xi4+XisbWyFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWMj4deZQveJMvMj4dFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWsrWy4+Xi4+Xi4+Xi4+XihYmFFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWMT0e"
    "wu1AyPVCyPVCwu1AMT0eFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/L"
    "EhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIe"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsWeZQvyPVCyPVCyPVCyPVCeZQvFRsWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFRsWeJQvyPVCyPVCyPVCyPVCeJMvFRsWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx"
    "8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx"
    "8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWMTwdwe1AyPVCyPVCwu1AMTwdFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWhImF4+Xi4+Xi4+Xi4+XisbWxFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWMT0deZQveJMuMT0dFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "sbWx4+Xi4+Xi4+Xi4+XihYmFFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWJCom"
    "VFlVVFlVVFlVVFlVMTYzFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsWFRsWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWMTczVFlVVFlVVFlVVFlVJComFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVub258vXx8vXx8vXx8vXx5unlFx0ZFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFx0Z5unm8vXx8vXx8vXx8vXxub25ExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXx"
    "y8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVxsnG8vXx8vXx8vXx8vXx8PPv"
    "GR8bFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWGR8b8PPv8vXx8vXx8vXx8vXxxsnGExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWRUtHkJSQkZWRkZWRkZWRYGVhFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWYWVikZWR"
    "kZWRkZWRkJSQRUpHFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWVltYqaypqayp"
    "qaypqaypd3t4ExoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVd3t4qaypqaypqaypqaypVltXFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUyMzI8vXx8vXx8vXx8vXx8fTwGiAcFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "GyEd8fTw8vXx8vXx8vXx8vXxyMzIEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgU"
    "y8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgU"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWrrKu9Pfz9Pfz9Pfz9Pfz3eDcFhwYFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFhwY3eDc9Pfz9Pfz9Pfz9PfzrrKuFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWGSAcQkhEQ0hEQ0hEQ0hEIyklFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWIyklQ0hEQ0hEQ0hE"
    "QkhEGSAcFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWmZ2a8fTw8vXx8vXx8vXx"
    "yczIFRsXFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFRsXyczJ8vXx8vXx8vXx8fTwmZ2aFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx"
    "8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx"
    "8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWEhgUDxMRFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUy8/L8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWHCIe8vXx8vXx8vXx8vXx8vXxy8/LEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWDxMRCg0LFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "EhgUy87K8vXx8vXx8vXx8vXx8vXxHCIeFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWHCIe8vXx8vXx8vXx8vXx8vXxy87KEhgUFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWCg0LBAUEFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWcHVxys7Ky87Ky87Ky87KmZ2ZFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWmZ2Zy87Ky87Ky87Kys7KcHVxFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWBAUEAAAAEBUSFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWEhgUEhgUEhgUEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUEhgUEhgUEhgUFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWEBUSAAAAAAAABggHFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWBggHAAAAAAAAAAAA"
    "DhMQFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWDhMQAAAAAAAAAAAAAAAAAgICEhgUFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUAgICAAAA"
    "AAAAAAAAAAAAAAAABAUFExkVFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWExkVBAUFAAAAAAAAAAAAAAAAAAAAAAAAAAAABAUFEhgUFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhgUBAUF"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgMCDhMPFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWDhMPAgMCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "BggGEBUSFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEBUSBggG"
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAUECg0LDxMQEhcUFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoW"
    "FBoWFBoWFBoWFBoWFBoWFBoWFBoWFBoWEhcUDxMQCg0LBAUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
)
LOGO_RGB_PIXELS = base64.b64decode(LOGO_RGB_PIXELS_B64)
assert len(LOGO_RGB_PIXELS) == LOGO_SIZE * LOGO_SIZE * 3
LOGO_DEFLATE = zlib.compress(LOGO_RGB_PIXELS, 6)


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
    """One Middle Out frame: a 100-byte v2 header + payload + 4-byte payload
    CRC. to_bytes always writes v2; from_bytes also parses v1 frames."""

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
            ">4sBHBHBBHHIQQ32s16s12s",
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
        # Smallest possible frame is a v1 frame with an empty payload.
        if len(raw) < HEADER_SIZE_V1 + 4:
            raise CorruptFrameError("frame shorter than header + CRC")
        if raw[:4] != MAGIC:
            raise CorruptFrameError("bad magic")
        version = raw[4]
        if version == VERSION:
            header_size, header_struct = HEADER_SIZE, HEADER_STRUCT
        elif version == 1:
            header_size, header_struct = HEADER_SIZE_V1, HEADER_STRUCT_V1
        else:
            raise CorruptFrameError(f"unsupported frame version {version}")
        if len(raw) < header_size + 4:
            raise CorruptFrameError("frame shorter than header + CRC")
        header = raw[:header_size]
        fields = struct.unpack(header_struct, header)
        (
            _magic,
            _version,
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
        if zlib.crc32(header[: header_size - 4]) & _MASK32 != header_crc:
            raise CorruptFrameError("header CRC mismatch")
        if len(raw) != header_size + payload_len + 4:
            raise CorruptFrameError(
                f"frame length {len(raw)} != header + {payload_len} + CRC"
            )
        payload = raw[header_size : header_size + payload_len]
        (payload_crc,) = struct.unpack(">I", raw[header_size + payload_len :])
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
            f"This file needs {total_frames} frames — over the {MAX_FRAMES}-frame "
            "limit for one PDF. Split it into smaller files and encode each "
            "one separately."
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
# Visual codes: Middle Out Code grid + bar-grid barcode (+ legacy stacked rows)
#
# The frames are rendered as full-page codes. A real ISO QR code holds ~3 KB;
# a Middle Out frame holds up to 64 KiB, so the 2D mode is a custom grid
# (QR-style finders, timing patterns, centre tile reserved for the logo)
# rather than an ISO QR code. Barcode mode uses the SAME grid layout with a
# 4x-stretched aspect: drawn into the full landscape page rect, the
# non-uniform scale stretches each module into a tall thin rectangle, so
# adjacent black modules merge into vertical bars. The legacy stacked-row
# barcode (PDF417-style rows) is still parsed, so old barcode PDFs keep
# decoding — but never written. All formats carry a 4-byte big-endian
# length prefix so the parser knows where the payload ends and the padding
# begins.
#
# Grids are RECTANGULAR (w x h): QR grids match the A4 landscape aspect
# (~1.41421), bar-grids stretch it 4x (~5.65685). choose_grid_size steps h
# by 2 from 32 with w = round(h * aspect). The reserved regions are the
# three 8x8 finder blocks (192 cells), the timing row (w-16 cells) and
# timing column (h-16 cells), and the centre logo tile (tileW x tileH
# cells). The tile is square AS DRAWN (in points) for landscape grids:
# tileW = max(8, halfUp(w * 595.28 / (4 * 841.89))),
# tileH = max(8, halfUp(h / 4)) — so the logo fills a square tile in
# both formats instead of a tall pillar in the bar-grid. Square grids
# (w == h: the old format) keep the original rule, side =
# max(8, min(w,h)//4), tileW = tileH = side, so old goldens stay
# byte-identical. The three regions never overlap for w,h >= 32
# (proven by test_capacity_formula_matches_independent_count), so the
# capacity is pure arithmetic — no reserved-cell set is ever built.
# ---------------------------------------------------------------------------

GRID_QUIET_MODULES = 4
BARCODE_ROW_BYTES = 64
BARCODE_ROW_BARS = 4 + 8 + BARCODE_ROW_BYTES * 8 + 4  # 528 bars per row
BARCODE_BAR_PX = 2
BARCODE_ROW_PX = 24
BARCODE_GAP_PX = 4


def _half_up(x: float) -> int:
    """Round-half-up: floor(x + 0.5). Python's round() is banker's
    rounding and disagrees on exact .5 cases; Dart's double.round()
    rounds half away from zero, i.e. half-up for non-negative x — so
    this is the bit-for-bit match with the Dart side."""
    return math.floor(x + 0.5)


def _centre_tile(w: int, h: int) -> tuple[int, int, int, int]:
    """(start_row, start_col, tile_w, tile_h) of the logo tile, centred.

    SQUARE grids (w == h — the old format): the original rule, side =
    max(8, n//4), tile_w = tile_h = side. Unchanged, so old goldens
    stay byte-identical.

    LANDSCAPE grids (w != h): the tile is square AS DRAWN (in points).
    A module draws CODE_PAGE_WIDTH/w points wide and
    CODE_PAGE_HEIGHT/h points tall, so a square-in-points tile needs
    tileW/tileH = (h/w) * (CODE_PAGE_WIDTH/CODE_PAGE_HEIGHT); with the
    tile height at a quarter of the grid height this gives
    tileW = max(8, halfUp(w * 595.28 / (4 * 841.89))),
    tileH = max(8, halfUp(h / 4)). Check: QR full frame 885x626 ->
    156x157 (nearly unchanged); bar full frame 1742x308 -> 308x77
    modules = 148.8x148.8 pt square as drawn."""
    if w == h:
        side = max(8, min(w, h) // 4)
        return (h - side) // 2, (w - side) // 2, side, side
    tile_w = max(8, _half_up(w * CODE_PAGE_HEIGHT / (BARCODE_STRETCH * CODE_PAGE_WIDTH)))
    tile_h = max(8, _half_up(h / 4))
    return (h - tile_h) // 2, (w - tile_w) // 2, tile_w, tile_h


def is_reserved(
    r: int,
    c: int,
    w: int,
    h: int,
    centre_start_row: int,
    centre_start_col: int,
    centre_tile_w: int,
    centre_tile_h: int,
) -> bool:
    """True when cell (r, c) of a w x h grid is reserved for a structural
    pattern — a finder block, the timing row/column, or the centre logo
    tile — and cannot carry a data bit.

    All reserved regions are rectangles/lines, so membership is a few O(1)
    range checks with zero allocation. The previous implementation built a
    set of every reserved cell on every call and probed it per cell — the
    Dart side measured that at ~100x slower than the arithmetic checks.
    The centre tile is passed precomputed (see _centre_tile) so the
    per-cell loop never recomputes it."""
    # Three 8x8 finder blocks: top-left, top-right, bottom-left.
    if r < 8 and c < 8:
        return True
    if r < 8 and c >= w - 8:
        return True
    if r >= h - 8 and c < 8:
        return True
    # Timing row 6 / column 6, between the finders.
    if r == 6 and 8 <= c < w - 8:
        return True
    if c == 6 and 8 <= r < h - 8:
        return True
    # Centre logo tile.
    return (
        centre_start_row <= r < centre_start_row + centre_tile_h
        and centre_start_col <= c < centre_start_col + centre_tile_w
    )


def grid_capacity_bits(w: int, h: int) -> int:
    """Placeable (non-reserved) cells of a w x h grid, in bits."""
    _, _, tile_w, tile_h = _centre_tile(w, h)
    return w * h - 192 - (w - 16) - (h - 16) - tile_w * tile_h


def choose_grid_size(
    payload_len: int, aspect: float = QR_ASPECT
) -> tuple[int, int]:
    """Smallest (w, h) with w/h ~= [aspect] whose data cells fit the
    payload plus its 4-byte length prefix. h steps by 2 from 32;
    w = round(h * aspect), at least 32.

    The rounding is int(h * aspect + 0.5) — round-half-up — to match
    Dart's double.round() bit-for-bit; Python's round() is banker's
    rounding and would disagree on an exact .5."""
    need_bits = (payload_len + 4) * 8
    h = GRID_MIN_HEIGHT
    while True:
        w = max(GRID_MIN_HEIGHT, int(h * aspect + 0.5))
        if grid_capacity_bits(w, h) >= need_bits:
            return w, h
        h += GRID_HEIGHT_STEP
        if h > GRID_MAX_HEIGHT:
            raise CodecError("payload too large for a single code grid")


def build_grid(payload: bytes, aspect: float = QR_ASPECT) -> list[bytearray]:
    """Render [payload] into a w x h module matrix (1 = black, 0 = white),
    w/h ~= [aspect] (QR_ASPECT by default). Bit order is unchanged:
    row-major over the placeable cells, MSB first, with a 4-byte
    big-endian length prefix."""
    blob = struct.pack(">I", len(payload)) + payload
    w, h = choose_grid_size(len(payload), aspect)
    grid: list[bytearray] = [bytearray(w) for _ in range(h)]
    cs_r, cs_c, tile_w, tile_h = _centre_tile(w, h)

    # Finder patterns: 7x7, outer ring black, middle ring white, core 3x3 black.
    for r0, c0 in ((0, 0), (0, w - 7), (h - 7, 0)):
        for dr in range(7):
            for dc in range(7):
                on_ring = dr in (0, 6) or dc in (0, 6)
                in_core = 2 <= dr <= 4 and 2 <= dc <= 4
                grid[r0 + dr][c0 + dc] = 1 if (on_ring or in_core) else 0
    # Timing row/column 6, alternating black/white starting black.
    for i in range(8, w - 8):
        grid[6][i] = 1 if i % 2 == 0 else 0
    for i in range(8, h - 8):
        grid[i][6] = 1 if i % 2 == 0 else 0

    # Data bits, row-major over the placeable cells, MSB first.
    bit_index = 0
    total_bits = len(blob) * 8
    for r in range(h):
        row = grid[r]
        for c in range(w):
            if is_reserved(r, c, w, h, cs_r, cs_c, tile_w, tile_h):
                continue
            if bit_index >= total_bits:
                return grid
            row[c] = (blob[bit_index >> 3] >> (7 - (bit_index & 7))) & 1
            bit_index += 1
    return grid


def build_barcode_grid(payload: bytes) -> list[bytearray]:
    """Bar-grid barcode: the same grid layout as build_grid, but with the
    4x-stretched aspect. Drawn into the full landscape page rect, the
    non-uniform scale stretches each module into a tall thin rectangle,
    so adjacent black modules merge into vertical bars. Parsing needs no
    stretch knowledge — parse_grid reads the 1 px-per-module image."""
    return build_grid(payload, BARCODE_ASPECT)


def parse_grid(grid: list[bytearray]) -> bytes:
    """Inverse of build_grid: read the length prefix, then the payload.
    Works for any w x h grid, including old square ones (w == h).

    Streams the placeable bits row-major into bytes instead of building
    a bit list: a full-frame grid holds ~525k bits."""
    h = len(grid)
    if h == 0:
        raise CodecError("empty grid")
    w = len(grid[0])
    cs_r, cs_c, tile_w, tile_h = _centre_tile(w, h)
    capacity = grid_capacity_bits(w, h)
    if capacity < 32:
        raise CodecError("grid too small to hold a length prefix")
    length: int | None = None
    prefix = bytearray()
    out = bytearray()
    acc = 0
    nbits = 0
    for r in range(h):
        row = grid[r]
        for c in range(w):
            if is_reserved(r, c, w, h, cs_r, cs_c, tile_w, tile_h):
                continue
            acc = (acc << 1) | (row[c] & 1)
            nbits += 1
            if nbits == 8:
                if length is None:
                    prefix.append(acc)
                    if len(prefix) == 4:
                        (length,) = struct.unpack(">I", bytes(prefix))
                        if length * 8 + 32 > capacity:
                            raise CodecError(
                                "grid length prefix exceeds grid capacity"
                            )
                        if length == 0:
                            return b""
                else:
                    out.append(acc)
                    if len(out) == length:
                        return bytes(out)
                acc = 0
                nbits = 0
    if length is None:
        raise CodecError("grid too small to hold a length prefix")
    raise CodecError("grid ends before the payload does")


def build_barcode_rows(payload: bytes) -> list[bytearray]:
    """Stacked-row barcode: each row is a bar strip carrying 64 payload bytes
    plus a 1-byte row index. Row layout (bars, 1 = black):
    [4 start guard][8 row index][512 data][4 stop guard] = 528 bars.

    LEGACY: new PDFs use the bar-grid (build_barcode_grid) instead. These
    rows are only built by tests now; parse_barcode_rows stays so old
    barcode PDFs keep decoding."""
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
    """Inverse of build_barcode_rows. Rows are reassembled by their index,
    so a scan that reads them out of order still decodes.

    The row index is 8 bits, so a frame needing more than 256 rows
    (payload above ~16 KiB — every full 64 KiB frame needs 1,026 rows)
    wraps: rows 256+ reuse indices 0+. When indices collide the index
    cannot order the rows, so they are reassembled in list order
    instead — PDF extraction and camera scans both read top-to-bottom,
    so list order is the row order. Unique indices keep the old
    index-ordered behaviour.
    """
    if not rows:
        raise CodecError("no barcode rows")
    width = len(rows[0])
    if width != BARCODE_ROW_BARS:
        raise CodecError(f"unexpected barcode row width {width}")
    chunks: dict[int, bytes] = {}
    ordered: list[bytes] = []
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
        chunk = bytes(data)
        chunks[index] = chunk
        ordered.append(chunk)
    if len(chunks) == len(rows):
        # No index collision: reassemble by index (out-of-order scans OK).
        blob = b"".join(chunks[i] for i in sorted(chunks))
    else:
        # Indices wrapped past 256 rows: reassemble in list order.
        blob = b"".join(ordered)
    (length,) = struct.unpack(">I", blob[:4])
    if length + 4 > len(blob):
        raise CodecError("barcode length prefix exceeds payload")
    return blob[4 : 4 + length]


# ---------------------------------------------------------------------------
# 1-bit image packing (mirrors lib/codec/png_encode.dart)
# ---------------------------------------------------------------------------

# bytes.translate tables: 0 <-> 1 (for 0/1 matrices), and bitwise NOT
# (for packed pixel bytes — NOT the same operation).
_FLIP_01_TABLE = bytes(1 if i == 0 else 0 if i == 1 else i for i in range(256))
_BIT_INVERT_TABLE = bytes(255 - i for i in range(256))


def pack_1bit(grid: list[bytearray]) -> bytes:
    """Pack a w x h module matrix (1 = black) into predictor-1 packed bits
    for a DeviceGray image XObject: MSB first, inverted (0 = black).
    Pad bits past the row width are zero (they are the low bits of the
    last byte, left as 0 by the shift)."""
    h = len(grid)
    w = len(grid[0]) if h else 0
    stride = (w + 7) // 8
    raw = bytearray(h * stride)
    for y in range(h):
        row = grid[y]
        base = y * stride
        current = 0
        bits = 0
        offset = base
        for x in range(w):
            # DeviceGray 1-bit: 0 = black — pack our 1 = black modules inverted.
            current = (current << 1) | (row[x] ^ 1)
            bits += 1
            if bits == 8:
                raw[offset] = current
                offset += 1
                current = 0
                bits = 0
        if bits:
            raw[offset] = current << (8 - bits)
    return bytes(raw)


def deflate_1bit(grid: list[bytearray], invert: bool = False) -> bytes:
    """zlib-compress packed 1-bit pixels for a PDF image XObject
    (predictor 1: packed bits, no filter bytes). Level 6, like Dart: on
    random grid data level 9 buys nothing, and on repetitive data level 6
    is far faster. [invert] flips every pixel for dark-theme pages (pad
    bits are re-zeroed after the flip)."""
    packed = bytearray(pack_1bit(grid))
    if invert:
        packed = bytearray(bytes(packed).translate(_BIT_INVERT_TABLE))
        # The flip sets the pad bits to 1; put them back to 0.
        w = len(grid[0])
        stride = (w + 7) // 8
        pad_bits = stride * 8 - w
        if pad_bits:
            mask = (0xFF << pad_bits) & 0xFF
            for y in range(len(grid)):
                packed[y * stride + stride - 1] &= mask
    return zlib.compress(bytes(packed), 6)


# ---------------------------------------------------------------------------
# Image rendering / sampling (PIL — used by the image round-trip tests only;
# the PDF path embeds packed bits directly and needs no imaging library)
# ---------------------------------------------------------------------------


def render_grid_image(grid: list[bytearray], module_px: int = 4,
                      quiet: int = GRID_QUIET_MODULES):
    """Render a module matrix to a 1-bit PIL image with a quiet zone."""
    from PIL import Image

    h = len(grid)
    w = len(grid[0])
    width = (w + 2 * quiet) * module_px
    height = (h + 2 * quiet) * module_px
    img = Image.new("1", (width, height), 1)
    px = img.load()
    for r in range(h):
        for c in range(w):
            if grid[r][c]:
                x0 = (c + quiet) * module_px
                y0 = (r + quiet) * module_px
                for y in range(y0, y0 + module_px):
                    for x in range(x0, x0 + module_px):
                        px[x, y] = 0
    return img


def sample_grid_image(img, module_px: int = 4,
                      quiet: int = GRID_QUIET_MODULES) -> list[bytearray]:
    """Sample a rendered grid image back to a module matrix (module centres)."""
    w = img.width // module_px - 2 * quiet
    h = img.height // module_px - 2 * quiet
    if w <= 0 or h <= 0:
        raise CodecError("grid image too small")
    grey = img.convert("L")
    px = grey.load()
    grid: list[bytearray] = []
    for r in range(h):
        row = bytearray(w)
        for c in range(w):
            x = (c + quiet) * module_px + module_px // 2
            y = (r + quiet) * module_px + module_px // 2
            row[c] = 1 if px[x, y] < 128 else 0
        grid.append(row)
    return grid


def render_barcode_image(rows: list[bytearray]):
    """Render legacy stacked barcode rows to a 1-bit PIL image."""
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
    """Sample a rendered legacy barcode image back to bar rows."""
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


# ---------------------------------------------------------------------------
# Minimal PDF writer (mirrors lib/codec/pdf_writer.dart)
#
# Hand-rolled: the 1-bit code images are embedded verbatim as DeviceGray
# image XObjects — no PIL/reportlab re-encode step ever runs on them.
# (The old reportlab path decoded each 1-bit PNG to RGB and re-deflated
# it; the Dart side measured ~194 ms per frame inside doc.save() for that,
# vs ~1 ms to serialise a page here.)
#
# Document shape (fixed): Catalog, Pages, Helvetica + Helvetica-Bold
# (standard-14 fonts, never embedded), one shared RGB logo XObject (when
# the document has frame pages), then per page: Page, Flate content
# stream, code image XObject.
# The image dicts deliberately contain NO nested dictionary: the extractor
# finds an image dict by scanning back to the nearest `<<` before `stream`,
# so a nested DecodeParms dict would be found instead of the outer dict.
# The image streams are therefore predictor 1 (packed bits, no filter
# bytes, no DecodeParms).
# ---------------------------------------------------------------------------

# Common punctuation mapped to its WinAnsi (cp1252) byte, so file names
# and the cover manifest keep their dashes and quotes instead of degrading
# to '?'. Mirrors _winAnsiPunctuation in pdf_writer.dart.
_WIN_ANSI_PUNCTUATION = {
    0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
    0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
    0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
    0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
    0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
    0x017E: 0x9E, 0x0178: 0x9F,
}


def _pdf_escape(s: str) -> str:
    """PDF literal-string escaping: backslash, parens; chars outside
    printable ASCII / WinAnsi 160-255 become '?' unless they have a
    WinAnsi mapping above. The em-dash in the cover manifest (U+2014)
    maps to WinAnsi 0x97."""
    out = []
    for ch in s:
        code = ord(ch)
        if code in (0x28, 0x29, 0x5C):
            out.append("\\")
            out.append(ch)
        elif (32 <= code <= 126) or (160 <= code <= 255):
            out.append(ch)
        elif code in _WIN_ANSI_PUNCTUATION:
            out.append(chr(_WIN_ANSI_PUNCTUATION[code]))
        else:
            out.append("?")
    return "".join(out)


def _pdf_num(v: float) -> str:
    """A PDF number: 2 decimals, trailing zeros (and a trailing dot) cut."""
    s = f"{v:.2f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def _latin1_bytes(s: str) -> bytes:
    return bytes(ord(c) if ord(c) <= 255 else 0x3F for c in s)


def _text_op(s: str, size: float, x: float, y: float, bold: bool = False) -> str:
    font = "F2" if bold else "F1"
    return (
        f"BT /{font} {_pdf_num(size)} Tf "
        f"{_pdf_num(x)} {_pdf_num(y)} Td ({_pdf_escape(s)}) Tj ET\n"
    )


def _image_op(name: str, w: float, h: float, x: float, y: float) -> str:
    return (
        f"q {_pdf_num(w)} 0 0 {_pdf_num(h)} "
        f"{_pdf_num(x)} {_pdf_num(y)} cm /{name} Do Q\n"
    )


@dataclass
class _PdfPageSpec:
    is_cover: bool
    manifest_lines: list[str] = field(default_factory=list)
    image_width: int = 0
    image_height: int = 0
    image_deflate: bytes = b""
    logo_rect: tuple[float, float, float, float] | None = None  # x, y, w, h
    dark: bool = False


def _page_content(page: _PdfPageSpec) -> bytes:
    """The page's content-stream operators (uncompressed)."""
    ops: list[str] = []
    if page.is_cover:
        # Unchanged cover layout (same text, sizes and margins as the old
        # reportlab cover): title, subtitle, manifest lines, portrait A4.
        mm = 72 / 25.4
        width, height = COVER_PAGE_WIDTH, COVER_PAGE_HEIGHT
        ops.append(_text_op("MIDDLE OUT", 34, 20 * mm, height - 30 * mm, bold=True))
        ops.append(_text_op("Lossless file, printed as code.", 12, 20 * mm, height - 42 * mm))
        y = height - 60 * mm
        for line in page.manifest_lines:
            ops.append(_text_op(line, 11, 20 * mm, y))
            y -= 7 * mm
    else:
        # Full-bleed code page: the image spans the ENTIRE landscape rect
        # — no margins, no caption, no quiet zone. Dark pages paint the
        # background black first (the code pixels are inverted too).
        if page.dark:
            ops.append(
                f"0 g 0 0 {_pdf_num(CODE_PAGE_WIDTH)} "
                f"{_pdf_num(CODE_PAGE_HEIGHT)} re f\n"
            )
        ops.append(_image_op("Im0", CODE_PAGE_WIDTH, CODE_PAGE_HEIGHT, 0, 0))
        if page.logo_rect is not None:
            x, y, w, _h = page.logo_rect
            ops.append(_logo_op(x, y, w))
    return _latin1_bytes("".join(ops))


class RawPdfWriter:
    """Minimal PDF writer: 1 portrait cover page + 1 landscape full-bleed
    code page per frame, each frame embedded as a 1-bit DeviceGray image
    XObject plus the RGB logo tile over its centre."""

    def __init__(self) -> None:
        self._pages: list[_PdfPageSpec] = []

    def add_cover_page(self, manifest_lines: list[str]) -> None:
        self._pages.append(
            _PdfPageSpec(is_cover=True, manifest_lines=list(manifest_lines))
        )

    def add_frame_page(
        self,
        image_width: int,
        image_height: int,
        image_deflate: bytes,
        logo_rect: tuple[float, float, float, float],
        dark: bool = False,
    ) -> None:
        self._pages.append(
            _PdfPageSpec(
                is_cover=False,
                image_width=image_width,
                image_height=image_height,
                image_deflate=image_deflate,
                logo_rect=logo_rect,
                dark=dark,
            )
        )

    @property
    def page_count(self) -> int:
        return len(self._pages)

    def build(self) -> bytes:
        # Object numbering: 1 Catalog, 2 Pages, 3 Helvetica, 4 Helvetica-Bold,
        # 5 the shared RGB logo XObject (only when the document has frame
        # pages), then per page: Page, Contents, and (frame pages only)
        # the code image XObject.
        n = len(self._pages)
        has_logo = any(not page.is_cover for page in self._pages)
        logo_obj = 5 if has_logo else 0
        page_obj: list[int] = []
        content_obj: list[int] = []
        image_obj: list[int] = []  # 0 on the cover (no image)
        nxt = 6 if has_logo else 5
        for page in self._pages:
            page_obj.append(nxt)
            nxt += 1
            content_obj.append(nxt)
            nxt += 1
            if page.is_cover:
                image_obj.append(0)
            else:
                image_obj.append(nxt)
                nxt += 1

        out = bytearray()
        offsets: list[int] = []

        def add_object(body: bytes) -> None:
            offsets.append(len(out))
            out.extend(f"{len(offsets)} 0 obj\n".encode("ascii"))
            out.extend(body)
            out.extend(b"\nendobj\n")

        out.extend(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        kids = " ".join(f"{o} 0 R" for o in page_obj)
        add_object(f"<< /Type /Catalog /Pages 2 0 R >>".encode("ascii"))
        add_object(
            f"<< /Type /Pages /Kids [{kids}] /Count {n} >>".encode("ascii")
        )
        add_object(
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
            b"/Encoding /WinAnsiEncoding >>"
        )
        add_object(
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold "
            b"/Encoding /WinAnsiEncoding >>"
        )
        if has_logo:
            # One shared logo XObject, referenced by every frame page.
            add_object(
                (
                    f"<< /Type /XObject /Subtype /Image "
                    f"/Width {LOGO_SIZE} /Height {LOGO_SIZE} "
                    f"/BitsPerComponent 8 /ColorSpace /DeviceRGB "
                    f"/Filter /FlateDecode "
                    f"/Length {len(LOGO_DEFLATE)} >>\n"
                ).encode("ascii")
                + b"stream\n"
                + LOGO_DEFLATE
                + b"\nendstream"
            )
        for i, page in enumerate(self._pages):
            if page.is_cover:
                mediabox = (
                    f"[0 0 {_pdf_num(COVER_PAGE_WIDTH)} "
                    f"{_pdf_num(COVER_PAGE_HEIGHT)}]"
                )
                xobjects = ""
            else:
                mediabox = (
                    f"[0 0 {_pdf_num(CODE_PAGE_WIDTH)} "
                    f"{_pdf_num(CODE_PAGE_HEIGHT)}]"
                )
                xobjects = (
                    f" /XObject << /Im0 {image_obj[i]} 0 R "
                    f"/Im1 {logo_obj} 0 R >>"
                )
            add_object(
                (
                    f"<< /Type /Page /Parent 2 0 R /MediaBox {mediabox} "
                    f"/Resources << /Font << /F1 3 0 R /F2 4 0 R >>"
                    f"{xobjects} "
                    f"/ProcSet [/PDF /Text /ImageB /ImageC] >> "
                    f"/Contents {content_obj[i]} 0 R >>"
                ).encode("ascii")
            )
            compressed = zlib.compress(_page_content(page), 6)
            add_object(
                f"<< /Length {len(compressed)} /Filter /FlateDecode >>\n".encode("ascii")
                + b"stream\n"
                + compressed
                + b"\nendstream"
            )
            if page.is_cover:
                continue
            add_object(
                (
                    f"<< /Type /XObject /Subtype /Image "
                    f"/Width {page.image_width} /Height {page.image_height} "
                    f"/BitsPerComponent 1 /ColorSpace /DeviceGray "
                    f"/Filter /FlateDecode "
                    f"/Length {len(page.image_deflate)} >>\n"
                ).encode("ascii")
                + b"stream\n"
                + page.image_deflate
                + b"\nendstream"
            )

        xref_at = len(out)
        total = len(offsets) + 1
        xref = ["xref", f"0 {total}", "0000000000 65535 f "]
        for off in offsets:
            xref.append(f"{off:010d} 00000 n ")
        xref.extend(
            [
                "trailer",
                f"<< /Size {total} /Root 1 0 R >>",
                "startxref",
                str(xref_at),
                "%%EOF",
            ]
        )
        out.extend(("\n".join(xref) + "\n").encode("ascii"))
        return bytes(out)


@dataclass
class PdfStats:
    pages: int
    size_bytes: int
    frames: int


def logo_rect_for_grid(w: int, h: int) -> tuple[float, float, float, float]:
    """Logo overlay rect (x, y, width, height) in points on a landscape
    code page. The logo is drawn SQUARE — side = min(tileW, tileH),
    centred in the centre-tile rect — so it is never stretched. With
    the square-as-drawn tile rule the tile is (nearly) square in
    points for both formats, so the logo fills the tile: for the QR
    grid the tile is 156x157 modules and the logo fills it exactly,
    and for the bar-grid the tile is 308x77 modules = 148.8x148.8 pt
    and the logo fills it too. Drawing the logo wider than the
    reserved tile would cover live data modules. PDF Y is bottom-up
    while grid rows are top-down."""
    start_row, start_col, tile_w, tile_h = _centre_tile(w, h)
    tile_w_pt = tile_w / w * CODE_PAGE_WIDTH
    tile_h_pt = tile_h / h * CODE_PAGE_HEIGHT
    logo_side = min(tile_w_pt, tile_h_pt)
    x = start_col / w * CODE_PAGE_WIDTH + (tile_w_pt - logo_side) / 2
    tile_bottom = CODE_PAGE_HEIGHT - (start_row + tile_h) / h * CODE_PAGE_HEIGHT
    y = tile_bottom + (tile_h_pt - logo_side) / 2
    return (x, y, logo_side, logo_side)


def _logo_op(x: float, y: float, side: float) -> str:
    """The logo tile, drawn with a rounded-rectangle clip (bezier
    corners, kappa = 0.5523, radius 0.2 * side) so the tile keeps its
    rounded corners. Mirrors _logoOp in pdf_writer.dart."""
    r = side * 0.2
    k = 0.5522847498
    n = _pdf_num
    ops = ["q "]
    ops.append(f"{n(x + r)} {n(y)} m ")
    ops.append(f"{n(x + side - r)} {n(y)} l ")
    ops.append(
        f"{n(x + side - r + k * r)} {n(y)} "
        f"{n(x + side)} {n(y + r - k * r)} "
        f"{n(x + side)} {n(y + r)} c "
    )
    ops.append(f"{n(x + side)} {n(y + side - r)} l ")
    ops.append(
        f"{n(x + side)} {n(y + side - r + k * r)} "
        f"{n(x + side - r + k * r)} {n(y + side)} "
        f"{n(x + side - r)} {n(y + side)} c "
    )
    ops.append(f"{n(x + r)} {n(y + side)} l ")
    ops.append(
        f"{n(x + r - k * r)} {n(y + side)} "
        f"{n(x)} {n(y + side - r + k * r)} "
        f"{n(x)} {n(y + side - r)} c "
    )
    ops.append(f"{n(x)} {n(y + r)} l ")
    ops.append(
        f"{n(x)} {n(y + r - k * r)} "
        f"{n(x + r - k * r)} {n(y)} "
        f"{n(x + r)} {n(y)} c "
    )
    ops.append("h W n\n")
    ops.append(f"{n(side)} 0 0 {n(side)} {n(x)} {n(y)} cm /Im1 Do Q\n")
    return "".join(ops)


def build_pdf(
    result: EncodeResult,
    file_name: str,
    out_path: str,
    dark: bool = False,
) -> PdfStats:
    """Assemble the encoded PDF: 1 portrait cover page + 1 landscape
    full-bleed code page per frame. [dark] inverts the code pixels and
    paints each code page's background black. Returns page count and file
    size (the 5-20 MB-per-GB band is checked by the caller against the
    original size)."""
    stats = result.stats
    writer = RawPdfWriter()

    # --- Cover page (unchanged: portrait, manifest text) ---
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
    writer.add_cover_page(lines)

    # --- One landscape full-bleed code page per frame ---
    for frame in result.frames:
        raw = frame.to_bytes()
        grid = build_barcode_grid(raw) if result.barcode else build_grid(raw)
        h = len(grid)
        w = len(grid[0])
        writer.add_frame_page(
            image_width=w,
            image_height=h,
            image_deflate=deflate_1bit(grid, invert=dark),
            logo_rect=logo_rect_for_grid(w, h),
            dark=dark,
        )
    pdf_bytes = writer.build()
    with open(out_path, "wb") as fh:
        fh.write(pdf_bytes)

    return PdfStats(
        pages=1 + len(result.frames),
        size_bytes=len(pdf_bytes),
        frames=len(result.frames),
    )


# ---------------------------------------------------------------------------
# PDF frame extraction (mirrors lib/services/pdf_frame_extractor.dart)
#
# The encoder embeds each frame as a 1-bit image XObject; this reader finds
# those XObjects, inflates the FlateDecode streams, and parses the code
# images back to frame blobs — which then feed the normal decode().
#
# The reader is deliberately tolerant: it tries 1-bit and 8-bit greyscale
# (and RGB) images and PNG/TIFF predictors, because the PDF writer's exact
# image encoding is an implementation detail — the golden old-format
# fixtures are 8-bit RGB XObjects from the pre-RawPdfWriter builder.
# Anything it cannot parse is skipped, never guessed: a blob is only
# returned when it parses as a valid frame, so the cover manifest grid
# and alpha masks fall away harmlessly. When a 1-bit image exists the
# RGB logo tile is never attempted at all (the 1-bit images are the
# codes); only when no 1-bit image exists (old-format PDFs) is every
# image attempted.
#
# Format branching is by image aspect, in order: a 528-bar-wide stacked
# geometry means a legacy stacked-row barcode; w/h ~= 5.66 a bar-grid;
# w/h ~= 1.41 a rectangular QR grid; square an old grid (quiet zone 4,
# falling back to 0). Polarity is auto-detected per page from the
# top-left finder (guard bars for stacked barcodes): dark-theme pages
# have every pixel inverted.
# ---------------------------------------------------------------------------


@dataclass
class PdfExtraction:
    frames: list[bytes]
    images_found: int
    images_parsed: int


@dataclass
class _PdfImage:
    width: int
    height: int
    bits_per_component: int
    colors: int
    predictor: int
    stream: bytes
    flate: bool


def _dict_int(dict_text: str, key: str) -> int | None:
    match = re.search(re.escape(key) + r"\s+(\d+)", dict_text)
    return int(match.group(1)) if match else None


def _find_images(pdf: bytes) -> list[_PdfImage]:
    """One entry per image XObject: dictionary fields + raw stream bytes."""
    images: list[_PdfImage] = []
    search_from = 0
    while True:
        stream_at = pdf.find(b"stream", search_from)
        if stream_at < 0:
            break
        # A real stream keyword follows its dictionary's closing ">>"
        # (plus optional EOL) — this skips the "stream" inside "endstream".
        back = stream_at
        while back > 0 and pdf[back - 1] in (0x0A, 0x0D, 0x20, 0x09):
            back -= 1
        if pdf[back - 2 : back] != b">>":
            search_from = stream_at + 6
            continue
        # Stream data starts after "stream" + EOL (\r\n or \n).
        data_start = stream_at + 6
        if data_start < len(pdf) and pdf[data_start] == 0x0D:
            data_start += 1
        if data_start < len(pdf) and pdf[data_start] == 0x0A:
            data_start += 1
        # The dictionary sits just before "stream" — look back for "<<".
        dict_start = pdf.rfind(b"<<", 0, stream_at)
        search_from = data_start
        if dict_start < 0 or stream_at - dict_start > 4096:
            continue
        dict_text = pdf[dict_start:stream_at].decode("latin-1", errors="ignore")
        if "/Subtype" not in dict_text or "/Image" not in dict_text:
            continue
        length = _dict_int(dict_text, "/Length")
        if length is not None and data_start + length <= len(pdf):
            stream = pdf[data_start : data_start + length]
        else:
            end_at = pdf.find(b"endstream", data_start)
            if end_at < 0:
                continue
            end = end_at
            while end > data_start and pdf[end - 1] in (0x0A, 0x0D):
                end -= 1
            stream = pdf[data_start:end]
        width = _dict_int(dict_text, "/Width")
        height = _dict_int(dict_text, "/Height")
        if width is None or height is None:
            continue
        bpc = _dict_int(dict_text, "/BitsPerComponent") or 1
        colors = 3 if "/DeviceRGB" in dict_text else 1
        predictor = _dict_int(dict_text, "/Predictor") or 1
        images.append(
            _PdfImage(
                width=width,
                height=height,
                bits_per_component=bpc,
                colors=colors,
                predictor=predictor,
                stream=stream,
                flate="/FlateDecode" in dict_text,
            )
        )
    return images


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unpredict(raw: bytes, row_bytes: int, image: _PdfImage) -> list[bytes] | None:
    """Undo a FlateDecode predictor, returning one byte-row per image row."""
    predictor = image.predictor
    height = image.height
    if predictor == 1:
        if len(raw) < row_bytes * height:
            return None
        return [raw[y * row_bytes : (y + 1) * row_bytes] for y in range(height)]
    if predictor == 2:
        # TIFF predictor: each sample differs from the one to its left.
        if len(raw) < row_bytes * height:
            return None
        bpp = max(1, min((image.bits_per_component * image.colors + 7) // 8, row_bytes))
        rows: list[bytes] = []
        for y in range(height):
            row = bytearray(raw[y * row_bytes : (y + 1) * row_bytes])
            for i in range(bpp, row_bytes):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
            rows.append(bytes(row))
        return rows
    if 10 <= predictor <= 15:
        # PNG predictors: one filter byte per row.
        stride = row_bytes + 1
        if len(raw) < stride * height:
            return None
        bpp = max(1, min((image.bits_per_component * image.colors + 7) // 8, row_bytes))
        rows = []
        previous = bytes(row_bytes)
        for y in range(height):
            filter_type = raw[y * stride]
            row = bytearray(raw[y * stride + 1 : (y + 1) * stride])
            for i in range(row_bytes):
                a = row[i - bpp] if i >= bpp else 0
                b = previous[i]
                c = previous[i - bpp] if i >= bpp else 0
                if filter_type == 1:
                    predict = a
                elif filter_type == 2:
                    predict = b
                elif filter_type == 3:
                    predict = (a + b) // 2
                elif filter_type == 4:
                    predict = _paeth(a, b, c)
                else:
                    predict = 0
                row[i] = (row[i] + predict) & 0xFF
            rows.append(bytes(row))
            previous = bytes(row)
        return rows
    return None


# Stored DeviceGray byte -> 8 matrix values (1 = black): a stored 0 bit
# is black, so the expansion inverts each bit.
_BIT_EXPAND = [
    bytes(1 - ((v >> (7 - k)) & 1) for k in range(8)) for v in range(256)
]
# 8-bit sample -> matrix value (1 = black below the midpoint).
_THRESHOLD_TABLE = bytes(1 if i < 128 else 0 for i in range(256))


def _decode_image(image: _PdfImage) -> list[bytearray] | None:
    """Inflate and unpack one image XObject into a 0/1 pixel matrix
    (1 = black module), or None when the image cannot be decoded."""
    if not image.flate:
        return None
    try:
        raw = zlib.decompress(image.stream)
    except zlib.error:
        return None
    row_bytes = (image.width * image.bits_per_component * image.colors + 7) // 8
    rows = _unpredict(raw, row_bytes, image)
    if rows is None:
        return None
    matrix: list[bytearray] = []
    if image.bits_per_component == 1 and image.colors == 1:
        for y in range(image.height):
            expanded = b"".join(_BIT_EXPAND[b] for b in rows[y])
            matrix.append(bytearray(expanded[: image.width]))
    elif image.bits_per_component == 8:
        for y in range(image.height):
            row = rows[y]
            if image.colors == 1:
                matrix.append(bytearray(row.translate(_THRESHOLD_TABLE)))
            else:
                matrix.append(
                    bytearray(
                        1 if (r + g + b) < 384 else 0
                        for r, g, b in zip(row[0::3], row[1::3], row[2::3])
                    )
                )
    else:
        return None
    return matrix


def _finder_bit(r: int, c: int) -> int:
    """Expected light-theme value of top-left finder cell (r, c), 0..6."""
    on_ring = r in (0, 6) or c in (0, 6)
    in_core = 2 <= r <= 4 and 2 <= c <= 4
    return 1 if (on_ring or in_core) else 0


def grid_is_dark(grid: list[bytearray]) -> bool:
    """Polarity auto-detect: compare the top-left 7x7 finder against the
    expected light pattern; True when the inverted pattern matches
    better (a dark-theme page). A real finder matches 49/49 one way and
    0/49 the other, so the halfway threshold has a wide margin."""
    matches_light = 0
    for r in range(7):
        row = grid[r]
        for c in range(7):
            if row[c] == _finder_bit(r, c):
                matches_light += 1
    return matches_light < 25


def _invert_matrix(matrix: list[bytearray]) -> list[bytearray]:
    return [bytearray(bytes(row).translate(_FLIP_01_TABLE)) for row in matrix]


def _is_frame(blob: bytes) -> bool:
    """True when [blob] parses as a Middle Out frame (magic + header CRC).
    The cover manifest grid parses to text and fails here, so it is
    skipped rather than treated as a frame."""
    # Pre-filter on the SMALLEST header (v1, 97 bytes): a v1 frame with
    # an empty payload is only 101 bytes, and the real validation happens
    # in Frame.from_bytes below.
    if len(blob) < HEADER_SIZE_V1 + 4:
        return False
    if blob[:4] != MAGIC:
        return False
    try:
        Frame.from_bytes(blob)
    except CorruptFrameError:
        return False
    return True


def _parse_grid_blob(grid: list[bytearray]) -> bytes | None:
    try:
        blob = parse_grid(grid)
    except CodecError:
        return None
    return blob if _is_frame(blob) else None


def _parse_barcode_blob(rows: list[bytearray]) -> bytes | None:
    try:
        blob = parse_barcode_rows(rows)
    except CodecError:
        return None
    return blob if _is_frame(blob) else None


def _try_parse_grid_matrix(grid: list[bytearray]) -> bytes | None:
    """Polarity-detect (finder) then parse; falls back to the opposite
    polarity. Returns the blob only when it is a valid frame."""
    if len(grid) < 7 or len(grid[0]) < 7:
        return None
    inverted = _invert_matrix(grid)
    candidates = (inverted, grid) if grid_is_dark(grid) else (grid, inverted)
    for candidate in candidates:
        blob = _parse_grid_blob(candidate)
        if blob is not None:
            return blob
    return None


def _try_parse_barcode_matrix(
    matrix: list[bytearray], bar_px: int, row_count: int
) -> bytes | None:
    """Sample stacked barcode rows out of a pixel matrix and parse them.
    Polarity comes from the guard bars (black on a light page), with the
    opposite polarity as a fallback."""
    row_stride = BARCODE_ROW_PX + BARCODE_GAP_PX
    rows: list[bytearray] = []
    for r in range(row_count):
        y = r * row_stride + BARCODE_ROW_PX // 2
        src = matrix[y]
        row = bytearray(BARCODE_ROW_BARS)
        for b in range(BARCODE_ROW_BARS):
            row[b] = src[b * bar_px + bar_px // 2]
        rows.append(row)
    dark = list(rows[0][:4]) == [0, 0, 0, 0]
    inverted = [bytearray(bytes(row).translate(_FLIP_01_TABLE)) for row in rows]
    candidates = (inverted, rows) if dark else (rows, inverted)
    for candidate in candidates:
        blob = _parse_barcode_blob(candidate)
        if blob is not None:
            return blob
    return None


def _near_aspect(aspect: float, target: float) -> bool:
    """True when [aspect] is within 0.05 of [target]. Grid aspects land
    within 0.5/h (<= 0.016 for h >= 32) of their nominal value, while
    the formats sit 0.4+ apart, so 0.05 separates them cleanly."""
    return abs(aspect - target) < 0.05


def _try_parse_code(matrix: list[bytearray], width: int, height: int) -> bytes | None:
    """Try to parse a pixel matrix as a Middle Out grid or barcode.
    Returns the frame blob only when it parses as a valid frame.
    Branches on the image aspect; each branch falls through to the next
    on a parse failure, so a misclassified image only costs a failed
    parse attempt, never a wrong frame."""
    # 1. Stacked-row barcode (old format): exact structural match on the
    # row width and band pitch. Runs first because a bar-grid can share
    # the aspect of a short stacked barcode by coincidence; the
    # guard-bar check rejects non-barcodes below.
    for bar_px in (BARCODE_BAR_PX, 1):
        row_stride = BARCODE_ROW_PX + BARCODE_GAP_PX
        if width == BARCODE_ROW_BARS * bar_px and height % row_stride == 0:
            row_count = height // row_stride
            if row_count >= 1:
                blob = _try_parse_barcode_matrix(matrix, bar_px, row_count)
                if blob is not None:
                    return blob
    # 2. Bar-grid (new barcode): aspect ~5.657, no quiet zone.
    if _near_aspect(width / height, BARCODE_ASPECT):
        blob = _try_parse_grid_matrix(matrix)
        if blob is not None:
            return blob
    # 3. Rectangular QR grid (new format): aspect ~1.414, no quiet zone.
    if _near_aspect(width / height, QR_ASPECT):
        blob = _try_parse_grid_matrix(matrix)
        if blob is not None:
            return blob
    # 4. Square grid (old format / cover manifest): quiet zone of
    # 4 modules (fall back to 0).
    if width == height:
        for quiet in (GRID_QUIET_MODULES, 0):
            n = width - 2 * quiet
            if n < GRID_MIN_HEIGHT:
                continue
            grid = [
                bytearray(row[quiet : quiet + n])
                for row in matrix[quiet : quiet + n]
            ]
            blob = _try_parse_grid_matrix(grid)
            if blob is not None:
                return blob
    return None


def extract_pdf_frames(pdf_bytes: bytes) -> PdfExtraction:
    """Recover Middle Out frame blobs from an encoded PDF's image XObjects.
    New-format PDFs carry 1-bit code images plus one RGB logo tile;
    prefer the 1-bit images and never try to parse the logo. Old-format
    PDFs have only 8-bit RGB code images (no 1-bit image exists), so
    when no 1-bit image is present every image is attempted. Only blobs
    that parse as valid frames are kept (deduplicated)."""
    images = _find_images(pdf_bytes)
    has_one_bit = any(
        image.bits_per_component == 1 and image.colors == 1 for image in images
    )
    candidates = (
        [i for i in images if i.bits_per_component == 1 and i.colors == 1]
        if has_one_bit
        else images
    )
    frames: list[bytes] = []
    seen: set[str] = set()
    parsed = 0
    for image in candidates:
        matrix = _decode_image(image)
        if matrix is None:
            continue
        parsed += 1
        blob = _try_parse_code(matrix, image.width, image.height)
        if blob is None:
            continue
        key = f"{len(blob)}-{blob[:16].hex()}"
        if key not in seen:
            seen.add(key)
            frames.append(blob)
    return PdfExtraction(frames=frames, images_found=len(images), images_parsed=parsed)


def decode_pdf(pdf_path: str, passphrase: str | None = None) -> bytes:
    """Full loop: PDF -> frame images -> frames -> original bytes.
    Light/dark and QR/barcode are auto-detected per page; old-format
    PDFs (square grids, stacked-row barcodes, 8-bit RGB XObjects)
    decode too."""
    with open(pdf_path, "rb") as fh:
        pdf_bytes = fh.read()
    extraction = extract_pdf_frames(pdf_bytes)
    if not extraction.frames:
        raise CodecError("no Middle Out frames found in PDF")
    return decode(extraction.frames, passphrase)


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
        dark = False
        frames_dir = None
        i = 4
        while i < len(argv):
            if argv[i] == "--passphrase":
                passphrase = argv[i + 1]
                i += 2
            elif argv[i] == "--barcode":
                barcode = True
                i += 1
            elif argv[i] == "--dark":
                dark = True
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
        pdf_stats = build_pdf(result, os.path.basename(src), pdf_path, dark=dark)
        theme = "dark" if dark else "light"
        print(f"encoded {len(data):,} bytes -> {result.stats.frame_count} frames "
              f"({result.stats.ratio:.1f}x) -> {pdf_path} "
              f"({pdf_stats.pages} pages, {pdf_stats.size_bytes:,} bytes, {theme})")
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
