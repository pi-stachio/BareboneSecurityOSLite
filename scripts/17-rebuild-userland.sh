#!/bin/bash
# Tier 3, part 2: rebuild all of LFS chapter 8 with the hardened compiler.
#
# This does not reimplement the build. jhalfs already extracted every chapter 8 command
# from the book into $LFS/jhalfs/lfs-commands/chapter08/, and those scripts are still on
# disk from the original run. We re-execute them, in book order, against the compiler
# that 16-harden-toolchain.sh just modified. Same commands, same versions, hardened output.
#
# Driving the scripts directly rather than via jhalfs' Makefile is deliberate: its targets
# are phony and chain back through chapters 5-7, so asking make for any chapter 8 target
# would rebuild the cross-toolchain as the `lfs` user first.
#
# Two packages are built with "no-fortify" specs -- CET, stack-clash and link hardening,
# but no _FORTIFY_SOURCE:
#
#   803-glibc  glibc *provides* the fortified implementations; compiling glibc itself
#              against them is circular, and upstream does not support it. It already
#              builds with --enable-stack-protector=strong from the book.
#   828-gcc    hardening the compiler protects nothing that matters here, and gcc builds
#              its own target libraries (libgcc, libstdc++) with the freshly built xgcc,
#              which does not read the installed specs file -- so -fhardened would be
#              half-applied at best. Those libraries get their hardening through
#              {C,LD}FLAGS_FOR_TARGET below instead, which is the supported route.
#
# They get CET rather than being excluded outright because the IBT/SHSTK note in
# .note.gnu.property only survives if every input object carries it. glibc contributes
# crt1.o/crti.o/crtn.o to every single binary in the system, so a glibc without
# -fcf-protection silently strips CET marking from the entire OS -- the endbr64
# instructions stay, but the loader never enforces them. Found by spot-checking a rebuilt
# binary at package 9 of 83 and seeing cet=no where it should have been cet=yes.
#
# Resumable: each completed package drops a stamp, so re-running continues where it
# stopped. To force one package to rebuild, delete its stamp.
#
# Run as root:  bash 17-rebuild-userland.sh
set -euo pipefail

# Reset SIGINT/SIGQUIT to their default disposition before anything else. A shell that
# starts a background job without job control sets them to SIG_IGN, that gets inherited
# all the way into the chroot, and CPython then refuses to install its own SIGINT handler
# -- which fails test_generators during Python's PGO training run and kills the build
# roughly two hours in. This is the same trap 07-run-build.sh works around.
if [ "${T3_SIGRESET:-}" != "1" ]; then
    export T3_SIGRESET=1
    exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV' "$0" "$@"
fi

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
CMDDIR="$LFS/jhalfs/lfs-commands/chapter08"
STAMPS="$LFS/jhalfs/tier3-stamps"
LOGS="$LFS/jhalfs/tier3-logs"
NOFORTIFY_PKGS=${NOFORTIFY_PKGS:-"803-glibc 828-gcc"}
LINK_ONLY_PKGS=${LINK_ONLY_PKGS:-""}

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
[ -d "$CMDDIR" ] || { echo "FATAL: no jhalfs chapter 8 commands at $CMDDIR"; exit 1; }
mkdir -p "$STAMPS" "$LOGS"

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

##############################################################################
# Keep the GMP portability fix. jhalfs' 820-gmp is the stock book command, which lets
# GMP probe the build CPU and bake in -march=broadwell. Rebuilding it unpatched would
# quietly reintroduce the SIGILL defect that made v1.0.0 and v1.1.0 unusable on older
# hardware -- and it would do so *underneath* gcc, which links libgmp.
##############################################################################
if ! grep -q 'host=none-linux-gnu' "$CMDDIR/820-gmp"; then
    sed -i 's|^\( *\)--disable-static \\$|\1--disable-static \\\n\1--host=none-linux-gnu \\|' \
        "$CMDDIR/820-gmp"
    echo "==> patched 820-gmp with --host=none-linux-gnu"
fi
grep -q 'host=none-linux-gnu' "$CMDDIR/820-gmp" \
    || { echo "FATAL: could not patch 820-gmp; refusing to rebuild a CPU-locked GMP"; exit 1; }

##############################################################################
# Make the book's symlink commands survive a second run.
#
# The book writes `ln -sv`, which is correct exactly once: on a rebuild the link already
# exists and ln fails, which trips `set -e` and kills the package. Six of them do this
# (gcc's /usr/lib/cpp and cc.1, gawk's awk.1, vim's vi, vi.1 and doc link).
#
# -n as well as -f, not just -f: vim's link points at a *directory*, and `ln -sf` on a
# symlink-to-directory helpfully creates the new link inside it instead of replacing it.
# Everything else in chapter 8 is already re-runnable -- the patches and `mkdir build`
# calls all operate on a source tree that the wrapper re-extracts from the tarball first.
##############################################################################
if ! grep -q 'ln -sfnv' "$CMDDIR/828-gcc"; then
    sed -i -E 's/\bln -svr\b/ln -sfnvr/g; s/\bln -sv\b/ln -sfnv/g' "$CMDDIR"/8[0-9][0-9]-*
    echo "==> made chapter 8 symlink commands idempotent"
fi

