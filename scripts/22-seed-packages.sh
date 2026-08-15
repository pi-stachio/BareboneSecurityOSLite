#!/bin/bash
# Build the first bpkg packages, and fix two real gaps while proving the tool works.
#
#   chrony            The system has no time sync at all. A drifting clock silently
#                     breaks TLS -- certificates are "not yet valid" or "expired" -- and
#                     makes every log timestamp and every advisory date untrustworthy.
#   dcron             Nothing runs periodically, so nothing can maintain the system.
#   bastion-logrotate sysklogd writes to /var/log without bound; on a small root
#                     filesystem that is a disk-full waiting to happen, and disk-full on
#                     a logging host means the logs stop exactly when they matter.
#
# Each is staged with DESTDIR, packaged with `bpkg create`, then installed with
# `bpkg install` -- the same path a user would take, so the packaging is exercised
# rather than described. The .bpkg files are kept for release.
#
# Run as root:  bash 22-seed-packages.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
SRC="$LFS/sources/pkg"
PKGOUT="$LFS/sources/packages"

CHRONY_VER=4.7
DCRON_VER=4.5

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
mkdir -p "$SRC" "$PKGOUT"
install -m755 "$SCRIPTS/bpkg.sh" "$LFS/usr/bin/bpkg"
sed -i 's/\r$//' "$LFS/usr/bin/bpkg"

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

fetch() { # url file
    [ -f "$SRC/$2" ] && return 0
    echo "    fetching $2"
    curl -fsSL -o "$SRC/$2" "$1" || { echo "FATAL: could not fetch $1"; exit 1; }
}

