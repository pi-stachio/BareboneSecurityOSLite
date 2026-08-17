#!/bin/bash
# Convert the raw disk image to a compressed qcow2 for release, refusing to package
# anything that was built for testing.
#
# The test image and the release image differ by one file -- an authorised SSH key --
# and that is exactly the kind of difference that ships by accident. 08-make-bootable-image.sh
# marks test builds; this refuses to touch them.
#
# Run as root:  bash 20-package-image.sh <version>
set -euo pipefail

VER=${1:-}
[ -n "$VER" ] || { echo "usage: $0 <version>   e.g. $0 1.4.0"; exit 1; }

IMG=${DISK_IMG:-/lfs-disk.img}
OUT=${OUT_DIR:-/mnt/c/Users/neume/Desktop/Projects/BareboneSecurityOSLite/image}
NAME="bastionos-$VER-x86_64.qcow2"
VDI="bastionos-$VER-x86_64.vdi"
MNT=/mnt/pkgcheck

[ -f "$IMG" ] || { echo "FATAL: no image at $IMG"; exit 1; }

echo "==> Checking $IMG is releasable"
mkdir -p "$MNT"
LOOP=$(losetup --find --show --partscan "$IMG")
cleanup() { umount "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
mount -o ro "${LOOP}p1" "$MNT"

fail=0
if [ -e "$MNT/etc/bastionos/TEST-IMAGE-DO-NOT-RELEASE" ]; then
    echo "REFUSING: this image was built with PROVISION_TEST_KEY=1"
    echo "          $(cat "$MNT/etc/bastionos/TEST-IMAGE-DO-NOT-RELEASE")"
    echo "          rebuild with: bash 08-make-bootable-image.sh"
    fail=1
fi
if [ -s "$MNT/home/admin/.ssh/authorized_keys" ]; then
    echo "REFUSING: an SSH key is authorised in the image:"
    ssh-keygen -lf "$MNT/home/admin/.ssh/authorized_keys" 2>/dev/null | sed 's/^/          /'
    fail=1
fi
if ls "$MNT"/etc/ssh/ssh_host_* > /dev/null 2>&1; then
    echo "REFUSING: SSH host keys are baked into the image; every download would share them:"
    for k in "$MNT"/etc/ssh/ssh_host_*_key.pub; do
        [ -e "$k" ] && ssh-keygen -lf "$k" 2>/dev/null | sed 's/^/          /'
    done
    fail=1
fi
if [ -e "$MNT/var/lib/bastionos/firstboot-done" ]; then
    echo "REFUSING: first-boot setup has already run in this image, so it will not run"
    echo "          for the user and host keys would never be regenerated."
    fail=1
fi
[ "$fail" = 0 ] || { echo; echo "Image is NOT releasable."; exit 1; }
echo "OK:    no baked-in keys, first boot still pending"

umount "$MNT"; losetup -d "$LOOP"; trap - EXIT

echo
echo "==> Converting to $NAME"
mkdir -p "$OUT"
rm -f "$OUT"/*.qcow2
qemu-img convert -f raw -O qcow2 -c "$IMG" "$OUT/$NAME"
cd "$OUT"
ls -l --block-size=M "$NAME"
sha256sum "$NAME" | tee "$NAME.sha256"

# VirtualBox cannot read qcow2, and phone login is far easier to try there than under
# QEMU: a bridged adapter puts the guest on the same network as the phone, with no port
# forwarding and no `advertise` override. So ship a VDI as well.
#
# Zipped, not raw: the VDI is ~1.8 GB where the compressed form is a third of that, and
# .zip is the one archive format a Windows machine opens with no extra software.
echo
echo "==> Converting to $VDI"
# Only the versioned name is removed. A glob would take any scratch VDI sitting in this
# directory with it, which is the sort of thing that eats a file someone was using.
rm -f "$OUT/$VDI" "$OUT/$VDI.zip"
qemu-img convert -f raw -O vdi "$IMG" "$OUT/$VDI"
if command -v zip > /dev/null 2>&1; then
    zip -q -j -9 "$OUT/$VDI.zip" "$OUT/$VDI"
    rm -f "$OUT/$VDI"
    ls -l --block-size=M "$VDI.zip"
    sha256sum "$VDI.zip" | tee "$VDI.zip.sha256"
else
    echo "WARN:  no zip on this host; shipping the VDI uncompressed"
    ls -l --block-size=M "$VDI"
    sha256sum "$VDI" | tee "$VDI.sha256"
fi

echo
echo "==> Releasable:"
echo "    $OUT/$NAME"
ls "$OUT/$VDI.zip" > /dev/null 2>&1 && echo "    $OUT/$VDI.zip" || echo "    $OUT/$VDI"
