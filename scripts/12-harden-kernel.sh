#!/bin/bash
# Rebuild the kernel with hardening options and built-in netfilter.
#
# Two things make this more than a list of toggles:
#
#  * CONFIG_MODULES=n removes loadable-module support entirely. Nothing in this system
#    needs it (every driver we use is built in), and it eliminates a whole class of
#    rootkit. But it also means every tristate symbol that defconfig left as =m is now
#    simply dropped -- so anything we actually need must be forced to =y explicitly.
#    That is why the netfilter symbols below are set one by one.
#
#  * The config is resolved with the *target* compiler inside the chroot, for the same
#    reason 05b exists: compiler-dependent symbols differ between host and target.
#
# Run as root:  bash 12-harden-kernel.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
KVER=6.18.10
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

echo "==> Mounting virtual kernel filesystems"
mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

cat > "$LFS/sources/harden-kernel-inside.sh" <<'EOS'
#!/bin/bash
set -e
KVER=6.18.10

# Stand the hardened userland specs down for the kernel build (see 16-harden-toolchain.sh).
# The kernel supplies its own -fno-PIE, -fcf-protection=none and stack-protector flags and
# an explicit command-line flag does beat -fhardened -- but a blanket -fno-hardened does
# NOT, because self_spec is applied after the command line. There is no way to opt out
# from the kernel's Makefile, so the specs file is moved aside instead. The trap puts it
# back even if the build fails, so a failed kernel cannot silently unharden userland.
SPECS=$(dirname "$(gcc -print-libgcc-file-name)")/specs
if [ -f "$SPECS" ]; then
    mv "$SPECS" "$SPECS.disabled"
    trap 'mv -f "$SPECS.disabled" "$SPECS" 2>/dev/null || true' EXIT
    echo "### userland hardening specs stood down for the kernel build ###"
fi

cd /sources
[ -d "linux-$KVER" ] || tar -xf "linux-$KVER.tar.xz"
cd "linux-$KVER"
cp -v /sources/kernel-config .config

echo "### applying hardening options ###"
c() { scripts/config "$@"; }

# --- exploit mitigation -------------------------------------------------------
c --enable  RANDOMIZE_BASE              # KASLR
c --enable  RANDOMIZE_MEMORY
c --enable  STRICT_KERNEL_RWX
c --enable  VMAP_STACK
c --enable  HARDENED_USERCOPY
c --enable  FORTIFY_SOURCE
c --enable  STACKPROTECTOR
c --enable  STACKPROTECTOR_STRONG
c --enable  INIT_ON_ALLOC_DEFAULT_ON    # zero heap on allocation
c --enable  INIT_ON_FREE_DEFAULT_ON     # and on free (costs some throughput)
c --enable  SLAB_FREELIST_RANDOM
c --enable  SLAB_FREELIST_HARDENED
c --enable  RANDOM_KMALLOC_CACHES
c --enable  BUG_ON_DATA_CORRUPTION
c --enable  SCHED_STACK_END_CHECK
c --enable  DEBUG_WX                    # warn on writable+executable mappings
c --enable  IO_STRICT_DEVMEM
c --enable  SECURITY_DMESG_RESTRICT

# --- attack surface removal ---------------------------------------------------
c --disable MODULES                     # no loadable modules at all
c --disable DEVMEM                      # no /dev/mem
c --disable PROC_KCORE
c --disable KEXEC
c --disable KEXEC_FILE
c --disable HIBERNATION
c --disable IA32_EMULATION              # userland is pure 64-bit
c --disable X86_VSYSCALL_EMULATION
c --set-val LEGACY_VSYSCALL_NONE y

# --- LSMs: containment without policy files to maintain ------------------------
c --enable  SECURITY
c --enable  SECURITYFS                  # /sys/kernel/security: lets us audit LSM state
c --enable  SECURITY_YAMA               # ptrace scope
c --enable  SECURITY_LANDLOCK           # unprivileged sandboxing
c --enable  SECURITY_LOCKDOWN_LSM
c --enable  SECURITY_LOCKDOWN_LSM_EARLY
c --set-str LSM "landlock,lockdown,yama,bpf"

# --- netfilter, built in because there are no modules --------------------------
for opt in NETFILTER NETFILTER_ADVANCED NETFILTER_NETLINK NETFILTER_NETLINK_QUEUE \
           NF_CONNTRACK NF_TABLES NF_TABLES_INET NFT_CT NFT_COUNTER NFT_LOG \
           NFT_REJECT NFT_REJECT_INET NF_REJECT_IPV4 NF_REJECT_IPV6 \
           NF_DEFRAG_IPV4 NF_DEFRAG_IPV6 NF_LOG_SYSLOG; do
    c --enable "$opt"
done

echo "### resolving with the target compiler ###"
make olddefconfig

echo
echo "### verifying: these MUST be built in ###"
fail=0
for o in CONFIG_RANDOMIZE_BASE CONFIG_HARDENED_USERCOPY CONFIG_FORTIFY_SOURCE \
         CONFIG_STACKPROTECTOR_STRONG CONFIG_INIT_ON_ALLOC_DEFAULT_ON \
         CONFIG_SLAB_FREELIST_HARDENED CONFIG_SECURITYFS \
         CONFIG_SECURITY_YAMA CONFIG_SECURITY_LANDLOCK \
         CONFIG_SECURITY_LOCKDOWN_LSM CONFIG_NF_TABLES CONFIG_NF_TABLES_INET \
         CONFIG_NF_CONNTRACK CONFIG_NFT_CT CONFIG_NFT_REJECT_INET \
         CONFIG_EXT4_FS CONFIG_BLK_DEV_SD CONFIG_SATA_AHCI CONFIG_ATA_PIIX \
         CONFIG_VIRTIO_BLK CONFIG_E1000 CONFIG_SERIAL_8250_CONSOLE CONFIG_DEVTMPFS_MOUNT; do
    if grep -q "^$o=y" .config; then printf 'OK:    %s=y\n' "$o"
    else printf 'ERROR: %s is NOT built in\n' "$o"; fail=1; fi
done

echo
echo "### verifying: these MUST be off ###"
for o in CONFIG_MODULES CONFIG_DEVMEM CONFIG_PROC_KCORE CONFIG_KEXEC \
         CONFIG_HIBERNATION CONFIG_IA32_EMULATION CONFIG_UEVENT_HELPER; do
    if grep -q "^$o=y" .config; then printf 'ERROR: %s is still enabled\n' "$o"; fail=1
    else printf 'OK:    %s disabled\n' "$o"; fi
done
[ "$fail" = 0 ] || { echo "config verification FAILED"; exit 1; }

echo
echo "### building (this takes a while) ###"
make -j"$(nproc)"

echo "### installing ###"
cp -v arch/x86/boot/bzImage "/boot/vmlinuz-$KVER-lfs-r13.0"
cp -v System.map "/boot/System.map-$KVER"
cp -v .config "/boot/config-$KVER"
cp -v .config /sources/kernel-config          # so rebuilds keep the hardening
echo "### done ###"
EOS

chmod +x "$LFS/sources/harden-kernel-inside.sh"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/harden-kernel-inside.sh

echo
echo "==> Hardened kernel installed. Re-run 08-make-bootable-image.sh."
