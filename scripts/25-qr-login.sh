#!/bin/bash
# Install phone login: scan a QR code on the console, tap approve on the phone.
#
# What goes in:
#   /usr/lib/bastionos/bastion_qr.py    QR encoder, stdlib only
#   /usr/lib/bastionos/bastion_auth.py  device store, TOTP, challenge/response
#   /usr/lib/bastionos/phone.html       the page the phone loads
#   /usr/sbin/bastion-qrauthd           the daemon (runs as the qrauth user)
#   /usr/sbin/bastion-qrlogin           the login program agetty runs on tty1 and tty2
#   /usr/sbin/bastion-qradmin           enrol/revoke, reached through bastionctl
#   /etc/rc.d/init.d/qrauthd            starts the daemon
#
# tty1 and tty2 get the QR login; tty3 to tty6 and the serial console keep the ordinary
# password prompt. That split is deliberate. If bastion-qrlogin ever fails to start,
# agetty respawns it in a loop and those ttys are useless, so at least half the console
# is left on a mechanism with no new moving parts.
#
# Run as root, after 19-firstboot.sh:  bash 25-qr-login.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPTS/qrauth"

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

for f in bastion_qr.py bastion_auth.py phone.html bastion-qrauthd bastion-qrlogin \
         bastion-qradmin; do
    [ -f "$SRC/$f" ] || { echo "FATAL: missing $SRC/$f"; exit 1; }
done

# The login path is Python. If the image has no interpreter the console is bricked, so
# check before changing inittab rather than after.
[ -x "$LFS/usr/bin/python3" ] || { echo "FATAL: no python3 in the image"; exit 1; }
[ -x "$LFS/usr/bin/login" ] || [ -x "$LFS/bin/login" ] \
    || { echo "FATAL: no login(1) in the image"; exit 1; }

echo "==> Creating the qrauth service account"
# The daemon is the only network-facing part, so it does not run as root. It still
# decides who may log in, so this is not a security boundary against a compromise of
# the daemon itself -- it is one against a bug in its HTTP parsing becoming root.
if ! grep -q '^qrauth:' "$LFS/etc/group"; then
    echo 'qrauth:x:53:' >> "$LFS/etc/group"
fi
if ! grep -q '^qrauth:' "$LFS/etc/passwd"; then
    echo 'qrauth:x:53:53:BastionOS phone login:/var/lib/bastionos/qrauth:/bin/false' \
        >> "$LFS/etc/passwd"
    echo 'qrauth:*:20000:0:99999:7:::' >> "$LFS/etc/shadow"
fi
grep -q '^qrauth:' "$LFS/etc/passwd" && echo "OK:    qrauth account present"

echo "==> Installing the Python modules and programs"
install -d -m755 "$LFS/usr/lib/bastionos"
install -m644 "$SRC/bastion_qr.py"   "$LFS/usr/lib/bastionos/bastion_qr.py"
install -m644 "$SRC/bastion_auth.py" "$LFS/usr/lib/bastionos/bastion_auth.py"
install -m644 "$SRC/phone.html"      "$LFS/usr/lib/bastionos/phone.html"
install -m755 "$SRC/bastion-qrauthd" "$LFS/usr/sbin/bastion-qrauthd"
install -m755 "$SRC/bastion-qrlogin" "$LFS/usr/sbin/bastion-qrlogin"
install -m755 "$SRC/bastion-qradmin" "$LFS/usr/sbin/bastion-qradmin"

install -d -m700 "$LFS/var/lib/bastionos/qrauth/devices"
chroot "$LFS" /usr/bin/chown -R qrauth:qrauth /var/lib/bastionos/qrauth
install -d -m755 "$LFS/var/log/bastionos"
: > "$LFS/var/log/bastionos/qrauth.log"
chroot "$LFS" /usr/bin/chown qrauth:qrauth /var/log/bastionos/qrauth.log
chmod 640 "$LFS/var/log/bastionos/qrauth.log"

