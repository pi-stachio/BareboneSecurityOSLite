#!/bin/bash
# Tier 1 hardening: kernel runtime parameters, sshd policy, password/umask defaults,
# and a SUID audit. No recompiling — all of this is configuration.
#
# Run as root:  bash 14-harden-config.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

echo "==> sysctl hardening"
cat > "$LFS/etc/sysctl.conf" <<'EOF'
# Kernel information leaks ---------------------------------------------------
kernel.dmesg_restrict = 1          # only root reads the kernel ring buffer
kernel.kptr_restrict = 2           # never expose kernel pointers via /proc
kernel.perf_event_paranoid = 3     # no unprivileged perf access
kernel.sysrq = 0                   # no magic SysRq key
# kernel.kexec_load_disabled is deliberately absent: CONFIG_KEXEC is compiled out, so
# the sysctl does not exist and setting it makes the boot-time sysctl run report an error.

# Process protection ---------------------------------------------------------
kernel.yama.ptrace_scope = 1       # a process may only ptrace its own children
fs.suid_dumpable = 0               # never core-dump setuid programs

# Filesystem races -----------------------------------------------------------
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# BPF ------------------------------------------------------------------------
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Network --------------------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
EOF

echo "==> Mounting securityfs at boot"
# Without securityfs the LSM list and lockdown state are invisible: the LSMs are active
# either way, but nothing can confirm it, which defeats auditing.
#
# Only add the entry if the kernel actually supports it. An fstab line for an unknown
# filesystem makes LFS' S40mountfs bootscript fail, which halts the boot at a
# "Press Enter to continue" prompt -- a dead system, from a purely cosmetic feature.
KCONF=$(ls "$LFS"/boot/config-* 2>/dev/null | head -1)
if [ -n "$KCONF" ] && grep -q '^CONFIG_SECURITYFS=y' "$KCONF"; then
    if ! grep -q securityfs "$LFS/etc/fstab"; then
        sed -i '/^cgroup2/a securityfs     /sys/kernel/security securityfs nosuid,noexec,nodev 0     0' \
            "$LFS/etc/fstab"
    fi
    grep -E 'securityfs' "$LFS/etc/fstab" | sed 's/^/    /'
else
    sed -i '/securityfs/d' "$LFS/etc/fstab"
    echo "    kernel lacks CONFIG_SECURITYFS - entry omitted (would halt the boot)"
fi

echo "==> sshd hardening"
SSHD="$LFS/etc/ssh/sshd_config"
# Strip any previous copies of these directives, then append one authoritative block,
# so re-running this script does not stack duplicates.
sed -i -E '/^[[:space:]]*#?[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|PermitEmptyPasswords|X11Forwarding|AllowTcpForwarding|AllowAgentForwarding|MaxAuthTries|LoginGraceTime|ClientAliveInterval|ClientAliveCountMax|AllowGroups)\b/d' "$SSHD"
cat >> "$SSHD" <<'EOF'

# --- BareboneSecurityOSLite hardening ---------------------------------------
PermitRootLogin no
PasswordAuthentication no          # key-based auth only over the network
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups wheel                  # only administrators may log in remotely
EOF
# Deliberately not pinning Ciphers/MACs/KexAlgorithms: OpenSSH 10's defaults are
# already modern, and a hand-written list ages badly and silently weakens over time.

echo "==> password and umask defaults"
LD="$LFS/etc/login.defs"
if [ -f "$LD" ]; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*UMASK.*/UMASK 027/' "$LD"
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' "$LD"
    grep -q '^SHA_CRYPT_MIN_ROUNDS' "$LD" || echo 'SHA_CRYPT_MIN_ROUNDS 65536' >> "$LD"
    grep -q '^UMASK' "$LD" || echo 'UMASK 027' >> "$LD"
    grep -q '^ENCRYPT_METHOD' "$LD" || echo 'ENCRYPT_METHOD SHA512' >> "$LD"
fi

echo
echo "==> SUID/SGID inventory before"
find "$LFS/usr" -perm /6000 -type f 2>/dev/null | sed "s|^$LFS||" | sort | sed 's/^/    /'

echo
echo "==> Dropping setuid where sudo already covers the need"
# Kept deliberately: su, sudo, passwd (users must be able to change their own password).
# Dropped: helpers that only exist for convenience and are routine privilege-escalation
# footholds. mount/umount lose setuid because only root mounts anything on this system.
for b in chfn chsh newgrp gpasswd mount umount; do
    for p in "$LFS/usr/bin/$b" "$LFS/usr/sbin/$b"; do
        if [ -u "$p" ] || [ -g "$p" ]; then
            chmod -s "$p"
            echo "    setuid/setgid removed: ${p#$LFS}"
        fi
    done
done

echo
echo "==> Converting raw-socket users from setuid to a capability"
# ping already uses cap_net_raw; ping6 and traceroute want the same privilege and
# shipped setuid-root. A capability grants only the raw-socket right instead of full
# root, so a bug in them is worth far less to an attacker.
for b in ping6 traceroute; do
    p="$LFS/usr/bin/$b"
    if [ -f "$p" ] && [ ! -L "$p" ]; then
        chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin \
            /bin/bash -c "setcap cap_net_raw+p /usr/bin/$b && chmod -s /usr/bin/$b" \
            && echo "    $b: setuid dropped, cap_net_raw granted"
    fi
done

# Host-based authentication is not used here, and ssh-keysign is setuid solely to
# support it.
if [ -u "$LFS/usr/libexec/ssh-keysign" ]; then
    chmod -s "$LFS/usr/libexec/ssh-keysign"
    echo "    ssh-keysign: setuid dropped (host-based auth unused)"
fi

echo
echo "==> SUID/SGID inventory after"
find "$LFS/usr" -perm /6000 -type f 2>/dev/null | sed "s|^$LFS||" | sort | sed 's/^/    /'

echo
echo "==> Installing the audit tool as /usr/sbin/security-audit"
install -m755 "$(dirname "$0")/security-audit.sh" "$LFS/usr/sbin/security-audit"
sed -i 's/\r$//' "$LFS/usr/sbin/security-audit"
echo "    installed"

echo
echo "==> Done. Re-run 08-make-bootable-image.sh to fold this in."