run_in() { chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" \
                PATH=/usr/bin:/usr/sbin /bin/bash --login "$@"; }

echo "==> Fetching sources"
fetch "https://chrony-project.org/releases/chrony-$CHRONY_VER.tar.gz" "chrony-$CHRONY_VER.tar.gz"
fetch "https://www.jimpryor.net/linux/releases/dcron-$DCRON_VER.tar.gz" "dcron-$DCRON_VER.tar.gz"

##############################################################################
# chrony
##############################################################################
cat > "$LFS/sources/pkg/build-chrony.sh" <<EOS
#!/bin/bash
set -e
cd /sources/pkg
rm -rf chrony-$CHRONY_VER stage-chrony
tar -xf chrony-$CHRONY_VER.tar.gz
cd chrony-$CHRONY_VER
# chrony's configure is hand-written, not autoconf: it takes no --sysconfdir and rejects
# unknown options, so the paths are set individually.
# libcap is deliberately NOT excluded: without it chronyd is built -PRIVDROP and cannot
# drop privileges at all, which makes running it as -u chrony pointless. libcap is already
# part of the LFS base (chapter 8), so there is nothing to add.
./configure --prefix=/usr           \\
            --sysconfdir=/etc       \\
            --localstatedir=/var    \\
            --without-nettle        \\
            --without-nss           \\
            --without-gnutls        \\
            --without-seccomp
make
make install DESTDIR=/sources/pkg/stage-chrony
# chronyd wants these at runtime and no package owns them otherwise.
install -d -m750 /sources/pkg/stage-chrony/var/lib/chrony
install -d -m755 /sources/pkg/stage-chrony/etc
# Every comment is on its own line. chrony's parser does not accept trailing comments:
# "makestep 1.0 3  # step a badly wrong clock" is read as five arguments to makestep and
# chronyd exits with "Too many arguments for makestep directive" before it ever starts.
cat > /sources/pkg/stage-chrony/etc/chrony.conf <<'CONF'
# BastionOS default chrony configuration.
pool pool.ntp.org iburst

driftfile /var/lib/chrony/drift

# A VM resumed from a snapshot can be wildly wrong; step rather than slew.
makestep 1.0 3

# Keep the hardware clock in step with system time.
rtcsync

# Never act as a server. This is a client-only configuration and the firewall drops
# inbound anyway, but saying so here means it stays true if the firewall changes.
port 0
cmdport 0
CONF
cd /sources/pkg && bpkg create stage-chrony chrony $CHRONY_VER
mv -f chrony-$CHRONY_VER.bpkg /sources/packages/
EOS

echo "==> Building chrony $CHRONY_VER"
run_in /sources/pkg/build-chrony.sh > /tmp/chrony.log 2>&1 \
    || { echo "FATAL: chrony build failed"; tail -25 /tmp/chrony.log; exit 1; }
echo "    packaged"

##############################################################################
# dcron
##############################################################################
cat > "$LFS/sources/pkg/build-dcron.sh" <<EOS
#!/bin/bash
set -e
cd /sources/pkg
rm -rf dcron-$DCRON_VER stage-dcron
tar -xf dcron-$DCRON_VER.tar.gz
cd dcron-$DCRON_VER
sed -i 's/-o root -g root//' Makefile          # install runs as root already
make CC=gcc PREFIX=/usr
install -d /sources/pkg/stage-dcron/usr/sbin /sources/pkg/stage-dcron/usr/bin
install -d -m700 /sources/pkg/stage-dcron/var/spool/cron/crontabs
install -m755 crond    /sources/pkg/stage-dcron/usr/sbin/crond
# crontab ships setuid so ordinary users can edit their own; only root uses cron here,
# so it is installed unprivileged rather than adding an eleventh setuid binary to a
# system that spent a whole release getting down to eight.
install -m755 crontab  /sources/pkg/stage-dcron/usr/bin/crontab
cd /sources/pkg && bpkg create stage-dcron dcron $DCRON_VER
mv -f dcron-$DCRON_VER.bpkg /sources/packages/
EOS

echo "==> Building dcron $DCRON_VER"
run_in /sources/pkg/build-dcron.sh > /tmp/dcron.log 2>&1 \
    || { echo "FATAL: dcron build failed"; tail -25 /tmp/dcron.log; exit 1; }
echo "    packaged"

##############################################################################
# bastion-logrotate -- ours, so no popt dependency for 60 lines of shell
##############################################################################
echo "==> Building bastion-logrotate"
S="$LFS/sources/pkg/stage-logrotate"
rm -rf "$S"
install -d "$S/usr/sbin" "$S/etc/cron.d"

cat > "$S/usr/sbin/bastion-logrotate" <<'EOF'
#!/bin/bash
# Rotate the logs sysklogd writes, keeping a bounded number of generations.
#
# Not GNU logrotate: that needs popt and a config language, and this system rotates four
# files on a fixed schedule. The failure this prevents -- a full root filesystem on a
# host whose job is to keep logs -- does not need a configuration language to prevent.
set -u
KEEP=${KEEP:-4}
MAXSIZE=${MAXSIZE:-1048576}          # rotate once a log passes 1 MiB
LOGS=${LOGS:-"/var/log/sys.log /var/log/auth.log /var/log/daemon.log /var/log/kern.log /var/log/messages"}

rotated=0
for f in $LOGS; do
    [ -f "$f" ] || continue
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ "$size" -ge "$MAXSIZE" ] || continue
    i=$KEEP
    while [ "$i" -gt 1 ]; do
        prev=$((i-1))
        [ -f "$f.$prev.gz" ] && mv -f "$f.$prev.gz" "$f.$i.gz"
        i=$prev
    done
    [ -f "$f.1.gz" ] && mv -f "$f.1.gz" "$f.2.gz"
    cp "$f" "$f.1" && : > "$f"       # copy-truncate: sysklogd keeps its open fd
    gzip -f "$f.1"
    chmod 640 "$f.1.gz" 2>/dev/null || true
    rotated=$((rotated+1))
done

# Tell syslog it happened, so a rotation is visible in the log it just rotated.
[ "$rotated" -gt 0 ] && logger -t bastion-logrotate "rotated $rotated log file(s)" 2>/dev/null
exit 0
EOF
chmod 755 "$S/usr/sbin/bastion-logrotate"

