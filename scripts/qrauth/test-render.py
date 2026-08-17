#!/usr/bin/env python3
"""Check that what the console actually draws is a readable QR code.

  python3 scripts/qrauth/test-render.py

test-qr.py proves the matrix is right. That is not the same as proving the login screen
is right: the matrix still has to survive being turned into half-block characters and
ANSI colours, and a renderer that transposes a row, drops the quiet zone or gets the
foreground and background the wrong way round produces something that looks like a QR
code on screen and cannot be scanned.

So this renders exactly what bastion-qrlogin renders, parses the escape sequences back
into a matrix, and decodes it. It also checks the thing that decides whether any of
this is usable at all: whether the drawing fits in 80x25.

What it cannot check is whether the console font has a glyph for U+2580. That is a
property of the booted machine, not of this code, and the boot test screenshots the
real console for it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bastion_qr  # noqa: E402
import qrdecode  # noqa: E402

COLS, ROWS = 80, 25
# bastion-qrlogin refuses to draw above this, and the login screen needs room for text.
MAX_VERSION = 5

failures = []
checked = 0


def check(cond, what):
    global checked
    checked += 1
    if not cond:
        failures.append(what)


def round_trip(text, level="M"):
    matrix, version = bastion_qr.encode(text, level)
    lines = bastion_qr.to_halfblocks(matrix)
    back = qrdecode.from_halfblocks(lines)
    got, _, _, _ = qrdecode.decode(back)
    return got, version, lines, bastion_qr.width_halfblocks(matrix)


def main():
    # The real payloads, at the longest plausible shapes: a fifteen-character address,
    # and an account name nobody would enjoy typing.
    #
    # The two screens have different budgets. The login screen draws the code one row
    # below a title, so it has ROWS-2 rows for it. Enrolment prints its explanation
    # first and the code last, so it has all ROWS -- which is why the enrolment code,
    # the taller of the two, is the one printed at the bottom.
    login = [
        "http://10.0.2.15:8043/a?0123456789ab",
        "http://192.168.100.100:8043/a?0123456789ab",
    ]
    enrol = [
        "http://192.168.100.100:8043/e#0123456789.MFRGGZDFMZTWQ2LKNNWG23TPOAXXA53P",
        "otpauth://totp/bastion:alice?secret=MFRGGZDFMZTWQ2LKNNWG23TPOAXXA53P",
    ]
    for url, budget, what in ([(u, ROWS - 2, "login") for u in login]
                              + [(u, ROWS, "enrol") for u in enrol]):
        try:
            got, version, lines, width = round_trip(url)
        except Exception as exc:
            failures.append("%r: rendering did not decode: %s" % (url[:50], exc))
            continue
        check(got == url, "%r decoded as %r" % (url[:50], got[:50]))
        height = len(lines)
        check(width <= COLS and height <= budget,
              "%s code for %r is version %d, needs %dx%d, budget is %dx%d"
              % (what, url[:44], version, width, height, COLS, budget))
        if what == "login":
            check(version <= MAX_VERSION,
                  "login code for %r is version %d; bastion-qrlogin refuses above %d"
                  % (url[:44], version, MAX_VERSION))
        print("  %-6s v%-2d %2dx%-2d cells  %s" % (what, version, width, height,
                                                   url[:46]))

    # Every version we might draw must survive the round trip, not just the ones the
    # sample URLs happen to hit.
    for version in range(1, bastion_qr.MAX_VERSION + 1):
        for level in ("L", "M"):
            cap = (bastion_qr._data_capacity_bits(version, level)
                   - bastion_qr._header_bits(version)) // 8
            # Exactly fill the version, so the terminator is truncated and no pad
            # codewords are added -- the awkward case.
            payload = ("v%d%s" % (version, level)).ljust(cap, "x")[:cap]
            matrix, got_ver = bastion_qr.encode(payload, level, min_version=version)
            lines = bastion_qr.to_halfblocks(matrix)
            try:
                back = qrdecode.from_halfblocks(lines)
                got, _, lvl, _ = qrdecode.decode(back)
            except Exception as exc:
                failures.append("v%d/%s: %s" % (version, level, exc))
                continue
            check(got == payload and lvl == level,
                  "v%d/%s round trip lost the payload" % (version, level))

    # A quiet zone must actually be there: without it many scanners will not lock on.
    matrix, _ = bastion_qr.encode("https://example.com", "M")
    lines = bastion_qr.to_halfblocks(matrix, quiet=4)
    back = qrdecode.from_halfblocks(lines, quiet=4)
    check(len(back) == len(matrix), "quiet zone was not four modules on every side")
    check(back == matrix, "the quiet zone strip did not recover the original matrix")

    # The ASCII fallback, for a console with no block glyphs.
    ascii_lines = bastion_qr.to_ascii(matrix, quiet=2)
    check(all(len(l) == (len(matrix) + 4) * 2 for l in ascii_lines),
          "ASCII rendering is not two characters per module")
    check(len(ascii_lines) == len(matrix) + 4,
          "ASCII rendering has the wrong number of rows")

    print("ran %d checks" % checked)
    for f in failures[:20]:
        print("  FAIL " + f)
    if failures:
        print("RESULT: FAIL (%d)" % len(failures))
        return 1
    print("RESULT: PASS -- rendered output decodes back to the payload")
    return 0


if __name__ == "__main__":
    sys.exit(main())
