#!/bin/bash
# Inventory every installed package and check it against the NVD CVE database.
#
# The previous tiers answer "was this compiled defensively?". This one answers the
# question that actually matters to someone running it: "is anything in here known to
# be broken right now?" A source-built system has no package manager and therefore no
# patch notifications at all, so without this the honest answer is "nobody knows".
#
# The manifest is built from the jhalfs chapter 8 command scripts rather than from
# ls /sources, because /sources also holds tarballs for packages LFS never installs
# (dbus and elfutils are downloaded as part of the full wget-list but not built here).
# What was compiled is what the book's commands say was compiled.
#
# Run as root:  bash 18-vuln-scan.sh
#   NVD_API_KEY=... speeds it up roughly 5x (50 requests/30s instead of 5).
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
CMDDIR="$LFS/jhalfs/lfs-commands/chapter08"
ETC="$LFS/etc/bastionos"
MANIFEST="$ETC/packages.tsv"
REPORT="$ETC/vuln-report.txt"

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
[ -d "$CMDDIR" ] || { echo "FATAL: no jhalfs chapter 8 commands at $CMDDIR"; exit 1; }
mkdir -p "$ETC"

# tarball name -> "name<TAB>version"
split_tarball() {
    local b=${1%.tar.*} n v
    n=${b%-*}; v=${b##*-}
    if [[ $v =~ ^[0-9] ]]; then printf '%s\t%s' "$n" "$v"; return; fi
    # Names where the version runs straight into the name with no separator:
    # expect5.45.4, tcl8.6.17-src.
    if [[ $b =~ ^([A-Za-z_+-]+)([0-9][0-9.]*[0-9])(-src)?$ ]]; then
        printf '%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return
    fi
    printf '%s\t%s' "$b" "?"
}

echo "==> Building the installed-package manifest"
tmp=$(mktemp)
for f in "$CMDDIR"/8*; do
    pkg=$(grep -m1 '^PACKAGE=' "$f" 2>/dev/null | cut -d= -f2 || true)
    [ -n "$pkg" ] || continue
    IFS=$'\t' read -r n v <<< "$(split_tarball "$pkg")"
    # LFS SysV builds udev from the systemd tarball, so the tarball name is a lie about
    # what ends up installed: there is no systemctl and there are no units, just udevd
    # and udevadm. Record the component, not the source archive it came out of.
    if [ "$n" = systemd ]; then n=udev; fi
    printf '%s\t%s\t%s\n' "$n" "$v" lfs >> "$tmp"
done

KVER=$(grep -m1 '^KVER=' "$SCRIPTS/12-harden-kernel.sh" | cut -d= -f2)
printf 'linux\t%s\tlfs\n' "$KVER" >> "$tmp"

for t in "$LFS"/sources/blfs/*.tar.*; do
    [ -e "$t" ] || continue
    case "$t" in *.sha256sum) continue ;; esac
    IFS=$'\t' read -r n v <<< "$(split_tarball "$(basename "$t")")"
    printf '%s\t%s\t%s\n' "$n" "$v" blfs >> "$tmp"
done

# Anything installed with bpkg. Without this, software added after the image was built
# is invisible to the scanner -- and software added later is exactly the software most
# likely to be unpatched, since the base at least gets rebuilt with the release.
if [ -d "$LFS/var/lib/bpkg/db" ]; then
    for p in "$LFS"/var/lib/bpkg/db/*/; do
        [ -f "$p/PKGINFO" ] || continue
        n=$(sed -n 's/^name = //p'    "$p/PKGINFO" | head -1)
        v=$(sed -n 's/^version = //p' "$p/PKGINFO" | head -1)
        [ -n "$n" ] && [ -n "$v" ] && printf '%s\t%s\t%s\n' "$n" "$v" bpkg >> "$tmp"
    done
fi

{
    echo "# BastionOS installed package manifest"
    echo "# name<TAB>version<TAB>origin   -- generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sort -u "$tmp"
} > "$MANIFEST"
rm -f "$tmp"

bad=$(awk -F'\t' '!/^#/ && $2=="?"' "$MANIFEST" | wc -l)
echo "    $(grep -vc '^#' "$MANIFEST") packages"
if [ "$bad" -gt 0 ]; then
    echo "ERROR: $bad entries have an unparsed version:"
    awk -F'\t' '!/^#/ && $2=="?"' "$MANIFEST" | sed 's/^/      /'
    exit 1
fi

echo
echo "==> Querying NVD (rate limited; several minutes without an API key)"
install -m755 "$SCRIPTS/vuln-scan.py" "$LFS/usr/sbin/vuln-scan"
sed -i 's/\r$//' "$LFS/usr/sbin/vuln-scan"

# Reinstall the audit tool as well, not just the scanner. security-audit reads the report
# this script produces, so the two are coupled -- and 14-harden-config.sh is what normally
# installs it. Editing the audit and re-running only this script would otherwise ship an
# image whose audit silently knows nothing about the report sitting next to it, which is
# exactly the state the boot test caught.
install -m755 "$SCRIPTS/security-audit.sh" "$LFS/usr/sbin/security-audit"
sed -i 's/\r$//' "$LFS/usr/sbin/security-audit"
python3 "$SCRIPTS/vuln-scan.py" -m "$MANIFEST" -o "$REPORT" ${NVD_API_KEY:+--api-key "$NVD_API_KEY"}

echo
echo "==> Installed into the image:"
echo "    /etc/bastionos/packages.tsv     the manifest"
echo "    /etc/bastionos/vuln-report.txt  this report"
echo "    /usr/sbin/vuln-scan             refresh it (needs network)"
echo
echo "==> Re-run 08-make-bootable-image.sh to fold this in."
