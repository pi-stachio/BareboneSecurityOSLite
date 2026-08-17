"""QR Code encoder -- byte mode, versions 1-10, error correction levels L and M.

Why this exists at all, rather than a dependency:

This module is in the console login path. If it fails to import, nobody can log in.
libqrencode would be a fine library, but making the ability to log in depend on a
package being installed and its shared library resolving is a bad trade for ~350
lines of pure stdlib. Nothing here imports anything.

Scope is deliberately narrow. Byte mode only (we encode URLs and otpauth: URIs, not
kanji), versions 1-10 (a version-10 code is 57 modules across, already far wider than
a console can draw), and EC levels L and M. Q and H would only add table rows, and
every added row is another chance to typo a number that produces a code which looks
perfectly fine and does not scan.

Correctness is not taken on faith: test-qr.py diffs every matrix this produces against
segno, over both EC levels, all ten versions and several thousand random payloads. The
structure below follows Nayuki's reference implementation closely, because agreeing
with a known-correct implementation is worth more than clever code here.
"""

# ---------------------------------------------------------------------------
# GF(256) arithmetic for Reed-Solomon, primitive polynomial 0x11D, generator 2.
# ---------------------------------------------------------------------------

_EXP = [0] * 512
_LOG = [0] * 256

def _init_gf():
    x = 1
    for i in range(255):
        _EXP[i] = x
        _LOG[x] = i
        x <<= 1
        if x & 0x100:          # overflowed 8 bits, reduce by the field polynomial
            x ^= 0x11D
    # Duplicated tail so _LOG[a] + _LOG[b] (max 508) can index without a modulo.
    for i in range(255, 512):
        _EXP[i] = _EXP[i - 255]

_init_gf()


def _gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(degree):
    """Generator polynomial (x-a^0)(x-a^1)...(x-a^(degree-1)), highest term first."""
    poly = [1]
    for i in range(degree):
        nxt = [0] * (len(poly) + 1)
        for j, c in enumerate(poly):
            nxt[j] ^= c                          # multiply by x
            nxt[j + 1] ^= _gf_mul(c, _EXP[i])    # multiply by a^i
        poly = nxt
    return poly


def _rs_remainder(data, ec_len):
    """The ec_len error-correction codewords for one block of data codewords."""
    gen = _rs_generator(ec_len)
    rem = [0] * ec_len
    for byte in data:
        factor = byte ^ rem[0]
        del rem[0]
        rem.append(0)
        if factor:
            lf = _LOG[factor]
            # gen[0] is always 1 and corresponds to the term shifted out above.
            for i in range(ec_len):
                g = gen[i + 1]
                if g:
                    rem[i] ^= _EXP[_LOG[g] + lf]
    return rem


# ---------------------------------------------------------------------------
# Version tables.
#
# _BLOCKS[version][level] = (ec_per_block, blocks1, data1, blocks2, data2)
#
# A block structure with two groups means the data codewords do not divide evenly
# among the blocks; the second group's blocks each hold one more codeword. Every
# row below satisfies blocks1*(data1+ec) + blocks2*(data2+ec) == _TOTAL[version],
# which _self_check() asserts at import time -- a mistyped table entry produces a
# code that is structurally plausible and simply will not scan, so it is worth the
# few microseconds to catch it here instead.
# ---------------------------------------------------------------------------

_TOTAL = {1: 26, 2: 44, 3: 70, 4: 100, 5: 134, 6: 172, 7: 196, 8: 242, 9: 292, 10: 346}

_BLOCKS = {
    1:  {"L": (7, 1, 19, 0, 0),    "M": (10, 1, 16, 0, 0)},
    2:  {"L": (10, 1, 34, 0, 0),   "M": (16, 1, 28, 0, 0)},
    3:  {"L": (15, 1, 55, 0, 0),   "M": (26, 1, 44, 0, 0)},
    4:  {"L": (20, 1, 80, 0, 0),   "M": (18, 2, 32, 0, 0)},
    5:  {"L": (26, 1, 108, 0, 0),  "M": (24, 2, 43, 0, 0)},
    6:  {"L": (18, 2, 68, 0, 0),   "M": (16, 4, 27, 0, 0)},
    7:  {"L": (20, 2, 78, 0, 0),   "M": (18, 4, 31, 0, 0)},
    8:  {"L": (24, 2, 97, 0, 0),   "M": (22, 2, 38, 2, 39)},
    9:  {"L": (30, 2, 116, 0, 0),  "M": (22, 3, 36, 2, 37)},
    10: {"L": (18, 2, 68, 2, 69),  "M": (26, 4, 43, 1, 44)},
}

