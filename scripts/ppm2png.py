#!/usr/bin/env python3
"""Convert QEMU's screendump output (binary PPM) to PNG, stdlib only.

QEMU writes P6 PPM from the monitor's `screendump` command. Nothing on this build host
reads PPM, and installing an imaging stack to look at one screenshot is not a trade
worth making, so this reuses the same thirty-line PNG writer as make-splash.py.
"""

import struct
import sys
import zlib


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def read_ppm(path: str):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a binary PPM (P6)")
    # Header is whitespace-separated tokens, and comment lines may appear between them.
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while i < len(data) and data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1                                  # single whitespace byte before the payload
    w, h, _maxval = fields
    return w, h, data[i:i + w * h * 3]


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: ppm2png.py <in.ppm> <out.png>", file=sys.stderr)
        return 2
    w, h, pix = read_ppm(sys.argv[1])

    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pix[y * w * 3:(y + 1) * w * 3]

    png = (b"\x89PNG\r\n\x1a\n"
           + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + _chunk(b"IEND", b""))
    with open(sys.argv[2], "wb") as fh:
        fh.write(png)

    # A blank screen is the expected failure here (gfxterm loaded but no font, or the
    # theme failed to parse), and it is indistinguishable from success unless measured.
    uniq = len({pix[k:k + 3] for k in range(0, len(pix), 3 * 97)})
    print(f"wrote {sys.argv[2]} ({w}x{h}, ~{uniq} distinct colours sampled)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
