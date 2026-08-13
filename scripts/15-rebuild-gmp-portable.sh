#!/bin/bash
# Rebuild GMP without build-machine CPU tuning.
#
# GMP detects the *build* CPU at configure time and bakes the result in --- on this
# machine it produced "-march=broadwell -mtune=skylake". Any binary linking libgmp
# then executes Broadwell instructions, so on an older or emulated CPU it dies with
# SIGILL. That affects nft and, more importantly, gcc: a distributed image built this
# way crashes on hardware older than the machine that built it.
#
# The LFS book covers this: pass --host=none-linux-gnu to disable CPU-specific tuning
# when the system may run somewhere other than the build machine. Since this project
# publishes bootable images, that is always.
#
# Run as root:  bash 15-rebuild-gmp-portable.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

TARBALL=$(ls "$LFS"/sources/gmp-*.tar.* 2>/dev/null | head -1)
[ -n "$TARBALL" ] || { echo "FATAL: no gmp tarball in $LFS/sources"; exit 1; }
VER=$(basename "$TARBALL" | sed -E 's/^gmp-(.+)\.tar\..*$/\1/')
echo "==> GMP $VER"

echo "==> Current tuning (the problem):"
grep -o '__GMP_CFLAGS "[^"]*"' "$LFS/usr/include/gmp.h" || true

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

cat > "$LFS/sources/gmp-portable.sh" <<EOS
#!/bin/bash
set -e
cd /sources
rm -rf gmp-$VER
tar -xf $(basename "$TARBALL")
cd gmp-$VER
# --host=none-linux-gnu is what turns off the CPU probing.
./configure --prefix=/usr        \\
            --enable-cxx         \\
            --disable-static     \\
            --host=none-linux-gnu \\
            --docdir=/usr/share/doc/gmp-$VER
make -j\$(nproc)
make install
EOS
chmod +x "$LFS/sources/gmp-portable.sh"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/gmp-portable.sh > /tmp/gmp-rebuild.log 2>&1 \
    || { echo "FATAL: GMP rebuild failed"; tail -20 /tmp/gmp-rebuild.log; exit 1; }

echo
echo "==> New tuning:"
NEW=$(grep -o '__GMP_CFLAGS "[^"]*"' "$LFS/usr/include/gmp.h" || true)
echo "    $NEW"
if echo "$NEW" | grep -qE '\-march=(broadwell|skylake|haswell|native|znver|core)'; then
    echo "ERROR: GMP is still tuned to a specific CPU"
    exit 1
else
    echo "OK:    GMP no longer targets a specific CPU"
fi

echo
echo "==> Sanity check inside the chroot"
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
    nft -c -f /etc/nftables.conf && echo "OK:    nft still parses the ruleset"
    gcc --version | head -1
'
echo
echo "==> Done. Re-run 08-make-bootable-image.sh."