cat > "$S/etc/cron.d/bastion-logrotate" <<'EOF'
# Hourly size check; the script itself decides whether anything needs rotating.
17 * * * * root /usr/sbin/bastion-logrotate
EOF

run_in -c "cd /sources/pkg && bpkg create stage-logrotate bastion-logrotate 1.0 \
           && mv -f bastion-logrotate-1.0.bpkg /sources/packages/" > /dev/null
echo "    packaged"

##############################################################################
# Install them, and wire up the services
##############################################################################
echo
echo "==> Installing the packages"
run_in -c "
    for p in chrony dcron bastion-logrotate; do bpkg remove \$p 2>/dev/null || true; done
    bpkg install /sources/packages/chrony-$CHRONY_VER.bpkg
    bpkg install /sources/packages/dcron-$DCRON_VER.bpkg
    bpkg install /sources/packages/bastion-logrotate-1.0.bpkg
    getent group chrony  > /dev/null || groupadd -g 87 chrony
    getent passwd chrony > /dev/null || useradd -c 'chrony daemon' -d /var/lib/chrony \
                                                -g chrony -s /bin/false -u 87 chrony
    chown -R chrony:chrony /var/lib/chrony
"

echo
echo "==> Installing service scripts"
cat > "$LFS/etc/rc.d/init.d/chronyd" <<'EOS'
#!/bin/sh
### BEGIN INIT INFO
# Provides:            chronyd
# Required-Start:      $network
# Default-Start:       2 3 4 5
# Default-Stop:        0 1 6
# Short-Description:   Network time synchronisation.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO
. /lib/lsb/init-functions
case "$1" in
    start)   log_info_msg "Starting chronyd..."; /usr/sbin/chronyd -u chrony; evaluate_retval ;;
    stop)    log_info_msg "Stopping chronyd..."; killall -q chronyd; evaluate_retval ;;
    restart) $0 stop; sleep 1; $0 start ;;
    status)  /usr/bin/chronyc tracking 2>/dev/null || echo "chronyd is not running" ;;
    *)       echo "Usage: ${0##*/} {start|stop|restart|status}"; exit 1 ;;
esac
EOS
cat > "$LFS/etc/rc.d/init.d/crond" <<'EOS'
#!/bin/sh
### BEGIN INIT INFO
# Provides:            crond
# Required-Start:      $local_fs
# Default-Start:       2 3 4 5
# Default-Stop:        0 1 6
# Short-Description:   Periodic command scheduler.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO
. /lib/lsb/init-functions
case "$1" in
    start)   log_info_msg "Starting crond..."; /usr/sbin/crond -b -l notice; evaluate_retval ;;
    stop)    log_info_msg "Stopping crond..."; killall -q crond; evaluate_retval ;;
    restart) $0 stop; sleep 1; $0 start ;;
    *)       echo "Usage: ${0##*/} {start|stop|restart}"; exit 1 ;;
esac
EOS
chmod 754 "$LFS/etc/rc.d/init.d/chronyd" "$LFS/etc/rc.d/init.d/crond"
for r in 2 3 4 5; do
    ln -sfn ../init.d/chronyd "$LFS/etc/rc.d/rc$r.d/S25chronyd"
    ln -sfn ../init.d/crond   "$LFS/etc/rc.d/rc$r.d/S40crond"
done
for r in 0 1 6; do
    ln -sfn ../init.d/chronyd "$LFS/etc/rc.d/rc$r.d/K35chronyd"
    ln -sfn ../init.d/crond   "$LFS/etc/rc.d/rc$r.d/K20crond"
done
echo "    chronyd at S25 (after network), crond at S40"

echo
echo "==> Packages built"
ls -lh "$PKGOUT"/*.bpkg | awk '{printf "    %-34s %s\n", $9, $5}'
run_in -c "bpkg list" | sed 's/^/    /'

echo
echo "==> Re-run 08-make-bootable-image.sh to fold this in."
