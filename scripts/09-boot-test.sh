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

ck 'Linux version'                "$LOG"    'kernel booted'
ck 'Freeing unused kernel image'  "$LOG"    'kernel handed off to userland'
ck 'login:'                       "$LOG"    'reached a login prompt'
ck 'Starting SSH Server|sshd'     "$LOG"    'sshd started at boot'
[ "$up" = 1 ] && echo "OK:    sshd accepted a TCP connection" || { echo "ERROR: sshd unreachable"; fail=1; }
ck '^lfs$'                        "$SSHLOG" 'logged in over SSH (hostname)'
ck 'groups=.*wheel'               "$SSHLOG" 'admin is in the wheel group'
ck 'inet 10\.0\.2\.[0-9]+'        "$SSHLOG" 'eth0 got an address from DHCP'
ck '2 (packets )?received|2 received' "$SSHLOG" 'ping works (iputils)'
ck 'HTTP/[12perf.]* 200'          "$SSHLOG" 'HTTPS fetch succeeded (curl + trust store)'
ck 'uid=0\(root\)'                "$SSHLOG" 'sudo escalates to root'
ck 'Unmounting all other'         "$LOG"    'clean shutdown'

echo
[ "$fail" = 0 ] && echo "RESULT: the system is administrable - SSH, sudo, DNS, ping and TLS all work." \
                || echo "RESULT: some checks failed; inspect $LOG and $SSHLOG"
exit $fail
