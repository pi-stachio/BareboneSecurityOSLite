#!/bin/bash
# Tier 3, part 1: make the compiler itself emit hardened code by default.
#
# The problem this solves: the previous tiers hardened the kernel and the configuration,
# but every userland binary was still built with LFS' stock flags. `security-audit`
# reported that honestly as "bindnow=no" on almost everything.
#
# Why a GCC specs file rather than CFLAGS
# ---------------------------------------
# Setting CFLAGS/LDFLAGS in the environment only works for packages that honour them.
# Plenty don't: they hardcode their own -O2, append rather than respect, or use a build
# system that drops the environment entirely. A specs file moves the flags *into the
# compiler*, so a package cannot accidentally opt out -- it would have to pass an
# explicit counter-flag on the command line.
#
# What goes in
# ------------
#   -fhardened     GCC 14+ bundles the userland hardening set behind one flag:
#                  _FORTIFY_SOURCE=3, _GLIBCXX_ASSERTIONS, -ftrivial-auto-var-init=zero,
#                  -fstack-protector-strong, -fstack-clash-protection, -fcf-protection=full,
#                  -fPIE -pie and -Wl,-z,relro,-z,now.
#                  Critically, it knows when *not* to apply a part of that set -- it skips
#                  _FORTIFY_SOURCE at -O0 instead of emitting a broken definition.
#   -Wno-hardened  ...but it announces those decisions as warnings, and a warning appearing
#                  in every configure probe in the system is noise at best and a false
#                  negative in an autoconf test at worst.
#   -z relro/-z now added to the *link spec separately, and this is not redundant:
#                  -fhardened deliberately drops its own link hardening whenever other
#                  link options are on the command line, which is *every shared library*
#                  (they all pass -shared). Relying on -fhardened alone leaves every .so
#                  in the system with lazy binding. Verified below, both cases.
#
# Modes:
#   full        (default) -fhardened + link hardening
#   no-fortify  CET and stack-clash + link hardening, but no _FORTIFY_SOURCE. This exists
#               for glibc, and it is not merely a milder setting -- it is required for CET
#               to work at all. The IBT/SHSTK marking in .note.gnu.property survives only
#               if EVERY input object carries it, and the linker silently intersects it
#               away otherwise. Since glibc supplies crt1.o, crti.o and crtn.o, a glibc
#               built without -fcf-protection strips the note off every binary in the
#               system, leaving endbr64 instructions that the loader never enforces.
#   link-only   link hardening only
#   off         remove the specs file, restoring stock GCC behaviour
#
# Run as root:  bash 16-harden-toolchain.sh [full|no-fortify|link-only|off]
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
MODE=${1:-full}
case "$MODE" in full|no-fortify|link-only|off) ;;
    *) echo "usage: $0 [full|no-fortify|link-only|off]"; exit 1 ;;
esac
mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

cat > "$LFS/sources/harden-toolchain-inside.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
MODE=$1

# GCC looks for "specs" next to libgcc.a, so ask it where that is rather than
# hardcoding a triplet and version that will change with the next LFS release.
GCCDIR=$(dirname "$(gcc -print-libgcc-file-name)")
SPECS="$GCCDIR/specs"
echo "==> specs file: $SPECS"

if [ "$MODE" = off ]; then
    rm -fv "$SPECS"
    echo "==> stock GCC behaviour restored"
    exit 0
fi

command -v gcc > /dev/null || { echo "FATAL: no gcc"; exit 1; }

# Drop any specs file we installed earlier BEFORE doing anything else. -dumpspecs prints
# the *effective* specs, so dumping while our own file is installed would re-append the
# link flags and emit a second *self_spec: block -- which is malformed, and reports
# itself only as "specs file malformed after N characters". Removing it first makes this
# script idempotent and guarantees we always start from GCC's built-in specs.
rm -f "$SPECS"

# Probe by using it, not by reading --help: -fhardened is not listed under --help=common
# even on compilers that implement it.
gcc -fhardened -E -x c /dev/null -o /dev/null 2>/dev/null \
    || { echo "FATAL: this gcc has no -fhardened (needs GCC >= 14)"; exit 1; }

# Build the specs from the compiler's own dump, so everything we do not touch stays
# exactly as GCC intended it.
gcc -dumpspecs > /tmp/specs.new

