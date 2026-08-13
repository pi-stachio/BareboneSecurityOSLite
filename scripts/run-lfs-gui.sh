#!/bin/bash
# Boot the LFS system in a real window on the Windows desktop, via WSLg.
#
#   wsl -d lfs-host -u root -- bash /root/lfs/run-lfs-gui.sh
#
# Log in as root / lfs. Type `poweroff` to shut down, or just close the window.
set -euo pipefail

IMG=${DISK_IMG:-/lfs-disk.img}
[ -f "$IMG" ] || { echo "FATAL: $IMG not found"; exit 1; }
[ -n "${DISPLAY:-}" ] || { echo "FATAL: no DISPLAY; WSLg not available"; exit 1; }

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

echo "Opening a QEMU window (login: root / lfs)"
exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "${MEM:-2048}" -smp "${CPUS:-2}" \
    -drive file="$IMG",format=raw,if=ide \
    -display gtk -vga std -no-reboot
