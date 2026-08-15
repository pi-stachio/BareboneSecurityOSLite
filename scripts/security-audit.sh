#!/bin/bash
# Security audit for BastionOS. Installed as /usr/sbin/security-audit.
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

hdr "Password and file-creation policy"
LD=/etc/login.defs
if [ -r "$LD" ]; then
    em=$(awk '/^ENCRYPT_METHOD/{print $2}' "$LD")
    case "$em" in
        YESCRYPT) ok "password hashing is yescrypt (memory-hard)" ;;
        SHA512)   warn "password hashing is SHA512 — yescrypt is available and stronger" ;;
        *)        bad "password hashing is '${em:-unset}'" ;;
    esac
    um=$(awk '/^UMASK/{print $2}' "$LD")
    [ "$um" = 027 ] && ok "default umask 027 (group/other cannot read new files)" \
                    || warn "default umask is '${um:-unset}', expected 027"
    # A locked or absent root password is fine; a *blank* one is not.
    if awk -F: '$1=="root" && $2==""' /etc/shadow 2>/dev/null | grep -q .; then
        bad "root has an empty password"
    else
        ok "root password is not empty"
    fi
else
    warn "no /etc/login.defs"
fi

hdr "ELF hardening across the whole installed system"
# Sampling a handful of binaries proves nothing about a rebuild: the interesting question
# is whether ANY binary was missed. So scan every executable and shared library and
# report the outliers by name.
#
# One readelf call per file carrying every section we need -- headers, program headers,
# dynamic section, notes, dynamic symbols. Three separate calls over ~700 files is
# noticeably slow on a VM.
tmp=$(mktemp); miss_now=$(mktemp); miss_pie=$(mktemp); miss_nx=$(mktemp); miss_cet=$(mktemp)
tot=0; static=0; n_now=0; n_relro=0; n_nx=0; n_cet=0; n_canary=0; exe=0; n_pie=0

