"""Device store and challenge/response for BastionOS phone login.

A "device" is one phone enrolled against one Unix account. It holds a 20-byte secret
that is generated here and delivered to the phone optically, in the QR code shown by
`bastionctl register`. The secret is never sent over the network.

That one secret serves two login paths, which matters because a phone is not always on
the same network as the machine:

  tap to approve   The console shows a QR containing a URL and a one-time nonce. The
                   phone opens it, computes HMAC-SHA256(secret, nonce) and posts the
                   result. The secret stays on the phone; the nonce makes the reply
                   useless a second time.

  type a code      Plain RFC 6238 TOTP over the same secret, so any authenticator app
                   works and nothing has to reach the machine over IP at all.

Why a shared secret rather than a keypair: the phone side runs in a browser reached over
plain HTTP on a LAN, which is not a "secure context", so window.crypto.subtle is
unavailable and there is no way to sign anything without shipping an elliptic-curve
implementation in hand-written JavaScript. HMAC-SHA256 is ~80 lines and is what TOTP
already needs. crypto.getRandomValues is available in insecure contexts, but it does not
help here: any key the phone generates still has to reach the machine somehow.

Only this module and the daemon touch the store. Everything else goes through the
daemon's socket, so exactly one process writes these files.
"""
import base64
import errno
import hashlib
import hmac
import json
import os
import re
import secrets
import struct
import time

STORE = os.environ.get("BASTION_QRAUTH_STORE", "/var/lib/bastionos/qrauth")
DEVICES = os.path.join(STORE, "devices")

# A wrong code should cost an attacker time. Six digits is a million possibilities, but
# only ~30 tries per code window, so a few thousand attempts is a real threat over days.
MAX_FAILS = 5
LOCKOUT_SECONDS = 300

TOTP_STEP = 30
TOTP_DIGITS = 6
# One step either side, for clock skew between the phone and the machine.
TOTP_WINDOW = 1

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")


class AuthError(Exception):
    pass


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

def init_store():
    os.makedirs(DEVICES, mode=0o700, exist_ok=True)
    os.chmod(STORE, 0o700)
    os.chmod(DEVICES, 0o700)


def _path(devid):
    # Eight hex characters, not more. A device id is a label, not a secret -- the phone
    # sends it in the clear and it proves nothing on its own -- and every character of
    # it lands in the enrolment QR, where the difference between a version 4 and a
    # version 5 symbol is four more rows than an 80x25 console can spare.
    if not re.match(r"^[0-9a-f]{8}$", devid or ""):
        raise AuthError("malformed device id")
    return os.path.join(DEVICES, devid + ".json")


def _read(devid):
    try:
        with open(_path(devid), "r") as fh:
            return json.load(fh)
    except IOError as exc:
        if exc.errno == errno.ENOENT:
            raise AuthError("no such device")
        raise


def _write(devid, rec):
    path = _path(devid)
    tmp = path + ".new"
    # Written 0600 before the rename so the secret is never briefly world-readable.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(rec, fh)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.rename(tmp, path)


def list_devices(user=None):
    out = []
    try:
        names = sorted(os.listdir(DEVICES))
    except IOError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        devid = name[:-5]
        try:
            rec = _read(devid)
        except (AuthError, ValueError):
            continue
        if user is None or rec.get("user") == user:
            out.append((devid, rec))
    return out


def add_device(user, name):
    if not _NAME_RE.match(name or ""):
        raise AuthError("device name must be 1-32 chars of letters, digits, . _ -")
    if user == "root":
        # root stays password-only on its own tty. A phone is a single point of
        # failure and the recovery path must not depend on it.
        raise AuthError("refusing to enrol root; keep a password for the console")
    init_store()
    devid = secrets.token_hex(4)
    # 160 bits. RFC 4226 requires at least 128 for the TOTP side and recommends 160,
    # and the same secret keys the HMAC-SHA256 challenge.
    secret = secrets.token_bytes(20)
    _write(devid, {
        "user": user,
        "name": name,
        "secret": base64.b32encode(secret).decode().rstrip("="),
        "created": int(time.time()),
        "last_counter": 0,
        "fails": 0,
        "locked_until": 0,
        "last_used": 0,
    })
    return devid, secret


def remove_device(devid):
    os.unlink(_path(devid))


def secret_of(rec):
    s = rec["secret"]
    return base64.b32decode(s + "=" * (-len(s) % 8))


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def _check_lock(devid, rec):
    now = int(time.time())
    if rec.get("locked_until", 0) > now:
        raise AuthError("device locked for %d more seconds"
                       % (rec["locked_until"] - now))


