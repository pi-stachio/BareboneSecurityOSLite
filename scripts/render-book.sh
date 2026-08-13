#!/bin/bash
# Render the LFS 13.0 SysV book locally, plus a dump of every command block.
#
# linuxfromscratch.org may be unreachable (it refuses connections from some networks),
# so this builds the book from the project's official GitHub mirror instead. The output
# is not redistributed in this repository because the book is licensed separately.
#
# Run as root:  bash render-book.sh [output-dir]
set -euo pipefail

OUT=${1:-/root/lfs-book}
CMDS=${2:-/root/lfs-commands}
SRC=/root/lfs-book-src
TAG=${LFS_TAG:-r13.0}

echo "==> Installing the DocBook toolchain"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    docbook-xml docbook-xsl xsltproc tidy libxml2-utils git > /dev/null

echo "==> Cloning the LFS book at $TAG"
rm -rf "$SRC"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/lfs-book/lfs.git "$SRC"

echo "==> Rendering (REV=sysv)"
cd "$SRC"
make REV=sysv BASEDIR="$OUT" DUMPDIR="$CMDS" book nochunks dump-commands

echo
echo "==> Book:     $OUT/index.html"
echo "==> Commands: $CMDS ($(find "$CMDS" -type f | wc -l) files)"