# Row/column centres of the alignment patterns, per version.
_ALIGN = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30],
    6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
}

# Two bits identifying the EC level inside the format information.
_ECL_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}

MAX_VERSION = 10


def _self_check():
    for ver, levels in _BLOCKS.items():
        for lvl, (ec, b1, d1, b2, d2) in levels.items():
            got = b1 * (d1 + ec) + b2 * (d2 + ec)
            if got != _TOTAL[ver]:
                raise AssertionError(
                    "QR block table wrong for version %d level %s: %d != %d"
                    % (ver, lvl, got, _TOTAL[ver]))

_self_check()


def _data_capacity_bits(version, level):
    ec, b1, d1, b2, d2 = _BLOCKS[version][level]
    return (b1 * d1 + b2 * d2) * 8


def _header_bits(version):
    # 4-bit mode indicator plus the character count field, which widens at version 10.
    return 4 + (8 if version <= 9 else 16)


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

class QRError(Exception):
    pass


def _choose_version(nbytes, level, min_version=1):
    for ver in range(min_version, MAX_VERSION + 1):
        if _header_bits(ver) + nbytes * 8 <= _data_capacity_bits(ver, level):
            return ver
    raise QRError("%d bytes does not fit in a version %d code at level %s"
                  % (nbytes, MAX_VERSION, level))


