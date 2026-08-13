#!/bin/bash
# Finalise the kernel config INSIDE the LFS chroot.
#
# 05-make-kernel-config.sh generates the config on the Debian host, but some Kconfig
# symbols are only visible when the compiler supports them -- CONFIG_GCC_PLUGINS
# appears only if gcc ships plugin headers. Host gcc-14 lacks them, LFS gcc-15.2.0
# has them, so the host-made config is missing symbols and the book's
# `timeout 60 make oldconfig` stops on the first NEW one and times out (exit 124).
#
# Running olddefconfig with the target compiler fills every NEW symbol with its
# default while preserving everything we already set.
#
# Run as root:  bash 05b-finalize-kernel-config.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
KVER=6.18.10

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

echo "==> Ensuring virtual kernel filesystems are mounted"
mkdir -pv "$LFS"/{dev,proc,sys,run} > /dev/null
mountpoint -q "$LFS/dev"     || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -t tmpfs tmpfs "$LFS/run"

echo "==> Finalising config with the LFS toolchain"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" \
    /bin/bash --login -e <<EOF
set -e
cd /sources
if [ ! -d linux-$KVER ]; then tar -xf linux-$KVER.tar.xz; fi
cd linux-$KVER
gcc --version | head -1
cp -v /sources/kernel-config .config
make olddefconfig

echo "--- verifying the options we depend on survived ---"
fail=0
for opt in CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_EXT4_FS CONFIG_BLK_DEV_SD \\
           CONFIG_SATA_AHCI CONFIG_ATA_PIIX CONFIG_VIRTIO_BLK CONFIG_SERIAL_8250_CONSOLE; do
    if grep -q "^\$opt=y" .config; then echo "OK:    \$opt=y"
    else echo "ERROR: \$opt not built in"; fail=1; fi
done
if grep -q '^CONFIG_UEVENT_HELPER=y' .config; then
    echo "ERROR: CONFIG_UEVENT_HELPER enabled"; fail=1
else
    echo "OK:    CONFIG_UEVENT_HELPER disabled"
fi
[ "\$fail" = 0 ] || exit 1

echo "--- proving the book's command now completes non-interactively ---"
timeout 60 make oldconfig < /dev/null
echo "oldconfig completed cleanly"

cp -v .config /sources/kernel-config
EOF

echo
echo "==> Copying the finalised config back to the host for reproducibility"
cp -v "$LFS/sources/kernel-config" /root/lfs/kernel.config
echo "==> Done. Re-run 07-run-build.sh to resume at 1002-kernel."
