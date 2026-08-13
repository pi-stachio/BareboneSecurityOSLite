#!/bin/bash
# Turn the finished LFS tree into a bootable disk image.
#
# The build filesystem (/lfs.img) is a bare ext4 with no partition table, which a
# BIOS bootloader cannot boot from. So we build a second image that has a real MBR
# and one bootable partition, copy the system across, and install GRUB into it.
#
# GRUB is installed by chrooting into the LFS system and using the grub that LFS
# itself built in chapter 8 -- not the Debian host's -- so the boot chain is the
# system's own.
#
# Run as root:  bash 08-make-bootable-image.sh [size]
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
IMG=${DISK_IMG:-/lfs-disk.img}
SIZE=${1:-12G}
MNT=/mnt/target
ROOTPW=${ROOTPW:-lfs}
HOSTNAME=${HOSTNAME_LFS:-bastion}
ADMINUSER=${ADMINUSER:-admin}

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
[ -x "$LFS/usr/sbin/grub-install" ] || { echo "FATAL: grub not found in the LFS tree"; exit 1; }

cleanup() {
    set +e
    umount "$LFS/mnt/target" 2>/dev/null
    umount "$MNT" 2>/dev/null
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "==> Creating $SIZE image at $IMG with an MBR partition table"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
sfdisk --quiet "$IMG" <<'EOF'
label: dos
start=2048, type=83, bootable
EOF

echo "==> Attaching loop device with partition scanning"
LOOP=$(losetup --show -fP "$IMG")
echo "    $LOOP -> ${LOOP}p1"
mkfs.ext4 -q -L LFSROOT "${LOOP}p1"

mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"

echo "==> Copying the LFS system (excluding build scaffolding)"
rsync -aHAX --numeric-ids --info=stats2 \
    --exclude='/sources/***' \
    --exclude='/jhalfs/***'  \
    --exclude='/tools/***'   \
    --exclude='/dev/***' --exclude='/proc/***' \
    --exclude='/sys/***' --exclude='/run/***'  \
    "$LFS/" "$MNT/"
mkdir -p "$MNT"/{dev,proc,sys,run,tmp}
chmod 1777 "$MNT/tmp"

KERNEL=$(cd "$MNT/boot" && ls vmlinuz-* 2>/dev/null | head -1)
[ -n "$KERNEL" ] || { echo "FATAL: no kernel in /boot"; exit 1; }
echo "==> Kernel: $KERNEL"

echo "==> Installing GRUB using the LFS system's own grub"
mkdir -p "$LFS/mnt/target"
mount --bind "$MNT" "$LFS/mnt/target"
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"

chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" \
    PATH=/usr/bin:/usr/sbin \
    grub-install --target=i386-pc --boot-directory=/mnt/target/boot \
                 --modules="part_msdos ext2 biosdisk" "$LOOP"

umount "$LFS/mnt/target"

echo "==> Writing grub.cfg"
# console=tty0 keeps the VGA console working; console=ttyS0 lets a headless QEMU
# run show the whole boot on stdout.
cat > "$MNT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3

insmod part_msdos
insmod ext2

menuentry "BastionOS (LFS 13.0 SysV), Linux $KERNEL" {
    set root=(hd0,msdos1)
    linux /boot/$KERNEL root=/dev/sda1 ro console=tty0 console=ttyS0,115200 net.ifnames=0 lockdown=integrity
}
EOF
# lockdown=integrity activates the lockdown LSM: it blocks the interfaces that let root
# modify the running kernel (raw device writes, unsigned module loads, kexec). It is set
# on the command line rather than compiled as "force" so it can be turned off for
# debugging by editing this line.
# net.ifnames=0 disables udev's predictable interface naming. LFS' chapter 9 network
# config is written for "eth0", but udev would name the NIC enp0s3 or similar, so the
# network bootscript fails at boot with "Interface eth0 doesn't exist".

# jhalfs substitutes our fstab but leaves chapter 9's hostname/hosts as literal
# "**EDITME**" placeholders, which show up in the shell prompt, uname and logs.
echo "==> Setting hostname to '$HOSTNAME'"
echo "$HOSTNAME" > "$MNT/etc/hostname"
# No static address here: eth0 uses DHCP, so the IP is not known ahead of time.
cat > "$MNT/etc/hosts" <<EOF
# Begin /etc/hosts

127.0.0.1 localhost.localdomain localhost
127.0.1.1 $HOSTNAME.local $HOSTNAME
::1       localhost ip6-localhost ip6-loopback
ff02::1   ip6-allnodes
ff02::2   ip6-allrouters

# End /etc/hosts
EOF
if grep -rq 'EDITME' "$MNT/etc" 2>/dev/null; then
    echo "ERROR: EDITME placeholders still present:"; grep -rl 'EDITME' "$MNT/etc"; exit 1
else
    echo "OK:    no EDITME placeholders remain in /etc"
fi

echo "==> Adding a serial getty so the system is reachable headlessly"
# LFS labels its gettys 1..6 (not c1..c6), so anchor on the end marker instead.
if ! grep -q ttyS0 "$MNT/etc/inittab"; then
    sed -i '/^# End \/etc\/inittab/i s0:2345:respawn:/sbin/agetty -L ttyS0 115200 vt100' \
        "$MNT/etc/inittab"
fi
grep -q '^s0:.*ttyS0' "$MNT/etc/inittab" \
    && echo "OK:    serial getty present" \
    || { echo "ERROR: failed to add serial getty"; exit 1; }

# LFS leaves root's shadow password field as a literal "x", which is not a valid
# hash -- no password matches it, so the account cannot be logged into at all.
# Install a real hash or the finished system is unusable.
echo "==> Setting the root password"
HASH=$(openssl passwd -6 "$ROOTPW")
sed -i "s|^root:[^:]*:|root:$HASH:|" "$MNT/etc/shadow"
if grep -q '^root:\$6\$' "$MNT/etc/shadow"; then
    echo "OK:    root password hash installed"
else
    echo "ERROR: root password not set"; exit 1
fi

# Root SSH login is disabled (BLFS default), so remote access goes through the admin
# account. Installing the host's public key makes that non-interactive and lets the
# boot test actually log in over the network.
if [ -d "$MNT/home/$ADMINUSER" ]; then
    echo "==> Installing host SSH key for '$ADMINUSER'"
    [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
    install -d -m700 -o 1000 -g 1000 "$MNT/home/$ADMINUSER/.ssh"
    install -m600 -o 1000 -g 1000 /root/.ssh/id_ed25519.pub \
        "$MNT/home/$ADMINUSER/.ssh/authorized_keys"
    echo "OK:    authorized_keys installed"
else
    echo "    (no $ADMINUSER home yet - run 11-blfs-build.sh for SSH access)"
fi

echo "==> Verifying essentials are present"
for f in /sbin/init /bin/bash /etc/fstab /boot/grub/grub.cfg "/boot/$KERNEL"; do
    if [ -e "$MNT$f" ]; then echo "OK:    $f"; else echo "ERROR: $f MISSING"; fi
done
echo "installed size: $(du -sh --exclude=lost+found "$MNT" | cut -f1)"

sync
echo
echo "==> Bootable image ready: $IMG"
