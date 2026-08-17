#!/bin/bash
# Boot BastionOS in a real window on the Windows desktop, via WSLg.
#
#   wsl -d lfs-host -u root -- bash scripts/run-lfs-gui.sh
#
# Boots /lfs-disk.img by default; point DISK_IMG at a released .qcow2 to try exactly
# what a download gives you:
#
#   DISK_IMG=.../image/bastionos-1.5.0-x86_64.qcow2 bash scripts/run-lfs-gui.sh
#
# Log in as root / lfs. Type `poweroff` to shut down, or just close the window.
set -euo pipefail

IMG=${DISK_IMG:-/lfs-disk.img}
PORT=${SSH_PORT:-2222}
QRPORT=${QR_PORT:-8043}
[ -f "$IMG" ] || { echo "FATAL: $IMG not found"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "FATAL: no DISPLAY; WSLg not available"; exit 1; }

# Detect the format instead of assuming raw. Handing qemu a qcow2 while claiming
# format=raw does not fail cleanly -- it boots whatever it finds in the qcow2 header
# and lands in the BIOS with "no bootable device", which looks like a broken image.
# Read the plain-text output, not --output=json: the JSON nests the image format under
# a child whose own "format" is the protocol layer ("file"), so the first match in the
# JSON is always "file" regardless of the actual image.
FMT=$(qemu-img info "$IMG" 2>/dev/null | awk -F': ' '/^file format:/{print $2; exit}')
FMT=${FMT:-raw}

ACCEL=()
if [ -w /dev/kvm ]; then
    ACCEL=(-enable-kvm -cpu host)
else
    echo "note: /dev/kvm is unavailable, so this runs under software emulation."
    echo "      Expect the boot to take a minute or two."
fi

echo "Opening a QEMU window  ($(basename "$IMG"), format=$FMT)"
echo "  tty1  : phone login (scan the QR code).  Alt-F3 for a password prompt."
echo "  login : root / lfs   or   admin / lfs"
echo "  ssh   : refuses passwords and ships no key. From the guest console, run"
echo "          bastionctl add-key 'ssh-ed25519 AAAA... you@host'"
echo "          then: ssh -p $PORT admin@localhost"
echo
echo "  Tapping Approve on a phone needs the phone to reach the guest, and user-mode"
echo "  networking NATs it. Port $QRPORT is forwarded, but the guest still has to be"
echo "  told the address the phone will use -- on the guest:"
echo "          echo 'advertise = <this-machine-lan-ip>:$QRPORT' >> /etc/bastionos/qrauth.conf"
echo "          /etc/rc.d/init.d/qrauthd restart"
echo "  The typed-code path ([c] on the login screen) needs none of that."
exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "${MEM:-2048}" -smp "${CPUS:-2}" \
    -drive file="$IMG",format="$FMT",if=ide \
    -netdev user,id=n0,hostfwd=tcp::"$PORT"-:22,hostfwd=tcp::"$QRPORT"-:"$QRPORT" \
    -device e1000,netdev=n0 \
    -display gtk -vga std -no-reboot