def _record_failure(devid, rec):
    rec["fails"] = rec.get("fails", 0) + 1
    if rec["fails"] >= MAX_FAILS:
        rec["locked_until"] = int(time.time()) + LOCKOUT_SECONDS
        rec["fails"] = 0
    _write(devid, rec)


def _record_success(devid, rec, counter=None):
    rec["fails"] = 0
    rec["locked_until"] = 0
    rec["last_used"] = int(time.time())
    if counter is not None:
        rec["last_counter"] = counter
    _write(devid, rec)


def totp(secret, counter):
    mac = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    code = struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF
    return "%0*d" % (TOTP_DIGITS, code % (10 ** TOTP_DIGITS))


def challenge_response(secret, nonce):
    """What the phone must return for a login nonce."""
    return hmac.new(secret, nonce.encode(), hashlib.sha256).hexdigest()


def verify_challenge(devid, nonce, response):
    """Check a tap-to-approve reply. Returns the username."""
    rec = _read(devid)
    _check_lock(devid, rec)
    want = challenge_response(secret_of(rec), nonce)
    if not hmac.compare_digest(want, (response or "").lower()):
        # Counted for the audit trail but deliberately NOT toward the lockout.
        #
        # A wrong response here is a wrong guess in a 2^256 space, so there is nothing
        # to brute force and a lockout buys no security. It would cost something,
        # though: anyone who can reach the port could post garbage and lock the phone
        # out of the typed-code path as well, which is the path that works when the
        # phone is not on this network. That turns a failed attack into a successful
        # denial of service. The daemon's per-session attempt cap is what limits abuse
        # here, and it expires with the session.
        rec["challenge_fails"] = rec.get("challenge_fails", 0) + 1
        _write(devid, rec)
        raise AuthError("bad response")
    rec["challenge_fails"] = 0
    _record_success(devid, rec)
    return rec["user"]


def verify_totp(user, code):
    """Check a typed code against every device enrolled to user. Returns the devid."""
    code = re.sub(r"\s+", "", code or "")
    if not re.match(r"^[0-9]{%d}$" % TOTP_DIGITS, code):
        raise AuthError("expected %d digits" % TOTP_DIGITS)
    devices = list_devices(user)
    if not devices:
        raise AuthError("no device enrolled for %s" % user)

    now = int(time.time()) // TOTP_STEP
    locked = 0
    for devid, rec in devices:
        try:
            _check_lock(devid, rec)
        except AuthError:
            locked += 1
            continue
        for drift in range(-TOTP_WINDOW, TOTP_WINDOW + 1):
            counter = now + drift
            # Refuse a code that has already been accepted. Without this, anyone who
            # reads the code over your shoulder has 30 seconds to reuse it.
            if counter <= rec.get("last_counter", 0):
                continue
            if hmac.compare_digest(totp(secret_of(rec), counter), code):
                _record_success(devid, rec, counter)
                return devid
        _record_failure(devid, rec)
    if locked == len(devices):
        raise AuthError("all devices for %s are locked out" % user)
    raise AuthError("that code is not valid")


# ---------------------------------------------------------------------------
# URIs shown as QR codes
# ---------------------------------------------------------------------------

def enroll_uri(base_url, devid, secret):
    """URL for the enrolment QR.

    The secret rides in the fragment, which browsers do not send to the server, so it
    never touches the network in either direction -- it goes from this machine to the
    phone optically and stops there. The page strips the fragment from the address bar
    once it has stored it. The residual exposure is the phone's own history and any
    browser-sync of it, which is a worse place for a secret than nowhere but a better
    one than a plaintext HTTP response body on a shared network.
    """
    s = base64.b32encode(secret).decode().rstrip("=")
    return "%s/e#%s.%s" % (base_url, devid, s)


def totp_uri(user, host, secret):
    """Standard otpauth: URI, for people who would rather use an authenticator app.

    digits, period and issuer are all omitted deliberately. Six digits over thirty
    seconds are the RFC 6238 defaults that every app already assumes, and the "issuer:
    account" label carries the issuer without a separate parameter. Each character
    costs QR modules, and dropping those nineteen keeps this inside a version 5 symbol,
    which is the largest that fits an 80x25 console.
    """
    s = base64.b32encode(secret).decode().rstrip("=")
    return "otpauth://totp/%s:%s?secret=%s" % (host, user, s)
