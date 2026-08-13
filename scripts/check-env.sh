#!/bin/bash
# Sanity check the LFS build environment. Run as root after any WSL restart:
#   wsl -d lfs-host -u root -- bash /root/lfs/check-env.sh
LFS=${LFS:-/mnt/lfs}
ok()   { printf 'OK:    %s\n' "$1"; }
bad()  { printf 'ERROR: %s\n' "$1"; FAIL=1; }
FAIL=0

# NB: on Debian /bin is a symlink to /usr/bin, so compare basenames rather than paths.
[ "$(basename "$(readlink -f /bin/sh)")" = "bash" ] && ok "/bin/sh -> bash" || bad "/bin/sh is not bash"

if echo "$PATH" | grep -q '/mnt/c'; then
    bad "Windows PATH is leaking into the environment (check /etc/wsl.conf, then 'wsl --terminate lfs-host')"
else
    ok "PATH is clean of Windows entries"
fi

mountpoint -q "$LFS" && ok "$LFS is mounted ($(df -h --output=avail "$LFS" | tail -1 | tr -d ' ') free)" \
                     || bad "$LFS is NOT mounted (run 01-lfs-partition.sh)"

id lfs &> /dev/null && ok "user lfs exists" || bad "user lfs missing"
[ -f /home/lfs/.bashrc ] && ok "lfs .bashrc present" || bad "lfs .bashrc missing"
[ ! -e /etc/bash.bashrc ] && ok "/etc/bash.bashrc moved aside" || bad "/etc/bash.bashrc still present"

n=$(ls "$LFS/sources" 2>/dev/null | grep -cE '\.(tar\.(gz|xz|bz2)|patch)$')
[ "$n" -ge 92 ] && ok "$n source files in $LFS/sources" || bad "only $n source files (expected >= 92)"

for d in tools usr/bin usr/lib usr/sbin etc var lib64; do
    [ -d "$LFS/$d" ] || bad "missing $LFS/$d"
done
[ "$FAIL" = 0 ] && ok "LFS directory skeleton intact"

echo
[ "$FAIL" = 0 ] && echo "All checks passed." || echo "Some checks FAILED (see above)."
exit $FAIL
