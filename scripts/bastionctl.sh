#!/bin/bash
# bastionctl -- small operator helper for the things a fresh BastionOS needs.
#
# Installed as /usr/sbin/bastionctl. Deliberately thin: every command here is something
# a user would otherwise have to do by hand on the console, in the exact situation where
# they cannot yet get in over SSH to look up how.
set -uo pipefail

ADMIN=${ADMIN:-admin}
AK="/home/$ADMIN/.ssh/authorized_keys"

usage() {
    cat <<EOF
bastionctl -- BastionOS operator helper

  add-key '<ssh public key>'   authorise a key for $ADMIN (SSH is key-only)
  list-keys                    show authorised keys
  remove-key <n>               remove the nth authorised key
  fingerprints                 this machine's SSH host key fingerprints
  status                       hostname, address, uptime, firewall, advisories
  set-hostname <name>          change the hostname (persists across reboot)

SSH here refuses passwords by design, so a key must be added from the console
before remote login will work.
EOF
}

need_root() { [ "$(id -u)" -eq 0 ] || { echo "must be root" >&2; exit 1; }; }

case "${1:-}" in

add-key)
    need_root
    key=${2:-}
    [ -n "$key" ] || { echo "usage: bastionctl add-key '<ssh public key>'" >&2; exit 1; }
    # Validate before installing. A malformed line in authorized_keys is silently
    # ignored by sshd, which looks exactly like a rejected key from the client side
    # and is miserable to debug from a console.
    tmp=$(mktemp)
    printf '%s\n' "$key" > "$tmp"
    if ! ssh-keygen -lf "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        echo "that does not parse as an SSH public key" >&2
        echo "expected something like: ssh-ed25519 AAAAC3Nz... you@host" >&2
        exit 1
    fi
    fp=$(ssh-keygen -lf "$tmp"); rm -f "$tmp"
    install -d -m700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.ssh"
    if [ -f "$AK" ] && grep -qxF "$key" "$AK"; then
        echo "already authorised: $fp"
        exit 0
    fi
    printf '%s\n' "$key" >> "$AK"
    chown "$ADMIN:$ADMIN" "$AK"; chmod 600 "$AK"
    echo "authorised for $ADMIN: $fp"
    echo "you can now: ssh $ADMIN@<this host>"
    ;;

list-keys)
    [ -s "$AK" ] || { echo "no keys authorised for $ADMIN"; exit 0; }
    n=0
    while read -r line; do
        [ -n "$line" ] || continue
        n=$((n+1))
        printf '%2d  %s\n' "$n" "$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null || echo "$line")"
    done < "$AK"
    ;;

remove-key)
    need_root
    n=${2:-}
    [ -n "$n" ] || { echo "usage: bastionctl remove-key <n>   (see list-keys)" >&2; exit 1; }
    [ -s "$AK" ] || { echo "no keys to remove"; exit 1; }
    sed -i "${n}d" "$AK" && echo "removed key $n"
    ;;

fingerprints)
    for k in /etc/ssh/ssh_host_*_key.pub; do
        [ -e "$k" ] || continue
        ssh-keygen -lf "$k"
    done
    ;;

set-hostname)
    need_root
    h=${2:-}
    [ -n "$h" ] || { echo "usage: bastionctl set-hostname <name>" >&2; exit 1; }
    echo "$h" > /etc/hostname
    hostname "$h"
    sed -i "s/^\(127\.0\.1\.1[[:space:]]\+\).*/\1$h/" /etc/hosts 2>/dev/null || true
    grep -q "^127.0.1.1" /etc/hosts || echo "127.0.1.1 $h" >> /etc/hosts
    echo "hostname is now $h"
    ;;

status)
    echo "host:      $(hostname)"
    echo "kernel:    $(uname -sr)"
    echo "uptime:   $(uptime | sed 's/^ *//')"
    addr=$(/usr/sbin/ip -o -4 addr show scope global 2>/dev/null \
           | awk '{print $2": "$4}' | paste -sd', ' -)
    echo "network:   ${addr:-no global address}"
    if command -v nft > /dev/null 2>&1; then
        pol=$(nft list ruleset 2>/dev/null | awk '/hook input/{print $NF}' | tr -d ';')
        echo "firewall:  inbound policy ${pol:-unknown}"
    fi
    if [ -s "$AK" ]; then
        echo "ssh keys:  $(grep -c . "$AK") authorised for $ADMIN"
    else
        echo "ssh keys:  none -- remote login will refuse you (bastionctl add-key)"
    fi
    if [ -r /etc/bastionos/vuln-report.txt ]; then
        echo "advisories: $(grep -m1 '^SUMMARY' /etc/bastionos/vuln-report.txt | sed 's/^SUMMARY //')"
        echo "            as of $(awk '/^# generated:/{print $3}' /etc/bastionos/vuln-report.txt)"
    fi
    if [ -e /var/lib/bastionos/firstboot-done ]; then
        echo "firstboot: completed $(cat /var/lib/bastionos/firstboot-done)"
    else
        echo "firstboot: has not run"
    fi
    ;;

-h|--help|help|"") usage ;;
*) echo "unknown command: $1" >&2; echo; usage; exit 1 ;;
esac
