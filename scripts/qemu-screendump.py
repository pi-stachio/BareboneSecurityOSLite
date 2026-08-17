#!/usr/bin/env python3
"""Grab the guest's screen through QEMU's monitor. Stdlib only.

  python3 qemu-screendump.py <monitor-port> <out.ppm> [out.png]

Some things can only be checked by looking at the screen. A boot splash either appears
or it does not; a QR code on tty1 either paints as readable modules or it paints as
something that looks fine to a human and cannot be scanned. Neither shows up in a serial
log, because neither goes anywhere near the serial port.

QEMU has to be started with a monitor to talk to:

  -monitor telnet:127.0.0.1:<port>,server,nowait

The file is written by QEMU, so it lands on the host, and `-display none` does not stop
it -- the display device is still emulated, it is just not shown in a window.
"""
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def screendump(port, ppm, timeout=20):
    if os.path.exists(ppm):
        os.unlink(ppm)
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(2)
    try:
        # Drain the banner, which arrives unprompted and would otherwise be read as
        # the reply to our command.
        time.sleep(0.5)
        try:
            sock.recv(65536)
        except socket.timeout:
            pass
        sock.sendall(("screendump %s\n" % ppm).encode())
        deadline = time.time() + timeout
        while time.time() < deadline:
            # QEMU creates the file before filling it, so a size check is needed as
            # well as an existence check.
            if os.path.exists(ppm) and os.path.getsize(ppm) > 1024:
                size = -1
                while size != os.path.getsize(ppm):
                    size = os.path.getsize(ppm)
                    time.sleep(0.2)
                return True
            time.sleep(0.2)
        return False
    finally:
        sock.close()


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: qemu-screendump.py <monitor-port> <out.ppm> [out.png]")
    port, ppm = int(sys.argv[1]), sys.argv[2]
    if not screendump(port, ppm):
        sys.exit("no screendump appeared at %s" % ppm)
    print("wrote %s (%d bytes)" % (ppm, os.path.getsize(ppm)))
    if len(sys.argv) > 3:
        subprocess.run([sys.executable, os.path.join(HERE, "ppm2png.py"),
                        ppm, sys.argv[3]], check=True)


if __name__ == "__main__":
    main()
