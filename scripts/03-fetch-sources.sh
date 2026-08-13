#!/bin/bash
# Download every LFS 13.0 source tarball + patch into $LFS/sources and verify md5sums.
#
# NOTE: linuxfromscratch.org itself refuses connections from this network, so we pull
# the complete package set straight from an OSU Open Source Lab mirror instead of
# using the book's wget-list (whose URLs point at ~90 different upstream hosts).
# Run as root:  bash 03-fetch-sources.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
MIRROR=${LFS_MIRROR:-https://ftp.osuosl.org/pub/lfs/lfs-packages/13.0}
SRC="$LFS/sources"

mountpoint -q "$LFS" || { echo "FATAL: $LFS is not mounted. Run 01-lfs-partition.sh first."; exit 1; }
mkdir -pv "$SRC"
cd "$SRC"

echo "==> Fetching md5sums and wget-list from $MIRROR"
curl -sSfL -o md5sums   "$MIRROR/md5sums"
curl -sSfL -o wget-list "$MIRROR/wget-list"
echo "    $(wc -l < md5sums) packages listed"

echo "==> Downloading packages from the mirror (resumable, 4 parallel)"
awk '{print $2}' md5sums | sed '/^$/d' > .filelist
xargs -a .filelist -P 4 -I{} \
    curl -sSfL --retry 3 --retry-delay 2 -C - -o {} "$MIRROR/{}" \
    || echo "!! some downloads failed; re-run this script to resume"

echo
echo "==> Verifying md5sums"
if md5sum -c md5sums --quiet; then
    echo "==> All $(wc -l < md5sums) packages verified OK"
else
    echo "!! Checksum failures above. Delete the offending files and re-run."
    exit 1
fi

rm -f .filelist
chown -R lfs:lfs "$SRC" 2>/dev/null || true
du -sh "$SRC"
