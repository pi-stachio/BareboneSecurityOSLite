#!/bin/bash
# Build the BLFS "administrable system" package set inside the LFS chroot.
#
# Order matters: libtasn1 -> p11-kit -> make-ca builds the TLS trust store, and curl
# is built before make-ca so there is a working HTTPS client once certs exist.
# Nothing here needs network: 10-blfs-sources.sh already fetched everything, including
# Mozilla's certdata.txt, which is handed to make-ca with -C.
#
# Run as root:  bash 11-blfs-build.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
ADMINUSER=${ADMINUSER:-admin}
ADMINPW=${ADMINPW:-lfs}

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
[ -d "$LFS/sources/blfs" ] || { echo "FATAL: run 10-blfs-sources.sh first"; exit 1; }

echo "==> Mounting virtual kernel filesystems"
mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"     || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -t tmpfs tmpfs "$LFS/run"

# Written unexpanded ('EOS') and executed inside the chroot.
cat > "$LFS/sources/blfs/build-inside.sh" <<'EOS'
#!/bin/bash
set -e
cd /sources/blfs
J=$(nproc)
export MAKEFLAGS="-j$J"

step() { echo; echo "##### $* #####"; }
unpack() { rm -rf "$2"; tar -xf "$1"; cd "$2"; }

step libunistring
unpack libunistring-1.4.1.tar.xz libunistring-1.4.1
# Required by BLFS for glibc-2.43 and later, which is exactly what LFS 13.0 ships.
sed -r '/_GL_EXTERN_C/s/w?memchr|bsearch/(&)/' -i $(find -name \*.in.h)
./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/libunistring-1.4.1
make
make install
cd /sources/blfs

step libidn2
unpack libidn2-2.3.8.tar.gz libidn2-2.3.8
./configure --prefix=/usr --disable-static
make
make install
cd /sources/blfs

step libpsl
unpack libpsl-0.21.5.tar.gz libpsl-0.21.5
mkdir build && cd build
meson setup .. --prefix=/usr --buildtype=release
ninja
ninja install
cd /sources/blfs

step libtasn1
unpack libtasn1-4.21.0.tar.gz libtasn1-4.21.0
./configure --prefix=/usr --disable-static
make
make install
cd /sources/blfs

step p11-kit
unpack p11-kit-0.26.2.tar.xz p11-kit-0.26.2
sed '20,$ d' -i trust/trust-extract-compat
cat >> trust/trust-extract-compat <<'EOF'
# Copy existing anchor modifications to /etc/ssl/local
/usr/libexec/make-ca/copy-trust-modifications
# Update trust stores
/usr/sbin/make-ca -r
EOF
mkdir p11-build && cd p11-build
meson setup .. --prefix=/usr --buildtype=release -D trust_paths=/etc/pki/anchors
ninja
ninja install
ln -sfv /usr/libexec/p11-kit/trust-extract-compat /usr/bin/update-ca-certificates
ln -sfv ./pkcs11/p11-kit-trust.so /usr/lib/libnssckbi.so
cd /sources/blfs

step curl
unpack curl-8.18.0.tar.xz curl-8.18.0
./configure --prefix=/usr --disable-static --with-openssl --with-ca-path=/etc/ssl/certs
make
make install
cd /sources/blfs

step make-ca
unpack make-ca-1.16.1.tar.gz make-ca-1.16.1
make install
install -vdm755 /etc/ssl/local
# -C uses the certdata.txt we staged; make-ca would otherwise try to download it,
# and the chroot has no usable resolver.
/usr/sbin/make-ca -C /sources/blfs/certdata.txt -f
cd /sources/blfs

step sudo
unpack sudo-1.9.17p2.tar.gz sudo-1.9.17p2
./configure --prefix=/usr         \
            --libexecdir=/usr/lib \
            --with-secure-path    \
            --with-env-editor     \
            --docdir=/usr/share/doc/sudo-1.9.17p2 \
            --with-passprompt="[sudo] password for %p: "
