#!/bin/bash
# Install the first-boot service.
#
# This exists because of a real defect in every image up to v1.3.1: SSH host keys were
# generated on the build machine and baked into the image, so every download shared the
# same host identity. Host-key verification is the mechanism that detects a
# man-in-the-middle, and it is worth nothing if the key is public and identical
# everywhere. The keys have to be generated on the machine that will use them.
#
# While we are running code on first boot anyway, it also grows the root filesystem to
# fill whatever disk it was given -- a 12 GB image on a 100 GB disk otherwise wastes 88 GB
# and there is no obvious moment for a user to notice or fix that.
#
# Run as root:  bash 19-firstboot.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

# Look in both bin and sbin rather than hardcoding: util-linux splits its tools between
# them in ways that are not obvious (findmnt and lsblk in bin, sfdisk and partx in sbin).
for t in ssh-keygen resize2fs sfdisk partx findmnt lsblk; do
    [ -e "$LFS/usr/bin/$t" ] || [ -e "$LFS/usr/sbin/$t" ] \
        || { echo "FATAL: firstboot needs $t and it is not in the image"; exit 1; }
done

echo "==> Installing /etc/rc.d/init.d/firstboot"
cat > "$LFS/etc/rc.d/init.d/firstboot" <<'EOS'
#!/bin/sh
########################################################################
# Begin firstboot
#
# Description : One-time setup the first time this image is booted
#
# Version     : BastionOS 1.4
#
########################################################################

### BEGIN INIT INFO
# Provides:            firstboot
# Required-Start:      $local_fs
# Should-Start:
# Required-Stop:
# Should-Stop:
# Default-Start:       S
# Default-Stop:
# Short-Description:   One-time first boot setup.
# Description:         Generates SSH host keys and grows the root filesystem.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO

. /lib/lsb/init-functions

# Deliberately not called STAMP.
#
# /lib/lsb/init-functions assigns a variable of that name inside log_info_msg for its
# log timestamps, and it is not declared local -- so it silently overwrites a caller's
# variable of the same name. The redirect then writes to a file literally called
# "Aug 14 14:24:57 +00:00 bastion " in /, the marker never appears where it is looked
# for, and first boot repeats on every single boot: fresh SSH host keys each time, and
# a host whose fingerprints change constantly. It fails without one error message.
#
# init-functions also owns BOOTLOG, BRACKET, COL, INFO, NORMAL, SCRIPT_STAT, SUCCESS,
# FAILURE, WARNING and their *_PREFIX/_SUFFIX forms. Prefix anything you define.
BASTION_FB_STAMP=/var/lib/bastionos/firstboot-done

case "$1" in
    start)
        [ -e "$BASTION_FB_STAMP" ] && exit 0

        # ---- SSH host identity -------------------------------------------------
        # Generated here, not on the build machine. Every image otherwise ships the
        # same host keys and nobody can tell a real host from an impostor.
        log_info_msg "Generating SSH host keys for this machine..."
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A > /dev/null 2>&1
        evaluate_retval

        # ---- Root filesystem ---------------------------------------------------
        # Grow the partition, then the filesystem, to fill the disk actually attached.
        # Every step is allowed to fail without taking the boot down with it: a system
        # that will not boot is a far worse outcome than one that did not grow.
        log_info_msg "Growing the root filesystem..."
        (
            root_src=$(findmnt -no SOURCE / 2>/dev/null) || exit 0
            case "$root_src" in /dev/*) ;; *) exit 0 ;; esac
            disk=$(lsblk -npo PKNAME "$root_src" 2>/dev/null | head -1)
            part=$(echo "$root_src" | sed 's/.*[^0-9]\([0-9]*\)$/\1/')
            [ -n "$disk" ] && [ -n "$part" ] || exit 0
            echo ',+' | sfdisk -N "$part" --no-reread --force "$disk" > /dev/null 2>&1 || true
            partx -u "$disk" > /dev/null 2>&1 || true
            resize2fs "$root_src" > /dev/null 2>&1 || true
        ) || true
        evaluate_retval

        mkdir -p /var/lib/bastionos
        date -u +%Y-%m-%dT%H:%M:%SZ > "$BASTION_FB_STAMP"

        # ---- Tell the operator what the host identity now is -------------------
        # Printed once, on the console, so the fingerprint can be compared against
        # what ssh shows on first connection.
        echo ""
        echo "  This machine's SSH host key fingerprints:"
        for k in /etc/ssh/ssh_host_*_key.pub; do
            [ -e "$k" ] || continue
            echo "    $(ssh-keygen -lf "$k" 2>/dev/null)"
        done
        echo ""
        ;;

    status)
        if [ -e "$BASTION_FB_STAMP" ]; then
            echo "first boot setup completed $(cat "$BASTION_FB_STAMP")"
        else
            echo "first boot setup has not run"
        fi
        ;;

    *)
        echo "Usage: ${0##*/} {start|status}"
        exit 1
        ;;
