#!/usr/bin/env python3
"""Tests for bastion_qr.py, checked against libqrencode and segno.

Runs on the BUILD HOST, never on the target -- these are oracles, not dependencies.
The target implementation is stdlib-only and this is how we know it works.

  apt-get install qrencode python3-segno
  python3 scripts/qrauth/test-qr.py

A hand-written QR encoder fails in one specific, nasty way: the output looks exactly
like a QR code and simply does not scan. Nothing short of comparing against real
implementations catches that, so there are four checks here.

1. Structural invariants -- data module counts per version, every Reed-Solomon block a
   valid codeword, spec-conformant padding. No oracle needed, and this is what catches
   a misplaced function pattern.

2. Format information against segno, for all sixteen level/mask combinations. segno can
   be told which mask to use, which makes it the right oracle for this field.

3. Decoding qrencode's matrices with our own machinery. This is the strongest check:
   read the format info to recover qrencode's mask and EC level, unmask, walk the
   zigzag, de-interleave the blocks, verify the Reed-Solomon syndromes and recover the
   payload. It only succeeds if our layout, mask patterns, format placement, block
   structure and Galois field are all identical to qrencode's, and unlike comparing
   matrices directly it does not care which mask was chosen.

4. Our own matrices, decoded the same way, and compared byte-for-byte with qrencode
   whenever the two implementations happened to pick the same mask.

Why mask choice is allowed to differ: the mask is recorded in the format information,
so a reader applies whichever one was used. A suboptimal choice is a cosmetic matter,
not a correctness one. libqrencode's penalty scoring is known to deviate slightly from
ISO/IEC 18004 in how it fuses rules 1 and 3 while scanning runs, so demanding
agreement would mean copying its deviation.

Why segno is not the oracle for whole matrices: segno's write_padding_bits does

    buff.extend([0] * (8 - (length % 8)))

which appends a whole spurious zero byte when the stream is already on a codeword
boundary. In byte mode it always is -- 4 mode bits + 8 count bits + 8n data bits + 4
terminator bits is a multiple of 8 -- so segno emits a stray 0x00 codeword on every
byte-mode symbol, where ISO/IEC 18004 7.4.10 makes that padding conditional ("If the
bit stream length is such that it does not end at a codeword boundary"). It is
harmless, landing after the terminator where decoders stop reading, which is why it
has survived; but it means segno and a conformant encoder never agree byte-for-byte.
"""
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bastion_qr as B  # noqa: E402

ALPHABET = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            ":/?&=.-_%+~@#!$*,;()[]{}<>|^ ")

# Modules in the encoding region that no codeword reaches. They are left light and then
# masked like any other module. Versions 2-6 have seven; without accounting for them the
# module-count check looks like a placement bug when it is not.
_REMAINDER_BITS = {1: 0, 2: 7, 3: 7, 4: 7, 5: 7, 6: 7, 7: 0, 8: 0, 9: 0, 10: 0}

_BITS_TO_ECL = {1: "L", 0: "M", 3: "Q", 2: "H"}


