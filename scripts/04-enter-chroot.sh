#!/bin/bash
# Mount the virtual kernel filesystems and enter the LFS chroot (book chapter 7.3/7.4).
# You need this from chapter 7 onward, and again on every fresh WSL session.
# Run as root:  bash 04-enter-chroot.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
mountpoint -q "$LFS" || { echo "FATAL: $LFS is not mounted. Run 01-lfs-partition.sh first."; exit 1; }

echo "==> Mounting virtual kernel filesystems"
mkdir -pv "$LFS"/{dev,proc,sys,run}

mountpoint -q "$LFS/dev"     || mount -v --bind /dev "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -vt proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -vt sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -vt tmpfs tmpfs "$LFS/run"

if [ -h "$LFS/dev/shm" ]; then
    install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
else
    mountpoint -q "$LFS/dev/shm" || mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

echo "==> Entering chroot"
exec chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" \
    TESTSUITEFLAGS="-j$(nproc)" \
    /bin/bash --login