def _bitstream(data, version, level):
    """Mode indicator, length, payload, terminator, padding -- as a list of bits."""
    bits = []

    def put(value, width):
        for i in range(width - 1, -1, -1):
            bits.append((value >> i) & 1)

    put(0b0100, 4)                                    # byte mode
    put(len(data), 8 if version <= 9 else 16)
    for byte in data:
        put(byte, 8)

    capacity = _data_capacity_bits(version, level)
    # Terminator: up to four zero bits, truncated if the code is nearly full.
    put(0, min(4, capacity - len(bits)))
    # Pad to a codeword boundary, then alternate the two specified pad bytes.
    if len(bits) % 8:
        put(0, 8 - len(bits) % 8)
    for i in range((capacity - len(bits)) // 8):
        put(0xEC if i % 2 == 0 else 0x11, 8)
    return bits


def _codewords(data, version, level):
    """Data and EC codewords, split into blocks and interleaved as the spec requires."""
    bits = _bitstream(data, version, level)
    raw = bytes(int("".join(str(b) for b in bits[i:i + 8]), 2)
                for i in range(0, len(bits), 8))

    ec_len, b1, d1, b2, d2 = _BLOCKS[version][level]
    blocks = []
    pos = 0
    for count, size in ((b1, d1), (b2, d2)):
        for _ in range(count):
            chunk = raw[pos:pos + size]
            pos += size
            blocks.append((list(chunk), _rs_remainder(chunk, ec_len)))

    out = []
    # Data codewords first, taking the i'th from every block in turn. Short blocks
    # simply have nothing to contribute in the final round.
    for i in range(max(len(d) for d, _ in blocks)):
        for d, _ in blocks:
            if i < len(d):
                out.append(d[i])
    for i in range(ec_len):
        for _, e in blocks:
            out.append(e[i])
    return out


# ---------------------------------------------------------------------------
# Module placement
# ---------------------------------------------------------------------------

class _Canvas:
    def __init__(self, version):
        self.version = version
        self.size = version * 4 + 17
        self.mod = [[0] * self.size for _ in range(self.size)]
        # Function modules are everything that is not data: finders, timing,
        # alignment, format and version areas. Data placement skips them and the
        # mask must not touch them.
        self.fixed = [[False] * self.size for _ in range(self.size)]

    def set_fn(self, row, col, dark):
        self.mod[row][col] = 1 if dark else 0
        self.fixed[row][col] = True

    def draw_function_patterns(self):
        n = self.size
        for i in range(n):
            self.set_fn(6, i, i % 2 == 0)
            self.set_fn(i, 6, i % 2 == 0)

        for cy, cx in ((3, 3), (3, n - 4), (n - 4, 3)):
            self._finder(cy, cx)

        pos = _ALIGN[self.version]
        last = len(pos) - 1
        for i, ry in enumerate(pos):
            for j, cx in enumerate(pos):
                # The three corners are occupied by finder patterns.
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue
                self._alignment(ry, cx)

        # Reserve the format and version areas by drawing them with placeholder
        # values; the real format bits go in after masking.
        self._draw_format(0)
        if self.version >= 7:
            self._draw_version()

    def _finder(self, cy, cx):
        # Radius 4 covers the 7x7 pattern plus its light separator, so both get
        # marked as function modules in one pass.
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                y, x = cy + dy, cx + dx
                if 0 <= y < self.size and 0 <= x < self.size:
                    d = max(abs(dy), abs(dx))
                    self.set_fn(y, x, d != 2 and d != 4)

    def _alignment(self, cy, cx):
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                self.set_fn(cy + dy, cx + dx, max(abs(dy), abs(dx)) != 1)

    def _draw_format(self, mask, level="M"):
        data = (_ECL_BITS[level] << 3) | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = ((data << 10) | (rem & 0x3FF)) ^ 0x5412

        # The 15-bit format string is placed most-significant bit first: the published
        # value for level L with mask 0 is 111011111000100, and its leading 1 goes at
        # (8,0). Placing it the other way round yields a code whose data region is
        # perfectly correct and whose format field is a valid-looking format field for
        # some other level and mask, so scanners read the wrong EC level and give up.
        def bit(i):
            return (bits >> (14 - i)) & 1

        n = self.size
        for i in range(6):
            self.set_fn(8, i, bit(i))
        self.set_fn(8, 7, bit(6))
        self.set_fn(8, 8, bit(7))
        self.set_fn(7, 8, bit(8))
        for i in range(9, 15):
            self.set_fn(14 - i, 8, bit(i))

        # The second copy splits 7 modules up the left column and 8 along the top row.
        # Not 8 and 7: the eighth cell of the column, (n-8, 8), is the always-dark
        # module. Splitting it the other way puts format bit 7 under the dark module,
        # which overwrites it, and leaves (8, n-8) unclaimed -- giving 209 data modules
        # in a version 1 code that has exactly 208. Everything downstream then drifts
        # by one bit from that point on, and the result is a perfectly plausible
        # looking code that no scanner can read.
        for i in range(7):
            self.set_fn(n - 1 - i, 8, bit(i))
        for i in range(7, 15):
            self.set_fn(8, n - 15 + i, bit(i))
        self.set_fn(n - 8, 8, True)          # the always-dark module

    def _draw_version(self):
        rem = self.version
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        bits = (self.version << 12) | (rem & 0xFFF)
        for i in range(18):
            b = (bits >> i) & 1
            a = self.size - 11 + i % 3
            c = i // 3
            self.set_fn(a, c, b)
            self.set_fn(c, a, b)

    def place_data(self, codewords):
        bits = [(cw >> i) & 1 for cw in codewords for i in range(7, -1, -1)]
        i = 0
        col = self.size - 1
        upward = True
        while col > 0:
            if col == 6:      # the vertical timing pattern is not a data column
                col -= 1
            rows = range(self.size - 1, -1, -1) if upward else range(self.size)
            for row in rows:
                for c in (col, col - 1):
                    if not self.fixed[row][c]:
                        # Remaining modules stay light if the bitstream runs out,
                        # which happens for the few versions with spare bits.
                        self.mod[row][c] = bits[i] if i < len(bits) else 0
                        i += 1
            upward = not upward
            col -= 2

    def apply_mask(self, mask):
        cond = _MASKS[mask]
        for r in range(self.size):
            for c in range(self.size):
                if not self.fixed[r][c] and cond(r, c):
                    self.mod[r][c] ^= 1

    def penalty(self):
        n, m = self.size, self.mod
        score = 0

        # Rule 1: runs of five or more same-coloured modules in a line.
        for major in range(n):
            for line in (m[major], [m[r][major] for r in range(n)]):
                run, prev = 1, line[0]
                for v in line[1:]:
                    if v == prev:
                        run += 1
                    else:
                        if run >= 5:
                            score += 3 + (run - 5)
                        run, prev = 1, v
                if run >= 5:
                    score += 3 + (run - 5)

        # Rule 2: 2x2 blocks of one colour.
        for r in range(n - 1):
            for c in range(n - 1):
                v = m[r][c]
                if v == m[r][c + 1] == m[r + 1][c] == m[r + 1][c + 1]:
                    score += 3

        # Rule 3: the finder-lookalike 1:1:3:1:1 pattern with four light modules
        # on either side, which is what confuses a scanner into misreading position.
        a = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0]
        b = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1]
        for major in range(n):
            for line in (m[major], [m[r][major] for r in range(n)]):
                for i in range(n - 10):
                    window = line[i:i + 11]
                    if window == a or window == b:
                        score += 40

        # Rule 4: deviation from an even balance of dark and light.
        dark = sum(sum(row) for row in m)
        pct = dark * 100 // (n * n)
        score += 10 * (abs(pct - 50) // 5)
        return score


_MASKS = [
    lambda r, c: (r + c) % 2 == 0,
    lambda r, c: r % 2 == 0,
    lambda r, c: c % 3 == 0,
    lambda r, c: (r + c) % 3 == 0,
    lambda r, c: (r // 2 + c // 3) % 2 == 0,
    lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
    lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
]


def encode(text, level="M", min_version=1):
    """Encode text and return (matrix, version) where matrix[row][col] is 0 or 1.

    The matrix has no quiet zone; renderers add it.
    """
    if level not in ("L", "M"):
        raise QRError("only levels L and M are supported, not %r" % (level,))
    data = text.encode("utf-8") if isinstance(text, str) else bytes(text)
    version = _choose_version(len(data), level, min_version)
    words = _codewords(data, version, level)

    best = None
    for mask in range(8):
        canvas = _Canvas(version)
        canvas.draw_function_patterns()
        canvas.place_data(words)
        canvas.apply_mask(mask)
        canvas._draw_format(mask, level)
        p = canvas.penalty()
        if best is None or p < best[0]:
            best = (p, canvas)
    return best[1].mod, version


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# A QR code has to be drawn dark-on-light regardless of the terminal's colours, so
# every module gets an explicit colour. Black and bright white, for the most contrast
# a text console can offer.
_BLACK_FG, _WHITE_FG, _BLACK_BG, _WHITE_BG = "30", "97", "40", "107"


def to_halfblocks(matrix, quiet=4):
    """Render as lines of U+2580 half blocks: one column and half a row per module.

    Two modules are stacked into each character cell. That is the only way a code
    large enough to scan fits an 80x25 console -- one cell per module would need
    twice the rows, and console cells are about twice as tall as they are wide, so
    stacking also happens to make the modules square, which scanners require.
    """
    n = len(matrix)
    grid = [[0] * (n + 2 * quiet) for _ in range(quiet)]
    for row in matrix:
        grid.append([0] * quiet + list(row) + [0] * quiet)
    grid.extend([[0] * (n + 2 * quiet) for _ in range(quiet)])
    if len(grid) % 2:
        grid.append([0] * (n + 2 * quiet))

    lines = []
    for top in range(0, len(grid), 2):
        upper, lower = grid[top], grid[top + 1]
        out = []
        last = None
        for c in range(len(upper)):
            fg = _BLACK_FG if upper[c] else _WHITE_FG
            bg = _BLACK_BG if lower[c] else _WHITE_BG
            if (fg, bg) != last:
                out.append("\033[%s;%sm" % (fg, bg))
                last = (fg, bg)
            out.append("▀")
        out.append("\033[0m")
        lines.append("".join(out))
    return lines


def to_ascii(matrix, quiet=2, dark="##", light="  "):
    """Render with two characters per module and no colour or Unicode at all.

    Twice as tall as the half-block form, so it does not fit a login screen, but it
    survives a console with no block glyphs and can be scrolled through.
    """
    n = len(matrix)
    pad = light * (n + 2 * quiet)
    lines = [pad] * quiet
    for row in matrix:
        lines.append(light * quiet + "".join(dark if v else light for v in row)
                     + light * quiet)
    lines.extend([pad] * quiet)
    return lines


def width_halfblocks(matrix, quiet=4):
    return len(matrix) + 2 * quiet


def height_halfblocks(matrix, quiet=4):
    return (len(matrix) + 2 * quiet + 1) // 2


if __name__ == "__main__":
    import sys
    text = sys.argv[1] if len(sys.argv) > 1 else "https://example.com"
    m, v = encode(text)
    print("version %d, %dx%d modules" % (v, len(m), len(m)))
    for line in to_halfblocks(m):
        print(line)
