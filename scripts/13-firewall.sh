#!/bin/bash
# Build nftables and install a default-deny inbound firewall.
#
# nftables is *archived* in BLFS r13.0 (the current book documents iptables instead),
# and the archived page's version entities are gone. So versions come from upstream
# netfilter.org, verified against the .sha256sum files they publish alongside each
# tarball. libmnl is still in the current book, so that one keeps the book's md5.
#
# Run as root:  bash 13-firewall.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SRC="$LFS/sources/blfs"
BLFS=/root/blfs-src
NFT_V=1.1.6
NFTNL_V=1.3.1
MNL_V=1.0.5

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
mkdir -p "$SRC"; cd "$SRC"

echo "==> Downloading and verifying"
get_sha256() {   # upstream publishes <file>.sha256sum next to the tarball
    local f=$1 url=$2
    [ -f "$f" ] || curl -sSfL --retry 3 -o "$f" "$url"
    curl -sSfL --retry 3 -o "$f.sha256sum" "$url.sha256sum"
    local want got
    want=$(grep -oE '[0-9a-f]{64}' "$f.sha256sum" | head -1)
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then echo "OK:    $f sha256 matches upstream"
    else echo "ERROR: $f sha256 mismatch (want $want got $got)"; exit 1; fi
}

# libmnl is still in the current book, so verify against the book's md5 instead.
if [ ! -f "libmnl-$MNL_V.tar.bz2" ]; then
    curl -sSfL --retry 3 -o "libmnl-$MNL_V.tar.bz2" \
        "https://netfilter.org/projects/libmnl/files/libmnl-$MNL_V.tar.bz2"
fi
want=$(grep -hoE '<!ENTITY[[:space:]]+libmnl-md5sum[[:space:]]+"[0-9a-f]{32}"' \
         "$BLFS/packages.ent" "$BLFS/networking/netlibs/libmnl.xml" 2>/dev/null \
       | grep -oE '[0-9a-f]{32}' | head -1 || true)
got=$(md5sum "libmnl-$MNL_V.tar.bz2" | cut -d' ' -f1)
[ "$want" = "$got" ] && echo "OK:    libmnl md5 matches the BLFS book" \
                     || { echo "ERROR: libmnl md5 mismatch"; exit 1; }

get_sha256 "libnftnl-$NFTNL_V.tar.xz" \
    "https://www.netfilter.org/pub/libnftnl/libnftnl-$NFTNL_V.tar.xz"
get_sha256 "nftables-$NFT_V.tar.xz" \
    "https://www.netfilter.org/pub/nftables/nftables-$NFT_V.tar.xz"

echo
echo "==> Writing the ruleset"
cat > "$LFS/etc/nftables.conf" <<'EOF'
#!/usr/sbin/nft -f
# Default-deny inbound firewall.
#   input   : drop everything except loopback, replies to our own traffic, and SSH
#   forward : drop (this is not a router)
#   output  : allow (so the box can fetch updates and resolve DNS)
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        # ICMP is needed for path MTU discovery; without it large packets black-hole.
        ip  protocol icmp   icmp   type { echo-request, echo-reply, destination-unreachable, time-exceeded, parameter-problem } accept
        ip6 nexthdr  icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept

        tcp dport 22 ct state new accept comment "ssh"

        counter comment "dropped-inbound"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
chmod 600 "$LFS/etc/nftables.conf"

echo "==> Writing the init script"
cat > "$LFS/etc/rc.d/init.d/nftables" <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:            nftables
# Required-Start:      $local_fs
# Should-Start:
# Required-Stop:
# Should-Stop:
# Default-Start:       3 4 5
# Default-Stop:        0 1 2 6
# Short-Description:   Loads the nftables firewall ruleset
# Description:         Applies /etc/nftables.conf, a default-deny inbound policy.
# X-LFS-Provided-By:   BareboneSecurityOSLite
### END INIT INFO
. /lib/lsb/init-functions

case "$1" in
    start)
        log_info_msg "Loading nftables ruleset..."
        /usr/sbin/nft -f /etc/nftables.conf
        evaluate_retval
        ;;
    stop)
        log_info_msg "Flushing nftables ruleset..."
        /usr/sbin/nft flush ruleset
        evaluate_retval
        ;;
    restart|reload)
        $0 stop; sleep 1; $0 start
        ;;
    status)
        /usr/sbin/nft list ruleset
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|reload|status}"
        exit 1
        ;;
esac
EOF
chmod 754 "$LFS/etc/rc.d/init.d/nftables"

cat > "$LFS/sources/blfs/firewall-inside.sh" <<EOS
#!/bin/bash
set -e
cd /sources/blfs
export MAKEFLAGS="-j\$(nproc)"
unpack() { rm -rf "\$2"; tar -xf "\$1"; cd "\$2"; }

echo "##### libmnl #####"
unpack libmnl-$MNL_V.tar.bz2 libmnl-$MNL_V
./configure --prefix=/usr --disable-static
make && make install
cd /sources/blfs

echo "##### libnftnl #####"
unpack libnftnl-$NFTNL_V.tar.xz libnftnl-$NFTNL_V
./configure --prefix=/usr --disable-static
make && make install
# NOTE: the archived BLFS page moves libnftnl.so.* into /lib here. LFS 13.0 has a
# merged /usr (/lib is a symlink to /usr/lib), so that move is a no-op at best and an
# error at worst. Skipped deliberately.
cd /sources/blfs

echo "##### nftables #####"
unpack nftables-$NFT_V.tar.xz nftables-$NFT_V
# --with-json needs jansson and --enable-man-doc needs asciidoc; neither is in LFS.
# --with-cli defaults to libedit, which LFS does not ship; GNU readline does exist,
# so point the interactive CLI at that instead of disabling it.
./configure --prefix=/usr        \\
            --sbindir=/usr/sbin  \\
            --sysconfdir=/etc    \\
            --disable-static     \\
            --disable-man-doc    \\
            --with-cli=readline  \\
            --with-python-bin=/usr/bin/python3
make && make install
cd /sources/blfs

echo "##### enabling at boot #####"
# Load the firewall before the network comes up, and tear it down last.
ln -sfv ../init.d/nftables /etc/rc.d/rc3.d/S18nftables
ln -sfv ../init.d/nftables /etc/rc.d/rc4.d/S18nftables
ln -sfv ../init.d/nftables /etc/rc.d/rc5.d/S18nftables
for r in 0 1 2 6; do ln -sfv ../init.d/nftables /etc/rc.d/rc\$r.d/K82nftables; done

echo "##### verification #####"
nft --version
nft -c -f /etc/nftables.conf && echo "ruleset syntax OK"
ls -l /etc/rc.d/rc3.d/ | grep -E 'nftables|network|sshd'
EOS

echo "==> Building in the chroot"
mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"
chmod +x "$LFS/sources/blfs/firewall-inside.sh"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/blfs/firewall-inside.sh

echo
echo "==> Firewall installed."
