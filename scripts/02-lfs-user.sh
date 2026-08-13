#!/bin/bash
# Create the unprivileged 'lfs' build user and its environment (book chapter 4.3/4.4).
# Run as root:  bash 02-lfs-user.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
mountpoint -q "$LFS" || { echo "FATAL: $LFS is not mounted. Run 01-lfs-partition.sh first."; exit 1; }

if ! getent group lfs > /dev/null; then
    echo "==> Creating group lfs"; groupadd lfs
fi
if ! id lfs &> /dev/null; then
    echo "==> Creating user lfs"
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi

echo "==> Handing the LFS tree to user lfs"
chown -v lfs "$LFS"/{usr{,/*},lib,var,etc,bin,sbin,tools,lib64,sources}

echo "==> Writing ~lfs/.bash_profile"
cat > /home/lfs/.bash_profile <<'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

echo "==> Writing ~lfs/.bashrc"
cat > /home/lfs/.bashrc <<'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS=-j$(nproc)
EOF

chown lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc

# Debian ships /etc/bash.bashrc, which would leak host settings into the build shell.
if [ -e /etc/bash.bashrc ]; then
    echo "==> Moving /etc/bash.bashrc out of the way"
    mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE
fi

echo
echo "==> Done. Enter the build environment with:"
echo "     wsl -d lfs-host -u lfs"