##############################################################################
# The package list, in book order. 884-cleanup is excluded: it deletes the `tester`
# account that no longer exists, so it fails under `set -e` on a second run. Its useful
# half is done explicitly at the end instead.
##############################################################################
PKGS=$(cd "$CMDDIR" && ls | grep -E '^8[0-9]{2}-' | grep -v '^884-cleanup$' | sort)
TOTAL=$(wc -w <<< "$PKGS")

CURRENT_MODE=""
set_specs() {
    [ "$CURRENT_MODE" = "$1" ] && return 0
    echo "    -- switching toolchain to '$1' specs"
    bash "$SCRIPTS/16-harden-toolchain.sh" "$1" > "$LOGS/specs-$1.log" 2>&1 \
        || { echo "FATAL: toolchain switch to $1 failed; see $LOGS/specs-$1.log"; exit 1; }
    CURRENT_MODE=$1
}

echo "=============================================================="
echo " Tier 3 userland rebuild -- $TOTAL packages"
echo " started $(date)"
echo "=============================================================="

n=0
for p in $PKGS; do
    n=$((n+1))
    if [ -f "$STAMPS/$p" ]; then
        printf '[%3d/%3d] %-18s skipped (stamp present)\n' "$n" "$TOTAL" "$p"
        continue
    fi

    case " $LINK_ONLY_PKGS " in
        *" $p "*) set_specs link-only ;;
        *) case " $NOFORTIFY_PKGS " in
               *" $p "*) set_specs no-fortify ;;
               *)        set_specs full ;;
           esac ;;
    esac

    printf '[%3d/%3d] %-18s %s ... ' "$n" "$TOTAL" "$p" "$(date +%H:%M:%S)"
    start=$SECONDS

    # gcc builds libgcc/libstdc++ with the compiler it just built, which never sees our
    # installed specs file. These are the only channel that reaches those libraries.
    EXTRA=()
    if [ "$p" = "828-gcc" ]; then
        EXTRA=(CFLAGS_FOR_TARGET="-O2 -g -fcf-protection=full -fstack-clash-protection"
               CXXFLAGS_FOR_TARGET="-O2 -g -fcf-protection=full -fstack-clash-protection"
               LDFLAGS_FOR_TARGET="-Wl,-z,relro,-z,now")
    fi

    if chroot "$LFS" /usr/bin/env -i \
            HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
            TEST_LOG=/dev/null "${EXTRA[@]}" \
            /bin/bash --login "/jhalfs/lfs-commands/chapter08/$p" \
            > "$LOGS/$p.log" 2>&1 < /dev/null; then
        touch "$STAMPS/$p"
        printf 'ok (%ds)\n' "$((SECONDS-start))"
    else
        printf 'FAILED (%ds)\n' "$((SECONDS-start))"
        echo
        echo "---- last 40 lines of $LOGS/$p.log ----"
        tail -40 "$LOGS/$p.log"
        echo "---------------------------------------"
        echo "Fix, then re-run this script; completed packages are skipped."
        echo "To build just this one without -fhardened (keeping CET):"
        echo "    NOFORTIFY_PKGS='$NOFORTIFY_PKGS $p' bash $0"
        echo "Or with link hardening only:"
        echo "    LINK_ONLY_PKGS='$LINK_ONLY_PKGS $p' bash $0"
        exit 1
    fi
done

##############################################################################
# The safe part of 884-cleanup. Rebuilding regenerates libtool archives, and LFS removes
# them because they record link paths that no longer exist and break later builds.
##############################################################################
echo
echo "==> post-build cleanup"
set_specs full
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
    find /usr/lib /usr/libexec -name \*.la -delete
    find /usr -depth -name $(uname -m)-lfs-linux-gnu\* -exec rm -rf {} + 2>/dev/null || true
    rm -rf /sources/*-build /tmp/* 2>/dev/null || true
'
echo "    done"

echo
echo "==> verifying the result"
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
now=0; lazy=0; cet=0; nocet=0
for f in $(find /usr/bin /usr/sbin /usr/lib -maxdepth 1 -type f \
             \( -perm -u+x -o -name "*.so*" \) 2>/dev/null); do
    readelf -W -d -n "$f" > /tmp/d 2>/dev/null || continue
    grep -q "Dynamic section at offset" /tmp/d || continue
    if grep -qE "BIND_NOW|FLAGS.*\bNOW\b" /tmp/d; then now=$((now+1)); else lazy=$((lazy+1)); fi
    if grep "x86 feature:" /tmp/d | grep -q IBT; then cet=$((cet+1)); else nocet=$((nocet+1)); fi
done
rm -f /tmp/d
echo "    full RELRO (BIND_NOW):  $now   (lazy remaining: $lazy)"
echo "    CET IBT/SHSTK marked:   $cet   (unmarked: $nocet)"
'
# The crt objects are the ones that decide CET marking for everything else, so name them.
echo "    glibc crt objects:"
chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
for o in /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o; do
    if readelf -nW "$o" 2>/dev/null | grep "x86 feature:" | grep -q IBT
    then echo "      $o: IBT/SHSTK"; else echo "      $o: NO CET PROPERTY"; fi
done'

echo
echo "=============================================================="
echo " finished $(date)"
echo " Next: 15-rebuild-gmp-portable.sh (verify), 11-blfs-build.sh,"
echo "       13-firewall.sh, 14-harden-config.sh, 08-make-bootable-image.sh"
echo "=============================================================="
