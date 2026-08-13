#!/bin/bash
# Create a loopback ext4 filesystem to act as the LFS "partition", mounted at /mnt/lfs.
# WSL2 has no spare physical partition, so a loop-mounted image gives us a real,
# self-contained ext4 filesystem that can later be booted in a VM.
# Run as root:  bash 01-lfs-partition.sh [size]
set -euo pipefail

IMG=${LFS_IMG:-/lfs.img}
LFS=${LFS:-/mnt/lfs}
SIZE=${1:-40G}

if [ -e "$IMG" ]; then
    echo "==> $IMG already exists ($(du -h --apparent-size "$IMG" | cut -f1) apparent), leaving it alone"
else
    echo "==> Creating sparse image $IMG ($SIZE)"
    truncate -s "$SIZE" "$IMG"
    echo "==> Formatting ext4"
    mkfs.ext4 -q -L LFS -F "$IMG"
fi

mkdir -pv "$LFS"
if mountpoint -q "$LFS"; then
    echo "==> $LFS already mounted"
else
    echo "==> Mounting $IMG at $LFS"
    mount -o loop "$IMG" "$LFS"
fi

# Auto-mount on future WSL boots. WSL processes /etc/fstab by default; nofail keeps
# a bad image from wedging startup.
if ! grep -q "^$IMG" /etc/fstab 2>/dev/null; then
    echo "==> Adding fstab entry"
    echo "$IMG  $LFS  ext4  loop,nofail  0 0" >> /etc/fstab
fi

echo "==> Creating the LFS directory skeleton (book chapter 4.2)"
mkdir -pv "$LFS"/{etc,var,lib64,tools}
mkdir -pv "$LFS"/usr/{bin,lib,sbin}
for i in bin lib sbin; do
    ln -sfv usr/$i "$LFS/$i"
done
mkdir -pv "$LFS/sources"
chmod -v a+wt "$LFS/sources"

echo
df -h "$LFS"
echo "==> LFS partition ready at $LFS"
