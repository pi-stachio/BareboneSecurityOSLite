#!/bin/bash
# LFS 13.0 host preparation for a WSL2 Debian instance.
# Run as root inside the lfs-host distro:  bash 00-host-setup.sh
set -euo pipefail

echo "==> Writing /etc/wsl.conf"
# appendWindowsPath=false is critical: without it the Windows PATH leaks into the
# build environment and configure scripts happily detect .exe files as tools.
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=false

[interop]
enabled=true
appendWindowsPath=false

[automount]
enabled=true
options="metadata"
EOF

echo "==> Pointing /bin/sh at bash (Debian defaults to dash; LFS requires bash)"
echo "dash dash/sh boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash
# dpkg-reconfigure records the answer but does not always move the symlink, so force it.
ln -sfv /bin/bash /bin/sh

echo "==> Installing host build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential bison gawk texinfo m4 patch perl python3 python3-venv \
    xz-utils gzip bzip2 zstd tar cpio file diffutils findutils grep sed \
    binutils make wget curl ca-certificates git bc flex libelf-dev \
    libssl-dev rsync sudo less vim-tiny e2fsprogs kmod util-linux \
    pkg-config gettext

echo "==> Ensuring awk -> gawk and yacc -> bison"
if [ -e /usr/bin/gawk ]; then
    update-alternatives --set awk /usr/bin/gawk 2>/dev/null || ln -sfv /usr/bin/gawk /usr/bin/awk
fi
if [ ! -e /usr/bin/yacc ]; then
    ln -sfv /usr/bin/bison /usr/bin/yacc
fi

echo "==> Running the LFS version-check script"
cd /root
if [ ! -f version-check.sh ]; then
    wget -q https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html -O /dev/null 2>/dev/null || true
fi
bash "$(dirname "$0")/version-check.sh"

echo
echo "==> Host setup complete."
echo "    Run 'wsl --shutdown' from Windows so /etc/wsl.conf takes effect."
