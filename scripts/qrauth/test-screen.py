#!/usr/bin/env python3
"""Decode a QR code out of a screenshot of the real console.

  python3 scripts/qrauth/test-screen.py shot.ppm <qr_cell_col> <qr_cell_row> <cells_wide>

test-render.py proves the escape sequences we emit describe the right code. This proves
the pixels a VGA text console actually paints out of them still are one, which is a
different question, because the console does not draw what a naive reading of "half
block" suggests:

  the character cell is 9x16 pixels, not 8x16 -- VGA's 9-dot text clock;
  the U+2580 glyph fills 7 rows with the foreground and 9 with the background,
      so stacked module rows alternate 7 and 9 pixels tall;
  the ninth column takes the BACKGROUND colour, so a dark module gets a one-pixel
      seam on its right whose colour comes from the module below it;
  the console has no bright backgrounds, so SGR 107 comes out as 168,168,168 while
      SGR 97 comes out as 255,255,255 -- two different "light" levels.

None of that is visible in the escape sequences, and all of it is visible to a camera.
So the modules are sampled where a scanner would sample them -- at the centre, away
from the seam -- and the result is run through the same strict decoder used elsewhere,
which does no error correction. If it reads here, a phone has margin to spare.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qrdecode  # noqa: E402

CELL_W, CELL_H = 9, 16
# Row offsets to sample the upper and lower module of a cell. The glyph splits 7/9, so
# the midpoints are not 4 and 12.
UPPER_Y, LOWER_Y = 3, 11
SAMPLE_X = 4              # centre of the 8-pixel glyph, clear of the ninth-column seam
QUIET = 4


def read_ppm(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise SystemExit("%s: not a binary PPM" % path)
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
    i += 1
    w, h, _ = fields
    return w, h, data[i:i + w * h * 3]


def sample(w, h, data, col0, row0, wide):
    def lum(x, y):
        i = (y * w + x) * 3
        return (data[i] * 299 + data[i + 1] * 587 + data[i + 2] * 114) // 1000

    grid = []
    for line in range((wide + 1) // 2):
        cy = (row0 + line) * CELL_H
        upper, lower = [], []
        for c in range(wide):
            cx = (col0 + c) * CELL_W + SAMPLE_X
            if cx >= w or cy + LOWER_Y >= h:
                return None
            upper.append(1 if lum(cx, cy + UPPER_Y) < 110 else 0)
            lower.append(1 if lum(cx, cy + LOWER_Y) < 110 else 0)
        grid.append(upper)
        grid.append(lower)

    # Strip the quiet zone and any padding row, exactly as from_halfblocks does.
    trimmed = [r[QUIET:wide - QUIET] for r in grid[QUIET:len(grid) - QUIET]]
    if not trimmed or not trimmed[0]:
        return None
    width = len(trimmed[0])
    while len(trimmed) > width and not any(trimmed[-1]):
        trimmed.pop()
    return trimmed


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: test-screen.py <shot.ppm> [cell_col cell_row cells_wide]")
    path = sys.argv[1]
    w, h, data = read_ppm(path)
    cols = w // CELL_W
    print("screenshot %dx%d = %d columns of %dx%d cells" % (w, h, cols, CELL_W, CELL_H))

    if len(sys.argv) >= 5:
        attempts = [tuple(int(x) for x in sys.argv[2:5])]
    else:
        # bastion-qrlogin draws the code flush to the right, one row below the title,
        # so only its width is unknown -- and that is fixed by the QR version. Try each
        # version rather than making the caller work out which address length produced
        # which symbol.
        attempts = [(cols - wide - 1, 2, wide)
                    for wide in (25, 29, 33, 37, 41, 45, 49)]

    for col0, row0, wide in attempts:
        if col0 < 0:
            continue
        matrix = sample(w, h, data, col0, row0, wide)
        if matrix is None:
            continue
        try:
            text, version, level, mask = qrdecode.decode(matrix)
        except Exception:
            continue
        print("found a %d-cell-wide code at cell (%d,%d)" % (wide, col0, row0))
        print("recovered a %dx%d module matrix" % (len(matrix[0]), len(matrix)))
        print()
        for row in matrix:
            print("  " + "".join("##" if v else "  " for v in row))
        print()
        print("decoded: %r" % text)
        print("version %d, level %s, mask %d" % (version, level, mask))
        print("RESULT: PASS -- the pixels on the console are a readable QR code")
        return 0

    print("RESULT: FAIL -- no readable QR code found on this screen")
    return 1


if __name__ == "__main__":
    sys.exit(main())
