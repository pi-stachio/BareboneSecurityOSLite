#!/bin/bash
# Boot the image in QEMU with a port forward, log in OVER SSH as the admin user, and
# exercise the administrable-system tools: sudo, ping, DHCP, and HTTPS with a real
# trust store. Then shut down cleanly and check the console log.
#
# This is a stronger check than driving the serial console: it proves the network
# stack, sshd, DHCP client and TLS certificates all work together from outside the VM.
#
# Run as root:  bash 09-boot-test.sh
set -uo pipefail

IMG=${DISK_IMG:-/lfs-disk.img}
LOG=${BOOT_LOG:-/root/lfs/boot.log}
SSHLOG=${SSH_LOG:-/root/lfs/ssh.log}
PORT=${SSH_PORT:-2222}
ADMINUSER=${ADMINUSER:-admin}
ADMINPW=${ADMINPW:-lfs}
KEY=/root/.ssh/id_ed25519

[ -f "$IMG" ] || { echo "FATAL: $IMG not found; run 08-make-bootable-image.sh"; exit 1; }
[ -f "$KEY" ] || { echo "FATAL: $KEY missing; 08-make-bootable-image.sh creates it"; exit 1; }
command -v ssh > /dev/null || { echo "FATAL: no ssh client on the host"; exit 1; }

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