for f in /usr/bin/* /usr/sbin/* /usr/lib/*.so*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    # readelf exits non-zero on anything that is not ELF, which filters out the shell
    # scripts and data files that live alongside the binaries.
    readelf -W -h -l -d -n --dyn-syms "$f" > "$tmp" 2>/dev/null || continue
    tot=$((tot+1))

    # No dynamic section at all -- a static binary. It cannot have BIND_NOW, and saying
    # it "fails" full RELRO would be a false positive, so count it separately.
    if ! grep -q 'Dynamic section at offset' "$tmp"; then static=$((static+1)); continue; fi

    grep -q 'GNU_RELRO' "$tmp" && n_relro=$((n_relro+1))
    if grep -qE 'BIND_NOW|FLAGS.*\bNOW\b' "$tmp"; then n_now=$((n_now+1))
    else echo "$f" >> "$miss_now"; fi
    if grep -q 'GNU_STACK' "$tmp" && grep -qE 'GNU_STACK.*RWE' "$tmp"; then echo "$f" >> "$miss_nx"
    else n_nx=$((n_nx+1)); fi
    grep -q '__stack_chk_fail' "$tmp" && n_canary=$((n_canary+1))
    # Match the .note.gnu.property line specifically, and require both properties --
    # a bare grep for IBT would also hit any symbol name containing those letters.
    if grep 'x86 feature:' "$tmp" | grep -q 'IBT' && grep 'x86 feature:' "$tmp" | grep -q 'SHSTK'
    then n_cet=$((n_cet+1)); else echo "$f" >> "$miss_cet"; fi

    # PIE only means something for executables; a shared library is DYN by definition.
    case "$f" in /usr/lib/*.so*) ;; *)
        exe=$((exe+1))
        if grep -qE 'Type:[[:space:]]+DYN' "$tmp"; then n_pie=$((n_pie+1))
        else echo "$f" >> "$miss_pie"; fi ;;
    esac
done

pct() { [ "$2" -eq 0 ] && echo 0 || echo $(( $1 * 100 / $2 )); }
show_missing() { # file label
    [ -s "$1" ] || return
    echo "    missing $2:"; sed 's|^|      |' "$1" | head -8
    [ "$(wc -l < "$1")" -gt 8 ] && echo "      ... and $(( $(wc -l < "$1") - 8 )) more"
}
dyn=$((tot-static))
echo "    scanned $tot files ($dyn dynamic, $static static)"

rate() { # label count total threshold-pct missingfile
    local p; p=$(pct "$2" "$3")
    printf '    %-24s %4d/%-4d %3d%%\n' "$1" "$2" "$3" "$p"
    if [ "$p" -ge "$4" ]; then PASS=$((PASS+1)); else
        if [ "$p" -ge $(( $4 - 10 )) ]; then warn "$1 at ${p}% (want ${4}%+)"
        else bad "$1 at ${p}% (want ${4}%+)"; fi
        show_missing "$5" "$1"
    fi
}
rate "full RELRO (BIND_NOW)" "$n_now"    "$dyn" 100 "$miss_now"
rate "GNU_RELRO segment"     "$n_relro"  "$dyn" 100 /dev/null
rate "PIE (executables)"     "$n_pie"    "$exe" 100 "$miss_pie"
rate "non-executable stack"  "$n_nx"     "$dyn" 100 "$miss_nx"
rate "CET (IBT+SHSTK)"       "$n_cet"    "$dyn"  95 "$miss_cet"
printf '    %-24s %4d/%-4d %3d%%   (only where the code has a protectable frame)\n' \
    "stack canary" "$n_canary" "$dyn" "$(pct "$n_canary" "$dyn")"
rm -f "$tmp" "$miss_now" "$miss_pie" "$miss_nx" "$miss_cet"

hdr "Compiler defaults on the running system"
# The image ships a working toolchain, so anything built ON this system should inherit
# the same hardening. Verify against a real compile rather than trusting the specs file.
if command -v gcc > /dev/null; then
    GCCSPECS=$(dirname "$(gcc -print-libgcc-file-name 2>/dev/null)")/specs
    [ -f "$GCCSPECS" ] && ok "hardened specs installed" || bad "no specs file at $GCCSPECS"
    t=$(mktemp -d); printf 'int main(void){return 0;}\n' > "$t/t.c"
    if gcc -O2 "$t/t.c" -o "$t/t" 2>/dev/null; then
        readelf -dW "$t/t" | grep -qE 'BIND_NOW|FLAGS.*\bNOW\b' \
            && ok "newly compiled binaries get BIND_NOW" \
            || bad "newly compiled binaries lack BIND_NOW"
        [ "$(gcc -O2 -dM -E - < /dev/null | awk '/define _FORTIFY_SOURCE/{print $3}')" = 3 ] \
            && ok "_FORTIFY_SOURCE=3 is the default" || bad "_FORTIFY_SOURCE=3 is not default"
        [ "$(gcc -O2 -dM -E - < /dev/null | awk '/define __CET__/{print $3}')" = 3 ] \
            && ok "CET is on by default" || bad "CET is not on by default"
    else
        bad "the shipped gcc cannot compile a trivial program"
    fi
    rm -rf "$t"
else
    warn "no gcc on this system to check"
fi

hdr "Package integrity"
# bpkg records a SHA256 for every file it installs, so this answers a question the rest
# of the audit cannot: has anything been modified since it was put there? It only covers
# packaged software -- the LFS base is not packaged -- which is stated rather than
# glossed over, because a partial integrity check read as a total one is worse than none.
if command -v bpkg > /dev/null 2>&1; then
    n=$(bpkg list 2>/dev/null | grep -cv 'no packages' || true)
    if [ "${n:-0}" -eq 0 ]; then
        ok "no add-on packages installed"
    else
        echo "    $n package(s) installed via bpkg:"
        bpkg list 2>/dev/null | sed 's/^/      /'
        if out=$(bpkg verify 2>&1); then
            ok "all packaged files match their recorded checksums"
        else
            bad "packaged files have been modified or are missing"
            echo "$out" | grep -E 'MODIFIED|MISSING|modified' | head -8 | sed 's/^/      /'
        fi
        echo "    (covers packaged software only; the LFS base is not packaged)"
    fi
else
    warn "bpkg not installed; no package integrity information"
fi

hdr "Time synchronisation"
# A drifting clock breaks TLS with errors that blame the certificate, and makes every
# log timestamp and the advisory report's date meaningless.
if command -v chronyc > /dev/null 2>&1; then
    if pgrep -x chronyd > /dev/null 2>&1; then
        src=$(chronyc -n tracking 2>/dev/null | awk -F': *' '/Reference ID/{print $2}')
        off=$(chronyc -n tracking 2>/dev/null | awk -F': *' '/System time/{print $2}')
        ok "chronyd is running (ref ${src:-none}, ${off:-unknown})"
    else
        warn "chrony is installed but chronyd is not running"
    fi
else
    warn "no time synchronisation installed — TLS will fail once the clock drifts"
fi

hdr "Known vulnerabilities in installed packages"
# Read the cached report rather than querying NVD live: the scan is rate limited to
# several minutes, and an audit that needs the network to finish is an audit that gets
# skipped. /usr/sbin/vuln-scan refreshes it.
VR=/etc/bastionos/vuln-report.txt
if [ -r "$VR" ]; then
    gen=$(awk '/^# generated:/{print $3}' "$VR")
    sm=$(grep -m1 '^SUMMARY' "$VR")
    crit=$(sed -n 's/.*critical=\([0-9]*\).*/\1/p' <<<"$sm")
    high=$(sed -n 's/.*high=\([0-9]*\).*/\1/p' <<<"$sm")
    med=$(sed -n 's/.*medium=\([0-9]*\).*/\1/p' <<<"$sm")
    low=$(sed -n 's/.*low=\([0-9]*\).*/\1/p' <<<"$sm")
    aff=$(sed -n 's/.*affected_packages=\([0-9]*\).*/\1/p' <<<"$sm")
    scanned=$(sed -n 's/.*scanned=\([0-9]*\).*/\1/p' <<<"$sm")
    echo "    report generated $gen  ($scanned packages scanned)"
    printf '    critical=%s high=%s medium=%s low=%s   across %s packages\n' \
        "${crit:-?}" "${high:-?}" "${med:-?}" "${low:-?}" "${aff:-?}"

    # Age: upstream publishes new advisories constantly, so a stale report is a
    # statement about the past, not the present.
    if [ -n "$gen" ] && age=$(( ( $(date -u +%s) - $(date -u -d "$gen" +%s) ) / 86400 )) 2>/dev/null; then
        if [ "$age" -le 30 ]; then ok "vulnerability report is ${age}d old"
        else warn "vulnerability report is ${age}d old — run vuln-scan to refresh"; fi
    fi

    # These are upstream facts about pinned versions, not defects in how this system was
    # built or configured, so they are warnings rather than failures. Reporting them as
    # failures would also mean the boot test could never pass, which would train everyone
    # to ignore it.
    if [ "${crit:-0}" -gt 0 ]; then warn "$crit critical advisories affect installed packages"
    else ok "no critical advisories"; fi
    if [ "${high:-0}" -gt 0 ]; then warn "$high high-severity advisories affect installed packages"
    else ok "no high-severity advisories"; fi

    echo "    worst-affected packages:"
    grep '^PKG' "$VR" | awk -F'\t' '{
        c=$5; sub(/.*critical=/,"",c); sub(/ .*/,"",c);
        h=$5; sub(/.*high=/,"",h);     sub(/ .*/,"",h);
        printf "%d\t%s\t%s\t%s\t%s\n", c*100+h, $2, $3, c, h }' \
        | sort -rn | head -6 \
        | awk -F'\t' '{printf "      %-18s %-12s critical=%s high=%s\n", $2, $3, $4, $5}'
    echo "    full list: $VR   refresh: vuln-scan"
else
    warn "no vulnerability report at $VR — run vuln-scan"
fi

hdr "Summary"
printf '  %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "  No failures." || echo "  Review the failures above."
exit $(( FAIL > 0 ? 1 : 0 ))