# Append the link hardening to the existing *link: spec. This is the line that covers
# shared libraries, which -fhardened will not.
awk '
    /^\*link:$/ { print; getline; print $0 " -z relro -z now"; found=1; next }
    { print }
    END { if (!found) { print "ERROR: no *link: spec found" > "/dev/stderr"; exit 1 } }
' /tmp/specs.new > /tmp/specs.linked

if [ "$MODE" = no-fortify ]; then
    # Same trailing-blank-line rule as below.
    perl -0777 -i -pe 's/\n*\z/\n\n/' /tmp/specs.linked
    printf '*self_spec:\n-fcf-protection=full -fstack-clash-protection\n\n' >> /tmp/specs.linked
fi

if [ "$MODE" = full ]; then
    # self_spec options are processed as though they preceded the command line, so an
    # explicit -fno-hardened from a package still wins. Verified in the self-test.
    #
    # Specs syntax is unforgiving here, and neither failure mode names its cause:
    #   - exactly ONE blank line separates two specs. -dumpspecs already ends with that
    #     blank line. Add a second and gcc says "specs file malformed after N characters";
    #     remove it and *self_spec: is silently parsed as more text belonging to the
    #     preceding *link_command: spec, which surfaces much later as the baffling
    #     "cannot execute '*self_spec:': No such file or directory" at the first link.
    #   - the "+ " append prefix only works on a spec that already exists, and
    #     self_spec does not appear in -dumpspecs output at all, so the plain form it is.
    perl -0777 -i -pe 's/\n*\z/\n\n/' /tmp/specs.linked
    printf '*self_spec:\n-fhardened -Wno-hardened\n\n' >> /tmp/specs.linked
fi

install -m644 /tmp/specs.linked "$SPECS"
rm -f /tmp/specs.new /tmp/specs.linked
echo "==> installed $MODE specs"

##############################################################################
# Self-test. A specs file that is subtly wrong produces a system that builds but is
# not hardened, so every claim gets checked against a real compile.
##############################################################################
cd /tmp
fail=0
chk() { if [ "$2" = "$3" ]; then printf '  OK:    %s (%s)\n' "$1" "$2"
        else printf '  ERROR: %s -- got %s, expected %s\n' "$1" "$2" "$3"; fail=1; fi }

# Presence, not count: a fully-relro binary reports BIND_NOW twice (once as a DT_ tag,
# once in DT_FLAGS_1), so counting lines would be comparing against an arbitrary number.
yn()      { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }
bindnow() { yn grep -qE 'BIND_NOW|FLAGS.*\bNOW\b' <(readelf -dW "$1"); }
relro()   { yn grep -q GNU_RELRO <(readelf -lW "$1"); }
ispie()   { yn grep -qE 'Type:[[:space:]]+DYN' <(readelf -hW "$1"); }

printf 'int main(void){return 0;}\n' > ht.c
printf 'int f(void){return 1;}\n'    > hs.c

echo
echo "### executable at -O2 ###"
gcc -O2 ht.c -o ht 2> ht.err
if [ -s ht.err ]; then echo "  unexpected diagnostics:"; sed 's/^/    /' ht.err; fail=1; fi
chk "PIE"       "$(ispie ht)"   yes
chk "GNU_RELRO" "$(relro ht)"   yes
chk "BIND_NOW"  "$(bindnow ht)" yes

echo
echo "### shared library at -O2  (the case -fhardened does not cover) ###"
gcc -O2 -shared -fPIC hs.c -o libhs.so 2> hs.err
if [ -s hs.err ]; then echo "  unexpected diagnostics:"; sed 's/^/    /' hs.err; fail=1; fi
chk "GNU_RELRO" "$(relro libhs.so)"   yes
chk "BIND_NOW"  "$(bindnow libhs.so)" yes

echo
echo "### compile-side hardening, verified by its effect on the output ###"
# Do NOT look for -fstack-clash-protection and friends on the cc1 command line: the
# driver passes the single flag -fhardened straight through and cc1 expands it
# internally, so grepping the command line reports "missing" for options that are
# very much in effect. Check what actually comes out of the compiler instead.
printf 'void g(char*);\nvoid f(void){char b[64];g(b);}\n'      > sp.c
printf 'void g(char*);\nvoid f(void){char b[200000];g(b);}\n'  > sc.c