def qrencode_matrix(payload, version, level):
    out = subprocess.run(
        ["qrencode", "-t", "ASCII", "-m", "0", "-8",
         "-v", str(version), "-l", level, "-o", "-", "--", payload],
        capture_output=True, check=True).stdout.decode()
    rows = [ln for ln in out.split("\n") if ln]
    # Two characters per module in ASCII output; '#' is dark.
    return [[1 if ln[2 * c] == "#" else 0 for c in range(len(ln) // 2)] for ln in rows]


# ---------------------------------------------------------------------------
# A decoder, built only from the layout bastion_qr claims is correct.
# ---------------------------------------------------------------------------

class DecodeError(Exception):
    pass


def decode(matrix):
    """Recover (text, version, level, mask) from a module matrix."""
    size = len(matrix)
    if (size - 17) % 4:
        raise DecodeError("size %d is not a valid QR symbol size" % size)
    version = (size - 17) // 4
    if not 1 <= version <= B.MAX_VERSION:
        raise DecodeError("version %d out of range" % version)

    canvas = B._Canvas(version)
    canvas.draw_function_patterns()

    # Format information, copy 1, most significant bit first.
    positions = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                 (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
    raw = 0
    for r, c in positions:
        raw = (raw << 1) | matrix[r][c]
    fmt = raw ^ 0x5412
    # Verify the BCH remainder rather than trusting it; a wrong format field is exactly
    # the failure this test exists to catch.
    data = fmt >> 10
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    if (rem & 0x3FF) != (fmt & 0x3FF):
        raise DecodeError("format information BCH check failed")
    level = _BITS_TO_ECL[data >> 3]
    mask = data & 7
    if level not in ("L", "M"):
        raise DecodeError("unsupported level %s" % level)

    # Undo the mask over the encoding region only.
    cond = B._MASKS[mask]
    grid = [row[:] for row in matrix]
    for r in range(size):
        for c in range(size):
            if not canvas.fixed[r][c] and cond(r, c):
                grid[r][c] ^= 1

    # Walk the same zigzag the encoder uses.
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

    expect = B._TOTAL[version] * 8 + _REMAINDER_BITS[version]
    if len(bits) != expect:
        raise DecodeError("read %d encoding-region bits, expected %d"
                          % (len(bits), expect))
    words = [int("".join(str(b) for b in bits[i:i + 8]), 2)
             for i in range(0, B._TOTAL[version] * 8, 8)]

    # De-interleave into blocks.
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
        raise DecodeError("de-interleave consumed %d of %d codewords" % (pos, len(words)))

    # Every block must be a valid Reed-Solomon codeword: zero at each generator root.
    for b in range(nblocks):
        full = data_words[b] + ec_words[b]
        for i in range(ec_len):
            acc = 0
            for coeff in full:
                acc = B._gf_mul(acc, B._EXP[i]) ^ coeff
            if acc != 0:
                raise DecodeError("block %d fails the Reed-Solomon syndrome check" % b)

    # Parse the data stream.
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


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_invariants(failures):
    for ver in range(1, B.MAX_VERSION + 1):
        canvas = B._Canvas(ver)
        canvas.draw_function_patterns()
        free = sum(1 for r in range(canvas.size) for c in range(canvas.size)
                   if not canvas.fixed[r][c])
        want = B._TOTAL[ver] * 8 + _REMAINDER_BITS[ver]
        # An extra or missing data module shifts every bit after it and produces an
        # unscannable code with no other symptom.
        if free != want:
            failures.append("version %d has %d data modules, expected %d"
                            % (ver, free, want))

    for ver in range(1, B.MAX_VERSION + 1):
        for lvl in ("L", "M"):
            cap = B._data_capacity_bits(ver, lvl)
            payload = bytes((i * 7 + 3) & 0xFF
                            for i in range((cap - B._header_bits(ver)) // 8))
            bits = B._bitstream(payload, ver, lvl)
            if len(bits) != cap:
                failures.append("v%d/%s bitstream is %d bits, capacity is %d"
                                % (ver, lvl, len(bits), cap))


def check_padding(failures):
    """ISO/IEC 18004 7.4.9 / 7.4.10, checked directly rather than via an oracle."""
    bits = B._bitstream(b"HELLO", 1, "L")
    words = [int("".join(str(b) for b in bits[i:i + 8]), 2)
             for i in range(0, len(bits), 8)]
    if words[:7] != [0x40, 0x54, 0x84, 0x54, 0xC4, 0xC4, 0xF0]:
        failures.append("header/payload codewords wrong: %r" % (words[:7],))
    if words[7:] != [0xEC, 0x11] * 6:
        failures.append("pad codewords wrong, expected EC/11 alternating: %r"
                        % (words[7:],))
    maxlen = (B._data_capacity_bits(1, "L") - B._header_bits(1)) // 8
    bits = B._bitstream(b"x" * maxlen, 1, "L")
    if len(bits) != B._data_capacity_bits(1, "L"):
        failures.append("full payload produced %d bits, capacity is %d"
                        % (len(bits), B._data_capacity_bits(1, "L")))


def check_format_info(failures):
    """All sixteen level/mask combinations against segno, which can be told its mask."""
    try:
        import segno
    except ImportError:
        print("  (skipping format-info check: python3-segno not installed)")
        return
    positions = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                 (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
    n = 21
    positions += [(n - 1 - i, 8) for i in range(7)] + [(8, n - 15 + i) for i in range(7, 15)]
    for level in ("L", "M"):
        for mask in range(8):
            ref = [list(r) for r in segno.make("FORMAT", version=1, error=level,
                                               mode="byte", boost_error=False,
                                               mask=mask).matrix]
            canvas = B._Canvas(1)
            canvas.draw_function_patterns()
            canvas._draw_format(mask, level)
            got = "".join(str(canvas.mod[r][c]) for r, c in positions)
            want = "".join(str(ref[r][c]) for r, c in positions)
            if got != want:
                failures.append("format info level %s mask %d: %s != %s"
                                % (level, mask, got, want))


def main():
    random.seed(20260817)
    per_cell = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    failures = []
    decoded_theirs = decoded_ours = identical = compared = 0

    check_invariants(failures)
    check_padding(failures)
    check_format_info(failures)

    for level in ("L", "M"):
        for version in range(1, B.MAX_VERSION + 1):
            cap = B._data_capacity_bits(version, level)
            maxlen = (cap - B._header_bits(version)) // 8
            lengths = [1, 2, maxlen - 1, maxlen]
            lengths += [random.randint(1, maxlen) for _ in range(per_cell)]

            for length in lengths:
                if not 1 <= length <= maxlen:
                    continue
                payload = "".join(random.choice(ALPHABET) for _ in range(length))

                mine, got_ver = B.encode(payload, level, min_version=version)
                if got_ver != version:
                    failures.append("v%d/%s len=%d: encoder chose version %d"
                                    % (version, level, length, got_ver))
                    continue

                theirs = qrencode_matrix(payload, version, level)
                if len(theirs) != len(mine):
                    continue        # qrencode grew the symbol; not comparable
                compared += 1

                # Their matrix, read with our machinery.
                try:
                    text, _, lvl, their_mask = decode(theirs)
                    if text != payload or lvl != level:
                        raise DecodeError("recovered %r level %s" % (text, lvl))
                    decoded_theirs += 1
                except DecodeError as exc:
                    failures.append("v%d/%s len=%d: cannot decode qrencode's matrix: %s"
                                    % (version, level, length, exc))
                    continue

                # Our matrix, read the same way.
                try:
                    text, _, lvl, our_mask = decode(mine)
                    if text != payload or lvl != level:
                        raise DecodeError("recovered %r level %s" % (text, lvl))
                    decoded_ours += 1
                except DecodeError as exc:
                    failures.append("v%d/%s len=%d: cannot decode our own matrix: %s"
                                    % (version, level, length, exc))
                    continue

                if our_mask == their_mask:
                    if mine == theirs:
                        identical += 1
                    else:
                        diff = sum(1 for r in range(len(mine))
                                   for c in range(len(mine)) if mine[r][c] != theirs[r][c])
                        failures.append(
                            "v%d/%s len=%d: same mask %d but %d modules differ"
                            % (version, level, length, our_mask, diff))

    # Non-ASCII, exercising the UTF-8 path and a two-byte character count.
    for level in ("L", "M"):
        payload = "wetter: 21C café naïve → über"
        mine, ver = B.encode(payload, level)
        try:
            text, _, _, _ = decode(mine)
            if text != payload:
                failures.append("utf-8 payload decoded as %r" % (text,))
        except DecodeError as exc:
            failures.append("utf-8 payload at level %s: %s" % (level, exc))

    # One byte past the largest supported symbol must raise, not truncate.
    try:
        B.encode("x" * (B._data_capacity_bits(10, "L") // 8), "L")
        failures.append("oversized payload accepted instead of raising QRError")
    except B.QRError:
        pass

    print("compared %d symbols against qrencode" % compared)
    print("  decoded qrencode's matrices with our layout : %d" % decoded_theirs)
    print("  decoded our own matrices                    : %d" % decoded_ours)
    print("  byte-identical where the mask agreed        : %d of %d"
          % (identical, compared))
    for f in failures[:25]:
        print("  FAIL " + f)
    if len(failures) > 25:
        print("  ... and %d more" % (len(failures) - 25))
    if failures:
        print("RESULT: FAIL (%d)" % len(failures))
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