make
make install
# No Linux-PAM in LFS base, so BLFS' /etc/pam.d/sudo step is skipped and sudo
# authenticates against /etc/shadow directly.
getent group wheel > /dev/null || groupadd wheel
cat > /etc/sudoers.d/00-sudo <<'EOF'
Defaults secure_path="/usr/sbin:/usr/bin"
%wheel ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/00-sudo
cd /sources/blfs

step dhcpcd
unpack dhcpcd-10.3.0.tar.xz dhcpcd-10.3.0
install -v -m700 -d /var/lib/dhcpcd
getent group dhcpcd  > /dev/null || groupadd -g 52 dhcpcd
getent passwd dhcpcd > /dev/null || useradd -c 'dhcpcd PrivSep' -d /var/lib/dhcpcd \
                                            -g dhcpcd -s /bin/false -u 52 dhcpcd
chown -v dhcpcd:dhcpcd /var/lib/dhcpcd
./configure --prefix=/usr                \
            --sysconfdir=/etc            \
            --libexecdir=/usr/lib/dhcpcd \
            --dbdir=/var/lib/dhcpcd      \
            --runstatedir=/run           \
            --privsepuser=dhcpcd
make
make install
cd /sources/blfs

step openssh
unpack openssh-10.2p1.tar.gz openssh-10.2p1
install -v -g sys -m700 -d /var/lib/sshd
getent group sshd  > /dev/null || groupadd -g 50 sshd
getent passwd sshd > /dev/null || useradd -c 'sshd PrivSep' -d /var/lib/sshd \
                                          -g sshd -s /bin/false -u 50 sshd
./configure --prefix=/usr                            \
            --sysconfdir=/etc/ssh                    \
            --with-privsep-path=/var/lib/sshd        \
            --with-default-path=/usr/bin             \
            --with-superuser-path=/usr/sbin:/usr/bin \
            --with-pid-dir=/run
make
make install
install -v -m755 contrib/ssh-copy-id /usr/bin
install -v -m644 contrib/ssh-copy-id.1 /usr/share/man/man1
cd /sources/blfs

step iputils
unpack iputils-20250605.tar.gz iputils-20250605
# Option names drift between iputils releases; only pass the ones this tree declares,
# otherwise meson aborts on an unknown option.
IOPTS=""
for o in BUILD_MANS BUILD_HTML_MANS SKIP_TESTS; do
    if grep -qs "$o" meson.options meson_options.txt; then
        case $o in
            SKIP_TESTS) IOPTS="$IOPTS -D$o=true" ;;
            *)          IOPTS="$IOPTS -D$o=false" ;;
        esac
    fi
done
echo "iputils meson options:$IOPTS"
meson setup build --prefix=/usr --buildtype=release $IOPTS
ninja -C build
ninja -C build install
cd /sources/blfs

step "bootscripts (sshd + dhcpcd service)"
cd blfs-bootscripts
make install-sshd
make install-service-dhcpcd
cd /sources/blfs

step "system configuration"
# BLFS' recommendation; with root SSH disabled an ordinary admin account is required.
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Use DHCP on eth0 so the image works on any network, not just QEMU's user-net.
cat > /etc/sysconfig/ifconfig.eth0 <<'EOF'
ONBOOT="yes"
IFACE="eth0"
SERVICE="dhcpcd"
DHCP_START="-b -q"
DHCP_STOP="-k"
EOF

echo "installed versions:"
sudo --version | head -1
curl --version | head -1
sshd --version 2>&1 | head -1 || /usr/sbin/sshd --version 2>&1 | head -1 || true
dhcpcd --version | head -1
ping -V 2>&1 | head -1
echo "trust store: $(ls /etc/ssl/certs/*.pem 2>/dev/null | wc -l) certs, bundle $(ls -lh /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | awk '{print $5}')"
EOS

chmod +x "$LFS/sources/blfs/build-inside.sh"

echo "==> Building inside the chroot (this takes a while)"
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/blfs/build-inside.sh

echo
echo "==> Creating the admin account '$ADMINUSER' (wheel group, for sudo and SSH)"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login -c "
        id $ADMINUSER >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash $ADMINUSER
        echo '$ADMINUSER:$ADMINPW' | chpasswd
        id $ADMINUSER
    "

echo
echo "==> Done. Re-run 08-make-bootable-image.sh to fold these into a new disk image."