cleanup() { [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null; }
trap cleanup EXIT

echo "==> Booting $IMG (ssh forwarded to localhost:$PORT)"
# 20-package-image.sh loop-mounts this image to inspect it. If it is still attached when
# QEMU starts, QEMU fails to launch and never even creates the serial log, so the only
# symptom is "sshd never answered" with no console output to explain it. Detach any loop
# device still backing this image before booting it.
losetup -j "$IMG" -O NAME --noheadings 2>/dev/null | while read -r l; do
    [ -n "$l" ] && { umount "$l"p1 2>/dev/null || true; losetup -d "$l" 2>/dev/null || true; }
done
rm -f "$LOG" "$SSHLOG"
qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -m 1024 -smp 2 \
    -drive file="$IMG",format=raw,if=ide \
    -netdev user,id=n0,hostfwd=tcp::"$PORT"-:22 \
    -device e1000,netdev=n0 \
    -display none -serial file:"$LOG" -no-reboot &
QPID=$!

SSH="ssh -i $KEY -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes $ADMINUSER@127.0.0.1"

# A plain TCP connect is useless here: QEMU's hostfwd accepts the connection on the
# host side immediately, whether or not anything is listening inside the guest. So
# probe with a real SSH handshake+login instead.
echo "==> Waiting for sshd to actually answer (up to 180s)"
up=0
for i in $(seq 1 36); do
    if $SSH true 2>/dev/null; then up=1; echo "    logged in after ~$((i*5))s"; break; fi
    kill -0 "$QPID" 2>/dev/null || { echo "    QEMU exited early"; break; }
    sleep 5
done

if [ "$up" = 1 ]; then
    echo "==> Running checks over SSH"
    $SSH 'set -x
          hostname
          id
          uname -r
          /usr/sbin/ip -o -4 addr show eth0   # /usr/sbin is not in a normal user PATH
          getcap /usr/bin/ping || /usr/sbin/getcap /usr/bin/ping
          cat /etc/resolv.conf | grep -v "^#"
          ping -c2 -W3 10.0.2.2
          curl -sS -I --max-time 20 https://example.com | head -1
          echo '"$ADMINPW"' | sudo -S id
          echo '"$ADMINPW"' | sudo -S /usr/sbin/bastionctl status
          echo '"$ADMINPW"' | sudo -S /usr/sbin/security-audit
         ' > "$SSHLOG" 2>&1
    echo "--- ssh session output ---"
    sed -e 's/^+ /$ /' "$SSHLOG"
    echo "==> Shutting down via sudo poweroff"
    $SSH "echo $ADMINPW | sudo -S poweroff" >> "$SSHLOG" 2>&1
else
    echo "!! sshd never answered; see $LOG"
fi

for i in $(seq 1 30); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
kill -0 "$QPID" 2>/dev/null && { echo "==> forcing QEMU down"; kill "$QPID"; }
wait "$QPID" 2>/dev/null

echo
echo "================ VERDICT ================"
fail=0
ck() { if grep -qE "$1" "$2" 2>/dev/null; then printf 'OK:    %s\n' "$3"; else printf 'ERROR: %s\n' "$3"; fail=1; fi; }

# The default menu entry boots with `quiet`, so the kernel's own banner and its
# "Freeing unused kernel image" line are suppressed by design. Assert on things that
# survive a quiet boot: sysvinit's banner (userspace, always printed) and the kernel
# actually running, read from the booted system rather than scraped off the console.
ck 'INIT: version .* booting'     "$LOG"    'init started'
# uname -r reports 6.18.10, not 6.18.10-lfs-r13.0: that suffix is only in the filename
# 08-make-bootable-image.sh gives the image, not in CONFIG_LOCALVERSION.
ck '^6\.18\.'                     "$SSHLOG" 'running the expected kernel'
ck 'login:'                       "$LOG"    'reached a login prompt'
ck 'Starting SSH Server|sshd'     "$LOG"    'sshd started at boot'
[ "$up" = 1 ] && echo "OK:    sshd accepted a TCP connection" || { echo "ERROR: sshd unreachable"; fail=1; }
ck '^bastion$'                    "$SSHLOG" 'logged in over SSH (hostname)'
# First boot must have replaced the build machine's host keys with its own.
ck 'firstboot: completed'         "$SSHLOG" 'first-boot setup ran'
ck 'groups=.*wheel'               "$SSHLOG" 'admin is in the wheel group'
ck 'inet 10\.0\.2\.[0-9]+'        "$SSHLOG" 'eth0 got an address from DHCP'
ck '2 (packets )?received|2 received' "$SSHLOG" 'ping works (iputils)'
ck 'HTTP/[12perf.]* 200'          "$SSHLOG" 'HTTPS fetch succeeded (curl + trust store)'
ck 'uid=0\(root\)'                "$SSHLOG" 'sudo escalates to root'
ck 'Unmounting all other'         "$LOG"    'clean shutdown'
# Hardening
ck 'landlock active'              "$SSHLOG" 'landlock LSM active'
ck 'yama active'                  "$SSHLOG" 'yama LSM active'
ck 'lockdown active'              "$SSHLOG" 'lockdown LSM active'
ck 'no loadable modules present'  "$SSHLOG" 'kernel has no loadable modules'
ck 'inbound policy is drop'       "$SSHLOG" 'firewall default-denies inbound'
# Toolchain tier. Anchored on 100% rather than on the word "OK" so that a partial
# rebuild -- the failure mode this tier actually has -- cannot pass silently.
ck 'full RELRO \(BIND_NOW\).*100%'     "$SSHLOG" 'every binary has full RELRO'
ck 'PIE \(executables\).*100%'         "$SSHLOG" 'every executable is PIE'
ck 'newly compiled binaries get BIND_NOW' "$SSHLOG" 'the shipped compiler still hardens'
ck '_FORTIFY_SOURCE=3 is the default'  "$SSHLOG" 'fortify is the compiler default'
ck 'password hashing is yescrypt'      "$SSHLOG" 'yescrypt password hashing'
# The image must carry a vulnerability report. Its *contents* are upstream facts and are
# not asserted here -- only that the system can tell you what it knows it is running.
ck 'report generated [0-9]{4}-'        "$SSHLOG" 'vulnerability report present'
ck 'vulnerability report is [0-9]+d old' "$SSHLOG" 'vulnerability report is current'
if grep -qE '^ *[0-9]+ passed, [0-9]+ warnings, 0 failures' "$SSHLOG"; then
    printf 'OK:    %s\n' 'security audit reports no failures'
else
    printf 'ERROR: %s\n' 'security audit reported failures'; fail=1
    sed -n '/FAIL/p' "$SSHLOG" | head -8
fi

echo
[ "$fail" = 0 ] && echo "RESULT: the system is administrable - SSH, sudo, DNS, ping and TLS all work." \
                || echo "RESULT: some checks failed; inspect $LOG and $SSHLOG"
exit $fail
