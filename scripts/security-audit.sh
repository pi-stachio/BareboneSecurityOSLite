#!/bin/bash
# Security audit for BareboneSecurityOSLite. Installed as /usr/sbin/security-audit.
#
# Reports what is actually true of the running system rather than what was intended:
# kernel build options, live sysctl values, active LSMs, the firewall policy, the
# SUID inventory, sshd policy, and ELF hardening of a sample of binaries.
#
# Run as root:  security-audit
PASS=0; WARN=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

KCONF=$(ls /boot/config-* 2>/dev/null | head -1)

hdr "Kernel build options  (${KCONF:-no config found})"
kchk() { # symbol expected-state description
    local s=$1 want=$2 d=$3
    [ -f "$KCONF" ] || { warn "$d (no kernel config to read)"; return; }
    if grep -q "^$s=y" "$KCONF"; then
        [ "$want" = y ] && ok "$d" || bad "$d — $s is enabled"
    else
        [ "$want" = n ] && ok "$d" || bad "$d — $s is not enabled"
    fi
}
kchk CONFIG_RANDOMIZE_BASE            y "KASLR"
kchk CONFIG_STRICT_KERNEL_RWX         y "kernel text is read-only"
kchk CONFIG_HARDENED_USERCOPY         y "hardened usercopy"
kchk CONFIG_FORTIFY_SOURCE            y "in-kernel FORTIFY_SOURCE"
kchk CONFIG_STACKPROTECTOR_STRONG     y "stack protector (strong)"
kchk CONFIG_INIT_ON_ALLOC_DEFAULT_ON  y "heap zeroed on allocation"
kchk CONFIG_INIT_ON_FREE_DEFAULT_ON   y "heap zeroed on free"
kchk CONFIG_SLAB_FREELIST_HARDENED    y "slab freelist hardening"
kchk CONFIG_SLAB_FREELIST_RANDOM      y "slab freelist randomisation"
kchk CONFIG_RANDOM_KMALLOC_CACHES     y "randomised kmalloc caches"
kchk CONFIG_VMAP_STACK                y "virtually-mapped stacks (guard pages)"
kchk CONFIG_BUG_ON_DATA_CORRUPTION    y "panic on detected data corruption"
kchk CONFIG_MODULES                   n "loadable modules disabled"
kchk CONFIG_DEVMEM                    n "/dev/mem disabled"
kchk CONFIG_PROC_KCORE                n "/proc/kcore disabled"
kchk CONFIG_KEXEC                     n "kexec disabled"
kchk CONFIG_HIBERNATION               n "hibernation disabled"
kchk CONFIG_IA32_EMULATION            n "32-bit syscall emulation disabled"

hdr "Active LSMs"
if [ -r /sys/kernel/security/lsm ]; then
    lsms=$(cat /sys/kernel/security/lsm)
    echo "  active: $lsms"
    for l in landlock lockdown yama; do
        case ",$lsms," in *",$l,"*|*",$l") ok "$l active" ;; *) bad "$l NOT active" ;; esac
    done
else
    warn "securityfs not mounted; cannot read active LSM list"
fi
[ -r /sys/kernel/security/lockdown ] && echo "  lockdown: $(cat /sys/kernel/security/lockdown)"

hdr "Loaded kernel modules"
if [ -e /proc/modules ] && [ -s /proc/modules ]; then
    bad "modules are loaded: $(wc -l < /proc/modules)"
else
    ok "no loadable modules present"
fi

hdr "Runtime sysctl"
schk() { # key expected description
    local v; v=$(sysctl -n "$1" 2>/dev/null)
    if [ -z "$v" ]; then warn "$3 ($1 unavailable)"
    elif [ "$v" = "$2" ]; then ok "$3 ($1=$v)"
    else bad "$3 — $1=$v, expected $2"; fi
}
schk kernel.dmesg_restrict 1            "kernel ring buffer restricted"
schk kernel.kptr_restrict 2             "kernel pointers hidden"
schk kernel.yama.ptrace_scope 1         "ptrace restricted to descendants"
schk kernel.perf_event_paranoid 3       "perf restricted"
schk kernel.sysrq 0                     "magic SysRq disabled"
# If the BPF syscall is compiled out entirely there is nothing to restrict, and the
# sysctls legitimately do not exist -- that is stronger than setting them, not weaker.
if [ -f "$KCONF" ] && ! grep -q '^CONFIG_BPF_SYSCALL=y' "$KCONF"; then
    ok "BPF syscall compiled out (nothing to restrict)"
