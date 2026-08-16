#!/bin/bash
# Build any package from a recipe and install it with bpkg.
#
# The seed packages in 22-seed-packages.sh were hand-written build scripts, which is fine
# for three of them and unmaintainable for thirty. A recipe is a few lines of shell
# declaring where the source is and how to build it; everything else -- downloading,
# checksum pinning, staging with DESTDIR, packaging, installing -- happens here.
#
#   bash 23-build-package.sh recipes/links.recipe
#
# Recipe format (see recipes/*.recipe):
#   name=       package name
#   version=    version string
#   url=        source tarball
#   sha256=     expected checksum, or empty on the first run to be told what it is
#   build()     runs in the unpacked source tree; install into $PKGDIR
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
RECIPE=${1:-}
[ -n "$RECIPE" ] || { echo "usage: $0 <recipe>"; exit 1; }
[ -f "$RECIPE" ] || { echo "FATAL: no such recipe: $RECIPE"; exit 1; }
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

# Read the metadata on the host to work out what to fetch. build() is not run here.
name=""; version=""; url=""; sha256=""
# shellcheck disable=SC1090
source "$RECIPE"
[ -n "$name" ] && [ -n "$version" ] && [ -n "$url" ] \
    || { echo "FATAL: recipe must set name, version and url"; exit 1; }

SRC="$LFS/sources/pkg"
PKGOUT="$LFS/sources/packages"
mkdir -p "$SRC" "$PKGOUT"
install -m755 "$SCRIPTS/bpkg.sh" "$LFS/usr/bin/bpkg"
sed -i 's/\r$//' "$LFS/usr/bin/bpkg"

tarball=$(basename "$url")
if [ ! -f "$SRC/$tarball" ]; then
    echo "==> Fetching $tarball"
    curl -fsSL -o "$SRC/$tarball" "$url" || { echo "FATAL: download failed"; exit 1; }
fi

got=$(sha256sum "$SRC/$tarball" | cut -d' ' -f1)
if [ -z "$sha256" ]; then
    # Deliberately loud. Recording the hash of whatever just downloaded is a pin, not a
    # verification -- it protects future builds from a changed tarball, but says nothing
    # about whether this one is genuine. Check it against upstream before trusting it.
    echo "WARNING: this recipe has no sha256. The file that just downloaded hashes to:"
    echo "    sha256=$got"
    echo "  Add that to the recipe to pin it. Confirm it against upstream first --"
    echo "  a self-recorded hash only proves the file has not changed since you fetched it."
elif [ "$got" != "$sha256" ]; then
    echo "FATAL: checksum mismatch for $tarball"
    echo "  expected $sha256"
    echo "  got      $got"
    exit 1
else
    echo "==> $tarball checksum OK"
fi

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

install -m644 "$RECIPE" "$LFS/sources/pkg/current.recipe"

cat > "$LFS/sources/pkg/build-recipe.sh" <<'EOS'
#!/bin/bash
set -e
cd /sources/pkg
source ./current.recipe

srcdir=""
rm -rf "stage-$name"
PKGDIR=/sources/pkg/stage-$name
export PKGDIR
mkdir -p "$PKGDIR"

tarball=$(basename "$url")
# Find the directory the tarball unpacks into rather than assuming name-version: plenty
# of projects disagree with that convention, and guessing wrong fails confusingly.
srcdir=$(tar -tf "$tarball" | head -1 | sed 's@^\./@@;s@/.*@@')
rm -rf "$srcdir"
tar -xf "$tarball"
cd "$srcdir"

export MAKEFLAGS="-j$(nproc)"
build

cd /sources/pkg
bpkg create "stage-$name" "$name" "$version"
mv -f "$name-$version.bpkg" /sources/packages/
EOS
chmod +x "$LFS/sources/pkg/build-recipe.sh"

echo "==> Building $name $version"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/pkg/build-recipe.sh > "/tmp/$name-build.log" 2>&1 \
    || { echo "FATAL: build failed"; tail -30 "/tmp/$name-build.log"; exit 1; }

echo "==> Installing"
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c "
    bpkg remove $name 2>/dev/null || true
    bpkg install /sources/packages/$name-$version.bpkg
"

echo
echo "==> Done"
ls -lh "$PKGOUT/$name-$version.bpkg" | awk '{printf "    %s  %s\n", $9, $5}'
