#!/bin/bash
# Generate a kernel .config for the barebone LFS system.
#
# Starts from x86_64_defconfig, then forces everything needed to boot a VM with no
# initramfs: the root filesystem driver and the disk controller drivers must be
# built IN, not modules, because nothing is available to load modules before root
# is mounted. Also applies the options LFS chapter 10.3 requires for udev.
#
# Run as root:  bash 05-make-kernel-config.sh
set -euo pipefail

KVER=6.18.10
SRC=${LFS:-/mnt/lfs}/sources
WORK=/root/kbuild
OUT=/root/lfs/kernel.config

mkdir -p "$WORK"
cd "$WORK"
if [ ! -d "linux-$KVER" ]; then
    echo "==> Extracting linux-$KVER"
    tar xf "$SRC/linux-$KVER.tar.xz"
fi
cd "linux-$KVER"

echo "==> make x86_64_defconfig"
make x86_64_defconfig > /dev/null

echo "==> Applying LFS + bootability options"
# --- LFS chapter 10.3 requirements (udev / devtmpfs) ---
scripts/config --enable  DEVTMPFS
scripts/config --enable  DEVTMPFS_MOUNT
scripts/config --disable UEVENT_HELPER          # interferes with udev
scripts/config --disable FW_LOADER_USER_HELPER

# --- root filesystem, built in ---
scripts/config --enable  EXT4_FS
scripts/config --enable  EXT4_USE_FOR_EXT2
scripts/config --enable  BLK_DEV_INITRD

# --- disk controllers, built in (no initramfs to load modules from) ---
scripts/config --enable  SCSI
scripts/config --enable  BLK_DEV_SD
scripts/config --enable  ATA
scripts/config --enable  ATA_SFF
scripts/config --enable  ATA_BMDMA
scripts/config --enable  SATA_AHCI
scripts/config --enable  ATA_PIIX
scripts/config --enable  VIRTIO
scripts/config --enable  VIRTIO_PCI
scripts/config --enable  VIRTIO_BLK
scripts/config --enable  VIRTIO_NET

# --- console: both VGA and serial, so QEMU -nographic works ---
scripts/config --enable  VT
scripts/config --enable  VT_CONSOLE
scripts/config --enable  SERIAL_8250
scripts/config --enable  SERIAL_8250_CONSOLE

# --- misc things a usable userland expects ---
scripts/config --enable  TMPFS
scripts/config --enable  TMPFS_POSIX_ACL
scripts/config --enable  PROC_FS
scripts/config --enable  SYSFS
scripts/config --enable  INOTIFY_USER
scripts/config --enable  BINFMT_ELF
scripts/config --enable  BINFMT_SCRIPT
scripts/config --enable  UNIX
scripts/config --enable  INET
scripts/config --enable  E1000
scripts/config --enable  E1000E

echo "==> make olddefconfig (resolve dependencies)"
make olddefconfig > /dev/null

echo "==> Sanity check: these must all be =y"
fail=0
for opt in CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT CONFIG_EXT4_FS CONFIG_BLK_DEV_SD \
           CONFIG_SATA_AHCI CONFIG_ATA_PIIX CONFIG_VIRTIO_BLK CONFIG_SERIAL_8250_CONSOLE; do
    if grep -q "^$opt=y" .config; then
        printf 'OK:    %s=y\n' "$opt"
    else
        printf 'ERROR: %s is not built in (%s)\n' "$opt" "$(grep -E "^($opt=|# $opt )" .config || echo unset)"
        fail=1
    fi
done
if grep -q '^CONFIG_UEVENT_HELPER=y' .config; then
    echo "ERROR: CONFIG_UEVENT_HELPER is enabled; LFS requires it off"; fail=1
else
    echo "OK:    CONFIG_UEVENT_HELPER disabled"
fi

mkdir -p "$(dirname "$OUT")"
cp .config "$OUT"
echo
echo "==> Kernel config written to $OUT"
exit $fail
