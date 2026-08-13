#!/bin/bash
# Boot the LFS system interactively on the serial console.
#
#   wsl -d lfs-host -u root -- bash /root/lfs/run-lfs.sh
#
# Log in as root / lfs. To shut down cleanly type `poweroff`.
# To detach from QEMU without shutting the guest down: Ctrl-a then x.
set -euo pipefail

IMG=${DISK_IMG:-/lfs-disk.img}
[ -f "$IMG" ] || { echo "FATAL: $IMG not found"; exit 1; }

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

echo "Booting $IMG  (login: root / lfs   |   detach: Ctrl-a x)"
exec qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m "${MEM:-2048}" -smp "${CPUS:-2}" \
    -drive file="$IMG",format=raw,if=ide \
    -nographic -no-reboot
