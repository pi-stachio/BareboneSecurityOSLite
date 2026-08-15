#!/usr/bin/env python3
"""Generate the GRUB background image.

Writes a PNG with nothing but the standard library -- no Pillow, no ImageMagick, no
netpbm. A PNG is a zlib-compressed scanline stream wrapped in four chunks, which is
about thirty lines of code, and that is a far smaller dependency than adding an imaging
stack to a system whose whole point is that every binary was built deliberately.

The image is background only. Text is drawn by GRUB itself from a .pf2 font, so the
wording can change without regenerating anything, and it stays crisp at any resolution.
"""

import struct
import sys
import zlib


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path: str, width: int, height: int, pixel) -> None:
    raw = bytearray()
    for y in range(height):
        raw.append(0)                      # filter type 0 (None) for this scanline
        for x in range(width):
            raw += bytes(pixel(x, y))
    png = (b"\x89PNG\r\n\x1a\n"
           + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + png_chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "background.png"
    W, H = 1024, 768

    # Dark vertical gradient with a subtle diagonal sheen, and a horizontal rule where
    # the theme places the title. Deliberately low contrast: the menu text sits on top
    # of it and has to stay readable.
    top = (14, 18, 24)
    bottom = (26, 34, 46)
    accent = (94, 168, 190)

    def pixel(x, y):
        t = y / (H - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)

        # Faint diagonal banding, a few units either way.
        sheen = ((x + y) % 160) / 160.0
        d = int(4 * (sheen - 0.5))
        r, g, b = r + d, g + d, b + d

        # A thin accent rule under the title area, and a matching one near the bottom.
        if 150 <= y <= 152 or H - 90 <= y <= H - 88:
            edge = min(x, W - x) / 220.0          # fade the rule out at both ends
            k = max(0.0, min(1.0, edge))
            r = int(r + (accent[0] - r) * k)
            g = int(g + (accent[1] - g) * k)
            b = int(b + (accent[2] - b) * k)

        return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))

    write_png(out, W, H, pixel)
    print(f"wrote {out} ({W}x{H})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