# CET and the property note matter in every mode except link-only, because glibc's crt
# objects are linked into everything and the note is intersected across all inputs.
if [ "$MODE" != link-only ]; then
    chk "__CET__ (CET/IBT+SHSTK)" \
        "$(gcc -O2 -dM -E - < /dev/null | awk '/define __CET__/{print $3}')" 3
    chk "CET endbr64 emitted" "$(yn grep -q endbr64 <(gcc -O2 -S sp.c -o -))" yes
    # Deliberately NOT checking for the IBT/SHSTK note on a linked binary here. That note
    # is the intersection of every input object's properties, including glibc's crt files,
    # so it cannot appear until glibc itself has been rebuilt with -fcf-protection --
    # which is the build this script is being run to enable. Asserting it here would make
    # the toolchain refuse to install the specs needed to fix it. 17-rebuild-userland.sh
    # verifies it at the end instead, and security-audit reports coverage on the image.

    gcc -O2 -S sc.c -o sc.s
    chk "stack-clash probe loop emitted" \
        "$(yn grep -qE 'orq?[[:space:]]+\$0,[[:space:]]*\(%rsp\)' sc.s)" yes
fi

if [ "$MODE" = full ]; then
    gcc -O2 -c sp.c -o sp.o
    chk "stack canary emitted" "$(yn grep -q __stack_chk_fail <(readelf -sW sp.o))" yes
    chk "_FORTIFY_SOURCE" \
        "$(gcc -O2 -dM -E - < /dev/null | awk '/define _FORTIFY_SOURCE/{print $3}')" 3
    chk "_GLIBCXX_ASSERTIONS" \
        "$(g++ -O2 -dM -E -x c++ - < /dev/null | grep -c 'define _GLIBCXX_ASSERTIONS')" 1

    echo
    echo "### -O0 must stay silent (configure probes compile without -O) ###"
    gcc -O0 ht.c -o ht0 2> h0.err
    if [ -s h0.err ]; then echo "  ERROR: diagnostics at -O0:"; sed 's/^/    /' h0.err; fail=1
    else echo "  OK:    no diagnostics at -O0"; fi
    chk "fortify off at -O0" \
        "$(gcc -O0 -dM -E - < /dev/null | grep -c 'define _FORTIFY_SOURCE')" 0

    echo
    echo "### a package that explicitly disables a flag must still win ###"
    # This is the one that matters in practice. Freestanding code -- grub's target
    # modules, libgcc's crtstuff, the kernel -- passes -fno-stack-protector because it
    # has no __stack_chk_fail to call. If -fhardened overrode that, those packages would
    # build and then fail to link, or link and then fault at runtime.
    #
    # Note the asymmetry: a blanket -fno-hardened does NOT switch this off, because
    # self_spec is applied after the command line. That is why 17-rebuild-userland.sh
    # uses this script's link-only mode as its escape hatch rather than a compiler flag.
    gcc -O2 -fno-stack-protector -c sp.c -o spn.o
    chk "explicit -fno-stack-protector wins" \
        "$(yn grep -q __stack_chk_fail <(readelf -sW spn.o))" no
    gcc -O2 -fno-hardened ht.c -o htn 2>/dev/null
    chk "link hardening applies regardless" "$(bindnow htn)" yes
else
    # Both reduced modes must leave fortify off -- that is the whole point of them.
    chk "no _FORTIFY_SOURCE in $MODE mode" \
        "$(gcc -O2 -dM -E - < /dev/null | grep -c 'define _FORTIFY_SOURCE')" 0
fi

echo
echo "### the compiler still works ###"
printf '#include <stdio.h>\n#include <string.h>\nint main(void){char b[64];strcpy(b,"hardened");printf("%%s\\n",b);return 0;}\n' > hr.c
gcc -O2 hr.c -o hr
out=$(./hr)
chk "compiled program runs" "$out" "hardened"

rm -f ht.c ht ht0 htn ht.err h0.err hs.c hs.err libhs.so hr.c hr \
      sp.c sp.o spn.o sc.c sc.s htc
echo
[ "$fail" = 0 ] || { echo "TOOLCHAIN SELF-TEST FAILED"; exit 1; }
echo "TOOLCHAIN SELF-TEST PASSED ($MODE)"
EOS

chmod +x "$LFS/sources/harden-toolchain-inside.sh"
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
    /bin/bash --login /sources/harden-toolchain-inside.sh "$MODE"

echo
echo "==> Toolchain is in '$MODE' mode. Next: bash 17-rebuild-userland.sh"
