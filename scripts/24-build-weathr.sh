#!/bin/bash
# Build weathr (a Rust terminal weather app) and package it with bpkg.
#
# weathr needs a Rust toolchain, which this system does not have and should not keep:
# rustc + cargo + std is around 1.5 GB installed, for one 3 MB binary. So Rust is
# installed to /opt/rust, used, and deleted -- a build dependency, not a runtime one.
# The package contains the weathr binary and nothing else.
#
# This does not use 23-build-package.sh because that expects a source tarball and a
# ./configure-style build; weathr comes from crates.io via cargo, which fetches its own
# dependencies. The recipe format is not worth contorting for one package.
#
# Run as root:  bash 24-build-weathr.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
RUST_VER=${RUST_VER:-1.97.1}
SRC="$LFS/sources/pkg"
KEEP_RUST=${KEEP_RUST:-0}

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
mkdir -p "$SRC" "$LFS/sources/packages"
install -m755 "$SCRIPTS/bpkg.sh" "$LFS/usr/bin/bpkg"
sed -i 's/\r$//' "$LFS/usr/bin/bpkg"

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"
cp -f /etc/resolv.conf "$LFS/etc/resolv.conf" 2>/dev/null || true

RUST_TAR="rust-$RUST_VER-x86_64-unknown-linux-gnu.tar.xz"
if [ ! -f "$SRC/$RUST_TAR" ]; then
    echo "==> Fetching Rust $RUST_VER (192 MB, build dependency only)"
    curl -fsSL -o "$SRC/$RUST_TAR" \
        "https://static.rust-lang.org/dist/$RUST_TAR" \
        || { echo "FATAL: could not download Rust"; exit 1; }
fi

cat > "$SRC/build-weathr.sh" <<EOS
#!/bin/bash
set -e
cd /sources/pkg

if [ ! -x /opt/rust/bin/cargo ]; then
    echo "### installing Rust to /opt/rust ###"
    rm -rf rust-$RUST_VER-x86_64-unknown-linux-gnu
    tar -xf $RUST_TAR
    cd rust-$RUST_VER-x86_64-unknown-linux-gnu
    # Only what is needed to compile: no docs, no analysis, no source. --disable-ldconfig
    # because nothing here goes into the shared library path anyway.
    ./install.sh --prefix=/opt/rust \\
                 --components=rustc,cargo,rust-std-x86_64-unknown-linux-gnu \\
                 --disable-ldconfig
    cd /sources/pkg
fi

export PATH=/opt/rust/bin:\$PATH
export CARGO_HOME=/sources/pkg/cargo-home
export HOME=/root
rustc --version
cargo --version

echo "### building weathr ###"
rm -rf /sources/pkg/wr-root /sources/pkg/stage-weathr
cargo install weathr --root /sources/pkg/wr-root --locked

# weathr --version prints its version on the first line and then several lines of data
# attribution (Open-Meteo, Nominatim, OpenStreetMap) including URLs. Taking the last
# field of every line turns the version into a multi-line blob, and bpkg then tries to
# create a package file whose name contains newlines and URLs. Take line one, and take
# only something that looks like a version from it.
VER=\$(/sources/pkg/wr-root/bin/weathr --version 2>/dev/null \\
       | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
[ -n "\$VER" ] || { echo "could not determine weathr version"; exit 1; }
echo "### weathr \$VER ###"

install -d /sources/pkg/stage-weathr/usr/bin
install -m755 /sources/pkg/wr-root/bin/weathr /sources/pkg/stage-weathr/usr/bin/weathr

cd /sources/pkg
bpkg create stage-weathr weathr "\$VER"
mv -f weathr-\$VER.bpkg /sources/packages/
bpkg remove weathr 2>/dev/null || true
bpkg install /sources/packages/weathr-\$VER.bpkg
EOS
chmod +x "$SRC/build-weathr.sh"

echo "==> Building weathr (cargo fetches its own dependencies; this takes a few minutes)"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/pkg/build-weathr.sh > /tmp/weathr.log 2>&1 \
    || { echo "FATAL: weathr build failed"; tail -30 /tmp/weathr.log; exit 1; }
grep -E '^### weathr' /tmp/weathr.log | sed 's/^/    /'

##############################################################################
# Remove the toolchain. It was a build dependency; keeping it would add ~1.5 GB
# and a large amount of attack surface to an image built to be small.
##############################################################################
if [ "$KEEP_RUST" = 1 ]; then
    echo "==> KEEP_RUST=1, leaving /opt/rust in place"
else
    echo "==> Removing the Rust toolchain and cargo caches"
    # Measure the directories being deleted, not the whole tree before and after. Two
    # du passes over 5.5 GB on a loop-mounted image takes minutes to produce a number
    # that is only cosmetic, and it makes the script look hung at the very end.
    doomed=("$LFS/opt/rust" "$SRC/cargo-home" "$SRC/wr-root"
            "$SRC/rust-$RUST_VER-x86_64-unknown-linux-gnu")
    freed=$(du -smc "${doomed[@]}" 2>/dev/null | tail -1 | cut -f1)
    rm -rf "${doomed[@]}"
    echo "    reclaimed ${freed:-?} MB"
fi

echo
echo "==> Result"
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
    bpkg info weathr | sed "s/^/    /"
    echo "    hardening of the built binary:"
    f=/usr/bin/weathr
    printf "      bindnow=%s relro=%s pie=%s\n" \
        "$(readelf -dW $f | grep -qE "BIND_NOW|FLAGS.*\bNOW\b" && echo yes || echo no)" \
        "$(readelf -lW $f | grep -q GNU_RELRO && echo yes || echo no)" \
        "$(readelf -hW $f | grep -qE "Type:[[:space:]]+DYN" && echo yes || echo no)"
'
echo
echo "==> Re-run 08-make-bootable-image.sh to fold this in."
