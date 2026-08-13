#!/bin/bash
# Configure jhalfs non-interactively and generate the build Makefile.
#
# jhalfs is normally driven through menuconfig. Its Makefile invokes kconfiglib with
# CONFIG_="" (no symbol prefix), so we can write a small fragment and let kconfiglib
# fill in every other symbol's default, producing a valid 'configuration' file.
#
# Run as root:  bash 06-configure-jhalfs.sh
set -euo pipefail

JH=/root/jhalfs
LFS=${LFS:-/mnt/lfs}

echo "==> Writing fstab for the target system"
cat > /root/lfs/fstab <<'EOF'
# file system  mount-point    type     options             dump  fsck order
/dev/sda1      /              ext4     defaults            1     1
proc           /proc          proc     nosuid,noexec,nodev 0     0
sysfs          /sys           sysfs    nosuid,noexec,nodev 0     0
devpts         /dev/pts       devpts   gid=5,mode=620      0     0
tmpfs          /run           tmpfs    defaults            0     0
devtmpfs       /dev           devtmpfs mode=0755,nosuid    0     0
tmpfs          /dev/shm       tmpfs    nosuid,nodev        0     0
cgroup2        /sys/fs/cgroup cgroup2  nosuid,noexec,nodev 0     0
EOF

echo "==> jhalfs will manage the build user; removing our smoke-test one"
userdel -r lfs 2>/dev/null || true

echo "==> Writing jhalfs config fragment"
cat > /root/lfs/jhalfs.frag <<EOF
BOOK_LFS_ANY=y
BOOK_LFS=y
WORKING_COPY=y
BOOK="/root/lfs-book-src"
LFS_MULTILIB_NO=y
BUILD_CHROOT=y
LUSER="lfs"
LGROUP="lfs"
LHOME="/home"
BUILDDIR="$LFS"
GETPKG=n
SRC_ARCHIVE="$LFS/sources"
RUNMAKE=n
CLEAN=n
N_PARALLEL=8
REALSBU=n
CONFIG_TESTS=n
KEEPDIR=n
TEST_MISMATCH=n
PKGMNGT=n
INSTALL_LOG=n
STRIP=y
NO_PROGRESS_BAR=y
BLFS_TOOL=n
HAVE_FSTAB=y
FSTAB="/root/lfs/fstab"
CONFIG_BUILD_KERNEL=y
CONFIG="/root/lfs/kernel.config"
EOF

echo "==> Expanding fragment into a full jhalfs 'configuration'"
cd "$JH"
CONFIG_="" python3 - <<'PY'
import os, sys
sys.path.insert(0, "menu")
os.environ["CONFIG_"] = ""
import kconfiglib
kconf = kconfiglib.Kconfig("Config.in", warn_to_stderr=False)
kconf.load_config("/root/lfs/jhalfs.frag", replace=True)
kconf.write_config("configuration")
print("wrote configuration with %d symbols" % len(kconf.syms))
PY

echo
echo "==> Key settings actually recorded:"
grep -E '^(BOOK|BOOK_LFS|WORKING_COPY|BUILDDIR|LUSER|LGROUP|METHOD|INITSYS|GETPKG|RUNMAKE|N_PARALLEL|TEST|STRIP|CONFIG|FSTAB|CONFIG_BUILD_KERNEL|HAVE_FSTAB|MULTILIB)=' configuration

echo
echo "==> Running jhalfs to generate the build Makefile"
# jhalfs asks two confirmations ("Do you want to run jhalfs?" and "Are you happy with
# these settings?"); the second compares against the literal string "yes", so feed that
# rather than the `yes` command's default "y".
yes yes | ./jhalfs run

echo
echo "==> Generated build system:"
ls "$LFS/jhalfs" 2>/dev/null | head