install -d -m755 "$LFS/etc/bastionos"
cat > "$LFS/etc/bastionos/qrauth.conf" <<'EOF'
# BastionOS phone login.
#
# The port is bound only while a login is waiting for approval or an enrolment window
# is open, and closed again the moment nothing is pending. It is not listening most of
# the time.
port = 8043

# The address a phone must use to reach this machine. Leave unset and the machine uses
# its own address, which is right when the phone is on the same network.
#
# Set it when this machine is behind NAT with a port forwarded to it -- most obviously
# a VM under QEMU's user-mode networking, where the machine sees itself as 10.0.2.15
# and the phone has to talk to the host instead. Without this the QR code scans
# perfectly and then cannot connect, which looks like a bug in the phone.
#
#   advertise = 192.168.1.50:8043
#
# The typed-code path ([c] on the login screen) needs none of this: it is plain TOTP
# and involves no connection to this machine at all.
EOF

echo "==> Installing the init script"
cat > "$LFS/etc/rc.d/init.d/qrauthd" <<'EOS'
#!/bin/sh
########################################################################
# Begin qrauthd
#
# Description : Phone login daemon for BastionOS
#
# Version     : BastionOS 1.5
#
########################################################################

### BEGIN INIT INFO
# Provides:            qrauthd
# Required-Start:      $local_fs $network
# Should-Start:
# Required-Stop:       $local_fs
# Should-Stop:
# Default-Start:       2 3 4 5
# Default-Stop:        0 1 6
# Short-Description:   Phone login daemon.
# Description:         Serves the approval page and verifies phone responses.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO

. /lib/lsb/init-functions

# Deliberately prefixed. init-functions owns a pile of unprefixed globals and will
# happily overwrite anything of its own name that a caller defines.
BASTION_QRAUTH_RUN=/run/bastionos
BASTION_QRAUTH_PID=$BASTION_QRAUTH_RUN/qrauthd.pid
BASTION_QRAUTH_SOCK=$BASTION_QRAUTH_RUN/qrauth.sock
BASTION_QRAUTH_LOG=/var/log/bastionos/qrauth.log

case "$1" in
    start)
        log_info_msg "Starting the phone login daemon..."
        # /run is a tmpfs, so this is gone after every boot and has to be remade.
        # Creating it is the one part that needs root; the daemon drops to the
        # qrauth user itself and then everything it touches is its own.
        #
        # 755, not 750: an ordinary user has to be able to reach the socket to ask
        # which phones can log in as them. The daemon decides what each caller may do
        # from the kernel-reported peer uid, so the directory mode is not the control.
        install -d -m755 -o qrauth -g qrauth "$BASTION_QRAUTH_RUN"
        install -d -m755 /var/log/bastionos
        [ -e "$BASTION_QRAUTH_LOG" ] || {
            : > "$BASTION_QRAUTH_LOG"
            chown qrauth:qrauth "$BASTION_QRAUTH_LOG"
            chmod 640 "$BASTION_QRAUTH_LOG"
        }
        rm -f "$BASTION_QRAUTH_SOCK"
        /usr/sbin/bastion-qrauthd --user qrauth --daemonize \
            --pidfile "$BASTION_QRAUTH_PID" --log "$BASTION_QRAUTH_LOG"
        # Report success only once the socket is actually there. Without this the
        # script prints OK whenever the fork succeeded, which it does even when the
        # daemon dies immediately afterwards -- and then the only symptom is that
        # tty1 quietly shows a password prompt instead of a code.
        i=0
        while [ ! -S "$BASTION_QRAUTH_SOCK" ] && [ $i -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done
        [ -S "$BASTION_QRAUTH_SOCK" ]
        evaluate_retval
        ;;

    stop)
        log_info_msg "Stopping the phone login daemon..."
        killproc -p "$BASTION_QRAUTH_PID" /usr/sbin/bastion-qrauthd
        evaluate_retval
        ;;

    restart)
        $0 stop
        sleep 1
        $0 start
        ;;

    status)
        statusproc -p "$BASTION_QRAUTH_PID" /usr/sbin/bastion-qrauthd
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

