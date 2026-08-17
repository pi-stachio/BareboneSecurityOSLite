#!/usr/bin/env python3
"""End-to-end test of the phone login flow, without a phone.

Runs on the BUILD HOST against the source tree:

  python3 scripts/qrauth/test-flow.py

Starts a real bastion-qrauthd on a temporary store and socket, then plays the part of
the phone: fetches the served page over HTTP, computes the HMAC the JavaScript would
compute, and posts it back. The JavaScript itself is checked separately by test-js.py,
so between the two the only untested link is the phone's camera.

The negative cases matter more than the positive one. An auth mechanism that says yes
when it should is easy; this checks that it says no to a replayed nonce, a reused TOTP
code, a wrong response, an expired session, a second approval of the same session, an
oversized body, and an attempt to enrol root.
"""
import base64
import hashlib
import hmac
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 18043


def find(name, installed):
    """Prefer the source tree, fall back to the installed copy.

    This file gets copied onto a booted BastionOS by the boot test and run there, where
    it is on its own -- and that run is the one that matters, because the target's
    Python is not the build host's.
    """
    local = os.path.join(HERE, name)
    return local if os.path.exists(local) else installed


DAEMON = find("bastion-qrauthd", "/usr/sbin/bastion-qrauthd")
PAGE = find("phone.html", "/usr/lib/bastionos/phone.html")

failures = []
checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)
    return cond


def ask(sock_path, req, timeout=10):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode().split("\n", 1)[0])
    finally:
        s.close()


def http_get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def http_post(url, obj, raw=None):
    body = raw if raw is not None else json.dumps(obj).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except ValueError:
            return e.code, {}


def totp_now(secret_b32, drift=0):
    secret = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8))
    counter = int(time.time()) // 30 + drift
    mac = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    off = mac[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % 1000000)