esac
EOS
chmod 754 "$LFS/etc/rc.d/init.d/firstboot"

# After S40mountfs (root must be writable to generate keys or resize) and before
# anything in runlevel 3, so sshd never starts on build-machine keys.
ln -sfnv ../init.d/firstboot "$LFS/etc/rc.d/rcS.d/S46firstboot" > /dev/null
echo "    linked as rcS.d/S46firstboot (after S45cleanfs, before runlevel 3)"

echo "==> Installing the motd generator"
cat > "$LFS/etc/rc.d/init.d/motd" <<'EOS'
#!/bin/sh
### BEGIN INIT INFO
# Provides:            motd
# Required-Start:      $local_fs
# Default-Start:       S
# Short-Description:   Regenerates /etc/motd with current system state.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO

. /lib/lsb/init-functions

case "$1" in
    start)
        {
            echo ""
            echo "  BastionOS  --  Linux From Scratch 13.0, hardened"
            echo "  $(uname -srm)"
            echo ""
            if [ -r /etc/bastionos/vuln-report.txt ]; then
                sum=$(grep -m1 '^SUMMARY' /etc/bastionos/vuln-report.txt)
                gen=$(awk '/^# generated:/{print $3}' /etc/bastionos/vuln-report.txt)
                echo "  Known advisories against installed packages (as of $gen):"
                echo "    $(echo "$sum" | sed 's/^SUMMARY //')"
                echo "    details: security-audit    refresh: vuln-scan"
            fi
            echo ""
            if [ ! -s /home/admin/.ssh/authorized_keys ]; then
                echo "  SSH is key-only and no key is installed yet, so remote login"
                echo "  will refuse you. From this console, run:"
                echo ""
                echo "    bastionctl add-key 'ssh-ed25519 AAAA... you@host'"
                echo ""
            fi
        } > /etc/motd 2>/dev/null || true
        ;;
esac
EOS
chmod 754 "$LFS/etc/rc.d/init.d/motd"
ln -sfnv ../init.d/motd "$LFS/etc/rc.d/rcS.d/S47motd" > /dev/null
echo "    linked as rcS.d/S47motd"

echo "==> Installing /usr/sbin/bastionctl"
install -m755 "$(dirname "$0")/bastionctl.sh" "$LFS/usr/sbin/bastionctl"
sed -i 's/\r$//' "$LFS/usr/sbin/bastionctl"

echo
echo "==> Clearing build-machine state so first boot regenerates it"
# Any host keys sitting here came from the build host and must not ship.
rm -fv "$LFS"/etc/ssh/ssh_host_* 2>/dev/null | sed 's/^/    /' || true
rm -f "$LFS/var/lib/bastionos/firstboot-done"
echo "    host keys cleared; firstboot marker cleared"

echo
echo "==> Done. Re-run 08-make-bootable-image.sh to fold this in."
