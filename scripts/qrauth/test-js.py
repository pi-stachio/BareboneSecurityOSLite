#!/usr/bin/env python3
"""Check the hand-written SHA-256/HMAC in phone.html against Python's hashlib.

Runs on the BUILD HOST. Needs nodejs, which is a test dependency only -- nothing in
this test ships, and the target has no JavaScript engine.

  apt-get install nodejs
  python3 scripts/qrauth/test-js.py

phone.html has to implement SHA-256 by hand: it is served over plain HTTP on a local
network, which is not a "secure context", so window.crypto.subtle is unavailable. A
subtly wrong SHA-256 would still produce 64 plausible hex characters, the machine would
reject every approval, and the visible symptom would be "tapping Approve does nothing"
-- which looks like a network problem. So it gets tested against a known-good
implementation, over the awkward lengths where padding and length-encoding go wrong.
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "phone.html")

# Lengths chosen around the 64-byte block and the 55/56-byte padding boundary, where the
# length field either does or does not fit in the final block.
LENGTHS = [0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000]
# Key lengths spanning the shorter-than-block, exactly-block and longer-than-block cases
# (a key over 64 bytes must be hashed first).
KEY_LENGTHS = [1, 20, 32, 63, 64, 65, 100]


def extract_crypto():
    """The crypto half of the page's script, up to the storage section."""
    with open(PAGE, "r", encoding="utf-8") as fh:
        html = fh.read()
    start = html.index("<script>") + len("<script>")
    end = html.index("/* ---------- storage ---------- */", start)
    js = html[start:end]
    # The page's only reference to injected data is this one line.
    return js.replace("var D = __BASTION_DATA__;", "")


def main():
    if subprocess.run(["sh", "-c", "command -v node"],
                      capture_output=True).returncode != 0:
        sys.exit("need nodejs on the build host: apt-get install nodejs")

    cases = []
    for n in LENGTHS:
        cases.append({"kind": "sha256", "msg": bytes((i * 31 + 7) & 0xFF
                                                     for i in range(n)).hex()})
    for kl in KEY_LENGTHS:
        for n in [0, 1, 32, 64, 200]:
            cases.append({"kind": "hmac",
                          "key": bytes((i * 17 + 5) & 0xFF for i in range(kl)).hex(),
                          "msg": bytes((i * 13 + 11) & 0xFF for i in range(n)).hex()})
    # The real shapes this code sees: a 20-byte secret and a 32-hex-character nonce.
    for nonce in ("00" * 16, "ff" * 16, os.urandom(16).hex()):
        cases.append({"kind": "hmac", "key": os.urandom(20).hex(),
                      "msg": nonce.encode().hex()})
    # base32 and UTF-8 helpers.
    b32_cases = ["JBSWY3DPEHPK3PXP", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                 "MFRGGZDFMZTWQ2LKNNWG23TPOA"]
    utf8_cases = ["", "abc", "café", "21°C ☁", "naïve → über"]

    harness = extract_crypto() + """
var cases = %s, b32 = %s, u8 = %s;
function unhex(s) {
  var out = new Uint8Array(s.length / 2);
  for (var i = 0; i < out.length; i++) out[i] = parseInt(s.substr(2*i, 2), 16);
  return out;
}
var res = { sha256: [], hmac: [], b32: [], utf8: [] };
for (var i = 0; i < cases.length; i++) {
  var c = cases[i];
  if (c.kind === "sha256") res.sha256.push(hex(sha256(unhex(c.msg))));
  else res.hmac.push(hex(hmacSha256(unhex(c.key), unhex(c.msg))));
}
for (i = 0; i < b32.length; i++) res.b32.push(hex(b32decode(b32[i])));
for (i = 0; i < u8.length; i++) res.utf8.push(hex(utf8(u8[i])));
console.log(JSON.stringify(res));
""" % (json.dumps(cases), json.dumps(b32_cases), json.dumps(utf8_cases))

    out = subprocess.run(["node", "-e", harness], capture_output=True)
    if out.returncode != 0:
        print(out.stderr.decode()[:3000])
        sys.exit("node failed to run the page's crypto")
    got = json.loads(out.stdout.decode())

    failures = []
    si = hi = 0
    for c in cases:
        if c["kind"] == "sha256":
            want = hashlib.sha256(bytes.fromhex(c["msg"])).hexdigest()
            if got["sha256"][si] != want:
                failures.append("sha256 of %d bytes: %s != %s"
                                % (len(c["msg"]) // 2, got["sha256"][si], want))
            si += 1
        else:
            want = hmac.new(bytes.fromhex(c["key"]), bytes.fromhex(c["msg"]),
                            hashlib.sha256).hexdigest()
            if got["hmac"][hi] != want:
                failures.append("hmac key=%d msg=%d bytes: %s != %s"
                                % (len(c["key"]) // 2, len(c["msg"]) // 2,
                                   got["hmac"][hi], want))
            hi += 1

    import base64
    for i, s in enumerate(b32_cases):
        want = base64.b32decode(s + "=" * (-len(s) % 8)).hex()
        if got["b32"][i] != want:
            failures.append("b32decode(%s): %s != %s" % (s, got["b32"][i], want))
    for i, s in enumerate(utf8_cases):
        want = s.encode("utf-8").hex()
        if got["utf8"][i] != want:
            failures.append("utf8(%r): %s != %s" % (s, got["utf8"][i], want))

    print("checked %d SHA-256 and %d HMAC vectors, %d base32, %d UTF-8"
          % (si, hi, len(b32_cases), len(utf8_cases)))
    for f in failures[:20]:
        print("  FAIL " + f)
    if failures:
        print("RESULT: FAIL (%d)" % len(failures))
        return 1
    print("RESULT: PASS -- the page's crypto matches hashlib exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