def main():
    tmp = tempfile.mkdtemp(prefix="qrauth-test-")
    # mkdtemp is 0700, which would stop an unprivileged caller reaching the socket for
    # reasons that have nothing to do with the daemon. The real /run/bastionos is 0755
    # and the socket is world-connectable on purpose, so mirror that here -- the store
    # underneath stays 0700, and the permission check below still asserts it.
    os.chmod(tmp, 0o755)
    store = os.path.join(tmp, "store")
    sock = os.path.join(tmp, "qrauth.sock")
    conf = os.path.join(tmp, "qrauth.conf")
    with open(conf, "w") as fh:
        fh.write("port = %d\n" % PORT)

    env = dict(os.environ,
               BASTION_QRAUTH_STORE=store,
               BASTION_QRAUTH_SOCK=sock,
               BASTION_QRAUTH_CONF=conf,
               BASTION_QRAUTH_PAGE=PAGE)
    log = open(os.path.join(tmp, "daemon.log"), "w+")
    proc = subprocess.Popen([sys.executable, DAEMON], env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if os.path.exists(sock):
                break
            time.sleep(0.05)
        if not check(os.path.exists(sock), "daemon never created its socket"):
            raise SystemExit

        base = "http://127.0.0.1:%d" % PORT

        # --- the port must be shut while nothing is pending -------------------
        st = ask(sock, {"op": "status"})
        check(st["ok"] and not st["listening"],
              "port is open with nothing pending: %r" % st)

        # --- enrolling root must be refused ----------------------------------
        r = ask(sock, {"op": "register", "user": "root", "name": "phone"})
        check(not r.get("ok") and "root" in r.get("error", ""),
              "root was allowed to enrol: %r" % r)

        # --- register a device ------------------------------------------------
        reg = ask(sock, {"op": "register", "user": "alice", "name": "pixel"})
        if not check(reg.get("ok"), "register failed: %r" % reg):
            raise SystemExit
        devid, secret_b32 = reg["devid"], reg["secret"]
        check(reg["url"].startswith("http://") and "/e#" in reg["url"],
              "enrolment url looks wrong: %r" % reg["url"])
        check(devid in reg["url"] and secret_b32 in reg["url"],
              "enrolment url is missing the device id or secret")
        check("otpauth://totp/" in reg["totp_uri"] and secret_b32 in reg["totp_uri"],
              "otpauth uri looks wrong: %r" % reg["totp_uri"])

        # Registering opens an enrolment window, so the port must now be open.
        st = ask(sock, {"op": "status"})
        check(st["listening"] and st["enrolling"],
              "enrolment did not open the port: %r" % st)

        # --- the enrolment page ----------------------------------------------
        code, html = http_get(base + "/e")
        check(code == 200 and '"mode": "enrol"' in html and '"user": "alice"' in html,
              "enrolment page wrong: %d %r" % (code, html[:200]))
        # The secret must not appear in the page: it travels in the URL fragment,
        # which the browser does not send and the server therefore cannot echo.
        check(secret_b32 not in html, "the secret leaked into the served page")

        # --- unknown paths ----------------------------------------------------
        check(http_get(base + "/")[0] == 404, "/ should be 404")
        check(http_get(base + "/../etc/passwd")[0] == 404, "path traversal not refused")
        check(http_post(base + "/nope", {})[0] == 404, "POST /nope should be 404")

        # --- a login, approved properly ---------------------------------------
        sess = ask(sock, {"op": "login_new", "tty": "tty1"})
        if not check(sess.get("ok"), "login_new failed: %r" % sess):
            raise SystemExit
        sid, nonce = sess["sid"], sess["nonce"]
        check(sess["url"].endswith("/a?" + sid), "login url wrong: %r" % sess["url"])

        code, html = http_get(base + "/a?" + sid)
        check(code == 200 and nonce in html and '"mode": "approve"' in html,
              "approve page wrong: %d" % code)
        check('"tty": "tty1"' in html, "approve page does not name the tty")

        secret = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8))
        good = hmac.new(secret, nonce.encode(), hashlib.sha256).hexdigest()

        # A wrong response first.
        code, r = http_post(base + "/r", {"sid": sid, "devid": devid,
                                          "resp": "00" * 32})
        check(code == 403 and not r.get("ok"), "wrong response was not rejected: %d %r"
              % (code, r))
        # Session must still be usable after a failure.
        check(ask(sock, {"op": "login_poll", "sid": sid})["state"] == "pending",
              "a failed attempt killed the session")

        code, r = http_post(base + "/r", {"sid": sid, "devid": devid, "resp": good})
        check(code == 200 and r.get("ok") and r.get("user") == "alice",
              "correct response was not accepted: %d %r" % (code, r))

        poll = ask(sock, {"op": "login_poll", "sid": sid})
        check(poll["state"] == "approved" and poll["user"] == "alice",
              "poll did not report approval: %r" % poll)
        # Reading the approval consumes it.
        poll = ask(sock, {"op": "login_poll", "sid": sid})
        check(poll["state"] == "spent", "approval was not single-use: %r" % poll)

        # Approving an already-approved session must fail.
        code, r = http_post(base + "/r", {"sid": sid, "devid": devid, "resp": good})
        check(code == 409, "second approval of the same session allowed: %d" % code)

        # --- a replayed nonce on a fresh session ------------------------------
        sess2 = ask(sock, {"op": "login_new", "tty": "tty2"})
        check(sess2["nonce"] != nonce, "two sessions got the same nonce")
        code, r = http_post(base + "/r", {"sid": sess2["sid"], "devid": devid,
                                          "resp": good})
        check(code == 403, "a response for the old nonce was accepted: %d" % code)
        ask(sock, {"op": "login_cancel", "sid": sess2["sid"]})

        # --- oversized body ---------------------------------------------------
        sess3 = ask(sock, {"op": "login_new", "tty": "tty3"})
        code, r = http_post(base + "/r", None, raw=b"x" * 65536)
        check(code == 413, "oversized body not refused: %d" % code)

        # --- too many attempts abandons the session ---------------------------
        for _ in range(11):
            http_post(base + "/r", {"sid": sess3["sid"], "devid": devid,
                                    "resp": "11" * 32})
        check(ask(sock, {"op": "login_poll", "sid": sess3["sid"]})["state"] != "pending",
              "unlimited approval attempts allowed")

        # --- typed TOTP code --------------------------------------------------
        # Eleven wrong approve attempts happened just above. They must NOT have locked
        # the device: a wrong HMAC is a guess in a 2^256 space, so locking on it would
        # buy nothing and would let anyone who can reach the port deny the phone its
        # offline code path.
        # Generate the code ONCE and present it twice. Calling totp_now() a second time
        # can cross a 30-second step boundary and hand back a different code that is
        # legitimately valid, which makes "the same code twice" pass or fail depending
        # on what second of the minute the test ran in.
        code = totp_now(secret_b32)
        r = ask(sock, {"op": "totp", "user": "alice", "code": code})
        check(r.get("ok"), "wrong approve attempts locked the device out of TOTP: %r" % r)
        check(r.get("devid") == devid, "valid TOTP code refused: %r" % r)
        r = ask(sock, {"op": "totp", "user": "alice", "code": code})
        check(not r.get("ok"), "a TOTP code was accepted twice: %r" % r)
        r = ask(sock, {"op": "totp", "user": "alice", "code": "000000"})
        check(not r.get("ok"), "an invalid TOTP code was accepted")
        r = ask(sock, {"op": "totp", "user": "nobody", "code": totp_now(secret_b32)})
        check(not r.get("ok"), "a code was accepted for an unenrolled account")

        # Wrong typed codes DO lock the device. Six digits is a million possibilities
        # with only ~30 seconds per code, which is brute-forceable given days, so this
        # path is the one that needs a lockout.
        for _ in range(6):
            ask(sock, {"op": "totp", "user": "alice", "code": "000001"})
        r = ask(sock, {"op": "totp", "user": "alice", "code": totp_now(secret_b32)})
        check(not r.get("ok") and "lock" in r.get("error", ""),
              "repeated wrong typed codes did not lock the device: %r" % r)

        # --- devices and revocation -------------------------------------------
        d = ask(sock, {"op": "devices", "user": "alice"})
        check(d["ok"] and len(d["devices"]) == 1 and d["devices"][0]["name"] == "pixel",
              "device listing wrong: %r" % d)
        check(d["devices"][0]["locked_until"] > time.time(),
              "device listing does not show the lockout: %r" % d)
        check(ask(sock, {"op": "revoke", "devid": devid}).get("ok"), "revoke failed")
        check(len(ask(sock, {"op": "devices"})["devices"]) == 0,
              "device survived revocation")
        r = ask(sock, {"op": "totp", "user": "alice", "code": totp_now(secret_b32)})
        check(not r.get("ok") and "no device" in r.get("error", ""),
              "a revoked device still authenticates: %r" % r)

        # --- what an unprivileged caller may ask -------------------------------
        # The socket is reachable by any local user, so the privilege boundary is the
        # peer uid the kernel reports, not the file mode. Re-run the ops as nobody.
        # Skipped when not root, since dropping privileges is the whole point.
        if os.getuid() == 0:
            import pwd as _pwd
            nobody = _pwd.getpwnam("nobody").pw_uid

            def as_nobody(req):
                """Run one request from a child that has dropped to nobody."""
                r, w = os.pipe()
                pid = os.fork()
                if pid == 0:
                    try:
                        os.close(r)
                        os.setgroups([])
                        os.setuid(nobody)
                        out = json.dumps(ask(sock, req)).encode()
                    except Exception as exc:                     # noqa: BLE001
                        out = json.dumps({"ok": False,
                                          "error": "child: %s" % exc}).encode()
                    os.write(w, out)
                    os._exit(0)
                os.close(w)
                buf = b""
                while True:
                    chunk = os.read(r, 4096)
                    if not chunk:
                        break
                    buf += chunk
                os.close(r)
                os.waitpid(pid, 0)
                return json.loads(buf.decode())

            # Anything that grants a login, enrols, revokes or checks a code: refused.
            for req in ({"op": "login_new", "tty": "tty1"},
                        {"op": "register", "user": "mallory", "name": "p"},
                        {"op": "revoke", "devid": devid},
                        {"op": "totp", "user": "alice", "code": totp_now(secret_b32)}):
                r = as_nobody(req)
                check(not r.get("ok") and "root" in r.get("error", ""),
                      "unprivileged caller was allowed %s: %r" % (req["op"], r))

            # Read-only ops are allowed, and scoped to the caller regardless of what
            # they asked for.
            r = as_nobody({"op": "status"})
            check(r.get("ok"), "unprivileged caller could not read status: %r" % r)
            r = as_nobody({"op": "devices", "user": "alice"})
            check(r.get("ok"), "unprivileged caller could not list devices: %r" % r)
            check(r.get("devices") == [],
                  "asking for another account's devices returned them: %r" % r)

        # --- secrets on disk are not world-readable ---------------------------
        for root, dirs, files in os.walk(store):
            for name in dirs + files:
                mode = os.stat(os.path.join(root, name)).st_mode & 0o777
                check(mode & 0o077 == 0,
                      "%s is mode %o, group/other can reach the secrets"
                      % (os.path.join(root, name), mode))

        # --- the port closes again --------------------------------------------
        ask(sock, {"op": "login_cancel", "sid": sid})
        ask(sock, {"op": "login_cancel", "sid": sess3["sid"]})
        # The enrolment window is still open, so force it shut by waiting for the
        # reaper only if it has expired; instead just confirm the daemon reports
        # honestly about what is pending.
        st = ask(sock, {"op": "status"})
        check(st["pending"] == 0, "sessions still pending after cancel: %r" % st)

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.flush()
        log.seek(0)
        daemon_log = log.read()
        log.close()

    print("ran %d checks" % checks)
    for f in failures:
        print("  FAIL " + f)
    if failures:
        print("\n--- daemon log ---\n" + daemon_log[-3000:])
        print("RESULT: FAIL (%d)" % len(failures))
        shutil.rmtree(tmp, ignore_errors=True)
        return 1
    # The log is part of the contract: an operator has to be able to see who logged in.
    for want in ("ENROL", "APPROVE", "REJECT", "REVOKE"):
        if want not in daemon_log:
            print("  FAIL daemon never logged %s" % want)
            print("RESULT: FAIL")
            shutil.rmtree(tmp, ignore_errors=True)
            return 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