else
    schk kernel.unprivileged_bpf_disabled 1 "unprivileged BPF disabled"
    schk net.core.bpf_jit_harden 2          "BPF JIT hardened"
fi
schk fs.suid_dumpable 0                 "setuid programs do not core-dump"
schk fs.protected_hardlinks 1           "hardlink protection"
schk fs.protected_symlinks 1            "symlink protection"
schk net.ipv4.tcp_syncookies 1          "SYN cookies"
schk net.ipv4.conf.all.rp_filter 1      "reverse-path filtering"
schk net.ipv4.conf.all.accept_redirects 0 "ICMP redirects ignored"
schk net.ipv4.conf.all.accept_source_route 0 "source routing refused"

hdr "Firewall"
if command -v nft > /dev/null; then
    if nft list ruleset 2>/dev/null | grep -q 'hook input'; then
        pol=$(nft list ruleset | awk '/hook input/{print $NF}' | tr -d ';')
        [ "$pol" = "drop" ] && ok "inbound policy is drop" || bad "inbound policy is $pol, expected drop"
        nft list ruleset | grep -q 'hook forward.*policy drop' \
            && ok "forwarding policy is drop" || warn "forwarding policy is not drop"
        nft list ruleset | grep -q 'tcp dport 22' && ok "SSH is permitted" || warn "no SSH rule found"
        echo "  counters:"; nft list ruleset | grep -E 'counter packets' | sed 's/^/    /' | head -3
    else
        bad "nftables is installed but no ruleset is loaded"
    fi
else
    bad "no nft binary — firewall not installed"
fi

hdr "SUID / SGID binaries"
suid=$(find / -xdev -perm /6000 -type f 2>/dev/null | sort)
n=$(printf '%s\n' "$suid" | grep -c . || true)
echo "$suid" | sed 's/^/    /'
[ "$n" -le 10 ] && ok "$n setuid/setgid binaries (small surface)" \
                || warn "$n setuid/setgid binaries — review the list above"

hdr "File capabilities"
command -v getcap > /dev/null && getcap -r / 2>/dev/null | sed 's/^/    /' || echo "    (getcap unavailable)"

hdr "SSH policy"
S=/etc/ssh/sshd_config
sshchk() { grep -qiE "^[[:space:]]*$1[[:space:]]+$2\b" "$S" && ok "$3" || bad "$3 — expected '$1 $2'"; }
if [ -r "$S" ]; then
    sshchk PermitRootLogin no                 "root login disabled"
    sshchk PasswordAuthentication no          "password auth disabled (keys only)"
    sshchk PermitEmptyPasswords no            "empty passwords refused"
    sshchk X11Forwarding no                   "X11 forwarding disabled"
    sshchk AllowTcpForwarding no              "TCP forwarding disabled"
    sshchk MaxAuthTries 3                     "auth attempts limited"
else
    warn "no sshd_config"
fi

hdr "ELF hardening of installed binaries"
# Userland compiler flags are the tier this project has not yet applied; report the
# real state rather than assume it.
elfchk() {
    local f=$1 h
    [ -x "$f" ] || return
    h=$(readelf -lWd "$f" 2>/dev/null) || return
    local relro=no now=no pie=no nx=no canary=no
    grep -q 'GNU_RELRO' <<<"$h" && relro=yes
    grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$h" && now=yes
    readelf -hW "$f" 2>/dev/null | grep -q 'Type:[[:space:]]*DYN' && pie=yes
    grep -q 'GNU_STACK.*RWE' <<<"$h" || nx=yes
    readelf -sW "$f" 2>/dev/null | grep -q '__stack_chk_fail' && canary=yes
    printf '    %-22s relro=%-3s bindnow=%-3s pie=%-3s nx=%-3s canary=%s\n' \
        "$(basename "$f")" "$relro" "$now" "$pie" "$nx" "$canary"
}
for f in /usr/bin/bash /usr/bin/ls /usr/bin/sudo /usr/bin/ssh /usr/bin/curl \
         /usr/sbin/sshd /usr/sbin/nft; do elfchk "$f"; done
echo "    (full RELRO + PIE across all packages requires rebuilding with hardened"
echo "     CFLAGS — the toolchain tier, not yet applied)"

hdr "Summary"
printf '  %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  No failures." || echo "  Review the failures above."
exit $(( FAIL > 0 ? 1 : 0 ))
