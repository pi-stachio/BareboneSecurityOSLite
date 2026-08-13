#!/bin/bash
# Launch the full LFS build (jhalfs chapters 4-11), detached.
#
# jhalfs imposes two constraints on how it may be invoked:
#   1. it refuses to run as root, and drives privileged steps via sudo, so we need an
#      unprivileged driver account with passwordless sudo;
#   2. it checks `stty size` for a >=80x24 terminal, so it must run under a pty --
#      a plain detached pipe reports no size and fails. `script` supplies the pty.
#
# Run as root:  bash 07-run-build.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
# Must live somewhere the unprivileged driver account can write; /root is 0700.
LOG=$LFS/jhalfs/build.log

# jhalfs insists on creating the LFS build user itself and aborts if it already exists.
# Do not mask failures here: a lingering process owned by the user makes userdel fail,
# and silently continuing just moves the error to the middle of the build.
if id lfs &> /dev/null; then
    echo "==> Removing pre-existing lfs user (jhalfs must create it)"
    pkill -9 -u lfs 2>/dev/null || true
    sleep 1
    userdel -r lfs || { echo "FATAL: could not remove user lfs"; exit 1; }
fi
getent group lfs > /dev/null && groupdel lfs || true
rm -rf /home/lfs

# Keep the previous attempt's log; `script` truncates its output file.
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.$(date +%H%M%S)"

if ! id builder &> /dev/null; then
    echo "==> Creating unprivileged driver account 'builder'"
    useradd -m -s /bin/bash builder
fi
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

echo "==> Giving builder ownership of the jhalfs work dir"
chown -R builder:builder "$LFS/jhalfs"

# A shell backgrounding a job without job control sets SIGINT and SIGQUIT to SIG_IGN,
# and that disposition is inherited by every process in the build. Python refuses to
# install its own SIGINT handler when it inherits SIG_IGN, which makes
# test_generators.SignalAndYieldFromTest fail during Python's PGO training run and
# takes the whole build down. Reset SIGINT to default before exec'ing make.
RUNNER=$LFS/jhalfs/run-make.sh
cat > "$RUNNER" <<EOF
#!/bin/bash
stty rows 50 cols 200 2>/dev/null
cd $LFS/jhalfs
exec perl -e '\$SIG{INT} = "DEFAULT"; exec @ARGV' make
EOF
chmod +x "$RUNNER"
chown builder:builder "$RUNNER"

echo "==> Launching build"
date > /root/lfs/build.started
setsid nohup sudo -u builder \
    script -qfc "$RUNNER" "$LOG" \
    > /tmp/launch.err 2>&1 < /dev/null &

sleep 25
echo "==> First lines of $LOG:"
head -20 "$LOG" || true
echo
echo "==> make processes running: $(pgrep -c -f 'jhalfs' || echo 0)"
echo "==> Follow with: tail -f $LOG"