# End qrauthd
EOS
chmod 754 "$LFS/etc/rc.d/init.d/qrauthd"

# After the network is up (S20 dhcpcd territory) but before the gettys matter.
ln -sfn ../init.d/qrauthd "$LFS/etc/rc.d/rc2.d/S48qrauthd"
ln -sfn ../init.d/qrauthd "$LFS/etc/rc.d/rc3.d/S48qrauthd"
ln -sfn ../init.d/qrauthd "$LFS/etc/rc.d/rc4.d/S48qrauthd"
ln -sfn ../init.d/qrauthd "$LFS/etc/rc.d/rc5.d/S48qrauthd"
for d in 0 1 6; do
    ln -sfn ../init.d/qrauthd "$LFS/etc/rc.d/rc$d.d/K22qrauthd"
done
echo "OK:    qrauthd will start in runlevels 2-5"

echo "==> Pointing tty1 and tty2 at the QR login"
INITTAB="$LFS/etc/inittab"
cp "$INITTAB" "$INITTAB.pre-qrauth"
for n in 1 2; do
    # LFS labels these lines "1:2345:respawn:/sbin/agetty --noclear tty1 9600".
    # -n stops agetty prompting for a name; -l points it at our program.
    sed -i "s|^$n:2345:respawn:/sbin/agetty .*|$n:2345:respawn:/sbin/agetty -n -l /usr/sbin/bastion-qrlogin --noclear tty$n linux|" \
        "$INITTAB"
done
changed=$(grep -c 'bastion-qrlogin' "$INITTAB" || true)
[ "$changed" = 2 ] || {
    echo "ERROR: expected to rewrite 2 getty lines, rewrote $changed"
    echo "       inittab left as-is at $INITTAB.pre-qrauth"
    cp "$INITTAB.pre-qrauth" "$INITTAB"
    exit 1
}
grep -q '^3:2345:respawn:/sbin/agetty' "$INITTAB" \
    && echo "OK:    tty1/tty2 use phone login, tty3-tty6 keep the password prompt" \
    || { echo "ERROR: no plain getty left; refusing to lock the console"; \
         cp "$INITTAB.pre-qrauth" "$INITTAB"; exit 1; }

echo "==> Opening the firewall for the approval page"
NFT="$LFS/etc/nftables.conf"
if [ -f "$NFT" ]; then
    if ! grep -q 'qrauth' "$NFT"; then
        # Private source ranges only. If this machine is on a public address, a phone
        # on the far side of the internet cannot reach a port that is shut except for
        # ninety seconds at a time anyway, and exposing it would be the wrong trade.
        sed -i '/comment "ssh"/a\        ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 8043 ct state new accept comment "qrauth"' \
            "$NFT"
    fi
    grep -q 'qrauth' "$NFT" && echo "OK:    nftables allows 8043 from private ranges" \
        || { echo "ERROR: failed to add the firewall rule"; exit 1; }
else
    echo "WARN:  no $NFT; run 13-firewall.sh first if you want the rule"
fi

echo "==> Refreshing bastionctl and security-audit"
# Both gained phone-login awareness, and both were installed by earlier scripts. An
# earlier release shipped a security-audit that had been edited after it was installed,
# so the audit in the image was missing a whole section and cheerfully reported no
# failures. Reinstall them here rather than assume.
install -m755 "$SCRIPTS/bastionctl.sh" "$LFS/usr/sbin/bastionctl"
install -m755 "$SCRIPTS/security-audit.sh" "$LFS/usr/sbin/security-audit"

echo
echo "Installed. On the booted machine:"
echo "    bastionctl register alice        enrol a phone for 'alice'"
echo "    bastionctl devices               list enrolled phones"
echo "    bastionctl revoke <device-id>    remove one"
echo
echo "tty1 and tty2 now show a QR code instead of a password prompt."
echo "tty3 to tty6 and the serial console are unchanged."
