"""A QR decoder, for tests only. Never installed.

Built only from the layout bastion_qr.py claims is correct, which is what makes it
useful: pointed at libqrencode's output it either reproduces the payload or it does
not, and if it does not, the two implementations disagree about something real.

It does no error correction. It verifies the Reed-Solomon syndromes instead and refuses
anything that does not check out, because for a test "this is exactly right" is the
answer wanted, not "this was close enough to repair".
"""
import bastion_qr as B

# Modules in the encoding region that no codeword reaches. Left light, then masked like
# any other module. Versions 2-6 have seven.
REMAINDER_BITS = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}

_BITS_TO_ECL = {1: "L", 0: "M", 3: "Q", 2: "H"}

# Format information, copy 1, in the order the bits are placed: most significant first.
FORMAT_COPY1 = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]


def format_copy2(size):
    return ([(size - 1 - i, 8) for i in range(7)]
            + [(8, size - 15 + i) for i in range(7, 15)])


class DecodeError(Exception):
    pass


def decode(matrix):
    """Recover (text, version, level, mask) from a module matrix."""
    size = len(matrix)
    if size < 21 or (size - 17) % 4:
        raise DecodeError("size %d is not a valid QR symbol size" % size)
    version = (size - 17) // 4
    if not 1 <= version <= B.MAX_VERSION:
        raise DecodeError("version %d out of range" % version)
    for row in matrix:
        if len(row) != size:
            raise DecodeError("matrix is not square")

    canvas = B._Canvas(version)
    canvas.draw_function_patterns()

    raw = 0
    for r, c in FORMAT_COPY1:
        raw = (raw << 1) | matrix[r][c]
    fmt = raw ^ 0x5412
    data = fmt >> 10
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    if (rem & 0x3FF) != (fmt & 0x3FF):
        raise DecodeError("format information BCH check failed")
    level = _BITS_TO_ECL[data >> 3]
    mask = data & 7
    if level not in ("L", "M"):
        raise DecodeError("level %s is outside what bastion_qr supports" % level)

    cond = B._MASKS[mask]
    grid = [row[:] for row in matrix]
    for r in range(size):
        for c in range(size):
            if not canvas.fixed[r][c] and cond(r, c):
                grid[r][c] ^= 1

    bits = []
    col = size - 1
    upward = True
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(size - 1, -1, -1) if upward else range(size)
        for row in rows:
            for c in (col, col - 1):
                if not canvas.fixed[row][c]:
                    bits.append(grid[row][c])
        upward = not upward
        col -= 2

    expect = B._TOTAL[version] * 8 + REMAINDER_BITS[version]
    if len(bits) != expect:
        raise DecodeError("read %d encoding-region bits, expected %d"
                          % (len(bits), expect))
    words = [int("".join(str(b) for b in bits[i:i + 8]), 2)
             for i in range(0, B._TOTAL[version] * 8, 8)]

    ec_len, b1, d1, b2, d2 = B._BLOCKS[version][level]
    sizes = [d1] * b1 + [d2] * b2
    nblocks = b1 + b2
    data_words = [[] for _ in range(nblocks)]
    pos = 0
    for i in range(max(sizes)):
        for b in range(nblocks):
            if i < sizes[b]:
                data_words[b].append(words[pos])
                pos += 1
    ec_words = [[] for _ in range(nblocks)]
    for i in range(ec_len):
        for b in range(nblocks):
            ec_words[b].append(words[pos])
            pos += 1
    if pos != len(words):
        raise DecodeError("de-interleave consumed %d of %d codewords"
                          % (pos, len(words)))

    for b in range(nblocks):
        full = data_words[b] + ec_words[b]
        for i in range(ec_len):
            acc = 0
            for coeff in full:
                acc = B._gf_mul(acc, B._EXP[i]) ^ coeff
            if acc != 0:
                raise DecodeError("block %d fails the Reed-Solomon syndrome check" % b)

    stream = [bit for w in (w for blk in data_words for w in blk)
              for bit in ((w >> i) & 1 for i in range(7, -1, -1))]

    def take(n):
        if len(stream) < n:
            raise DecodeError("data stream truncated")
        v = 0
        for _ in range(n):
            v = (v << 1) | stream.pop(0)
        return v

    mode = take(4)
    if mode != 0b0100:
        raise DecodeError("expected byte mode, got %s" % bin(mode))
    count = take(8 if version <= 9 else 16)
    payload = bytes(take(8) for _ in range(count))
    return payload.decode("utf-8"), version, level, mask


def from_halfblocks(lines, quiet=4):
    """Turn bastion_qr.to_halfblocks output back into a matrix.

    Reads the SGR colours rather than the character, because the character is the same
    half block everywhere; it is the foreground and background that say whether the
    upper and lower module of each cell are dark. Colours are only emitted when they
    change, so the current pair has to be carried along the line.
    """
    rows = []
    for line in lines:
        upper, lower = [], []
        fg = bg = None
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "\033":
                end = line.find("m", i)
                if end < 0:
                    raise DecodeError("unterminated escape sequence")
                for part in line[i + 2:end].split(";"):
                    if part in ("30", "97"):
                        fg = part
                    elif part in ("40", "107"):
                        bg = part
                    elif part == "0":
                        fg = bg = None
                i = end + 1
                continue
            if ch == "▀":
                if fg is None or bg is None:
                    raise DecodeError("a module was drawn with no colour set")
                upper.append(1 if fg == "30" else 0)
                lower.append(1 if bg == "40" else 0)
                i += 1
                continue
            if ch in ("\n", "\r"):
                i += 1
                continue
            raise DecodeError("unexpected character %r in rendered output" % ch)
        if upper:
            rows.append(upper)
            rows.append(lower)

    if not rows:
        raise DecodeError("no modules found in the rendered output")
    # Strip the quiet zone from all four sides.
    full_width = len(rows[0])
    trimmed = [r[quiet:full_width - quiet] for r in rows[quiet:len(rows) - quiet]]
    # to_halfblocks appends one more light row when the total height is odd, so that
    # every character cell holds two modules. That row survives the bottom trim and
    # has to come off separately, or the matrix ends up one row taller than it is wide.
    width = len(trimmed[0]) if trimmed else 0
    while len(trimmed) > width and not any(trimmed[-1]):
        trimmed.pop()
    return trimmed
