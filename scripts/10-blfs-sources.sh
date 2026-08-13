#!/bin/bash
# Download the BLFS packages that make the system administrable, into $LFS/sources/blfs.
#
# Everything is fetched on the host, where networking works, so the chroot build needs
# no network at all. md5sums come from the BLFS book's own packages.ent, so a bad
# mirror or a truncated download is caught here rather than mid-build.
#
# Run as root:  bash 10-blfs-sources.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SRC="$LFS/sources/blfs"
BLFS=/root/blfs-src

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
[ -d "$BLFS" ] || { echo "FATAL: BLFS book source missing at $BLFS"; exit 1; }
mkdir -p "$SRC"
cd "$SRC"

# name|url|book-xml-file  (BLFS defines each md5 in the package's own XML, NOT in
# packages.ent -- that only carries versions. Empty file = no book md5 to check.)
# libunistring/libidn2/libpsl exist only to satisfy curl: BLFS warns that building
# curl without libpsl has "severe security implications", so we add the chain rather
# than pass --without-libpsl.
PKGS="
libunistring|https://ftpmirror.gnu.org/libunistring/libunistring-1.4.1.tar.xz|general/genlib/libunistring.xml
libidn2|https://ftpmirror.gnu.org/libidn/libidn2-2.3.8.tar.gz|general/genlib/libidn2.xml
libpsl|https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz|networking/netlibs/libpsl.xml
libtasn1|https://ftpmirror.gnu.org/libtasn1/libtasn1-4.21.0.tar.gz|general/genlib/libtasn1.xml
p11-kit|https://github.com/p11-glue/p11-kit/releases/download/0.26.2/p11-kit-0.26.2.tar.xz|postlfs/security/p11-kit.xml
make-ca|https://github.com/lfs-book/make-ca/archive/v1.16.1/make-ca-1.16.1.tar.gz|postlfs/security/make-ca.xml
curl|https://curl.se/download/curl-8.18.0.tar.xz|networking/netlibs/curl.xml
sudo|https://www.sudo.ws/dist/sudo-1.9.17p2.tar.gz|postlfs/security/sudo.xml
dhcpcd|https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.3.0/dhcpcd-10.3.0.tar.xz|networking/connect/dhcpcd.xml
openssh|https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.2p1.tar.gz|postlfs/security/openssh.xml
iputils|https://github.com/iputils/iputils/archive/20250605/iputils-20250605.tar.gz|
"

echo "==> Downloading packages"
fail=0
while IFS='|' read -r name url xml; do
    [ -z "$name" ] && continue
    file=$(basename "$url")
    if [ ! -f "$file" ]; then
        printf '%-10s %-34s ' "$name" "$file"
        curl -sSfL --retry 3 -o "$file" "$url" && echo "downloaded" || { echo "FAILED"; fail=1; continue; }
    else
        printf '%-10s %-34s cached\n' "$name" "$file"
    fi

    if [ -n "$xml" ] && [ -f "$BLFS/$xml" ]; then
        # BLFS keeps some md5s in packages.ent and others in the package's own XML;
        # where both exist the XML one is self-referential ("&openssh-md5sum;"), so
        # search packages.ent first and fall back to the XML.
        # `|| true` matters: under `set -e` with pipefail a non-matching grep would
        # abort the whole script rather than just skipping this checksum.
        want=$(grep -hoE "<!ENTITY[[:space:]]+$name-md5sum[[:space:]]+\"[0-9a-f]{32}\"" \
                   "$BLFS/packages.ent" "$BLFS/$xml" 2>/dev/null \
               | grep -oE '[0-9a-f]{32}' | head -1 || true)
        if [ -n "$want" ]; then
            got=$(md5sum "$file" | cut -d' ' -f1)
            if [ "$want" = "$got" ]; then
                echo "           md5 OK (matches BLFS book)"
            else
                echo "           md5 MISMATCH: book=$want got=$got"; fail=1
            fi
        else
            echo "           (no $name-md5sum entity in $xml)"
        fi
    else
        echo "           (not a BLFS package - no book md5 to check)"
    fi
done <<< "$PKGS"

echo
echo "==> Downloading Mozilla certdata.txt for make-ca"
# make-ca would fetch this itself, but the chroot has no usable resolver, so supply it
# locally and pass it with `make-ca -C`.
if [ ! -f certdata.txt ]; then
    curl -sSfL --retry 3 -o certdata.txt \
      "https://hg-edge.mozilla.org/projects/nss/raw-file/tip/lib/ckfw/builtins/certdata.txt" \
      || { echo "FAILED to fetch certdata.txt"; fail=1; }
fi
if [ -f certdata.txt ]; then
    n=$(grep -c 'CKA_CLASS' certdata.txt || echo 0)
    echo "    certdata.txt: $(du -h certdata.txt | cut -f1), $n CKA_CLASS entries"
    [ "$n" -gt 100 ] || { echo "    certdata.txt looks wrong"; fail=1; }
fi

echo
echo "==> Staging blfs-bootscripts (provides the sshd init script and dhcpcd service)"
rm -rf "$SRC/blfs-bootscripts"
cp -r /root/blfs-bootscripts "$SRC/blfs-bootscripts"
rm -rf "$SRC/blfs-bootscripts/.git"
echo "    targets available: $(grep -cE '^install-' "$SRC/blfs-bootscripts/Makefile")"

echo
ls -lh "$SRC" | tail -n +2 | awk '{printf "  %-38s %s\n", $9, $5}'
echo
[ "$fail" = 0 ] && echo "==> All BLFS sources present and verified." \
                || { echo "==> Some downloads/checksums FAILED"; exit 1; }
