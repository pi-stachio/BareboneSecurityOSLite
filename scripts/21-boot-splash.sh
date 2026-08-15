#!/bin/bash
# Give the system a boot screen instead of a wall of kernel messages.
#
# Three separate things happen during a boot and each needs its own treatment:
#
#   1. GRUB, before any kernel runs. This is the menu people picture when they think
#      "boot screen". Making it graphical needs gfxterm, which cannot draw a single
#      character without a .pf2 font -- and LFS builds grub without FreeType, so
#      grub-mkfont is never built and no font exists. FreeType is built here for that
#      one purpose, then grub is rebuilt so grub-mkfont exists to convert a font.
#
#   2. The kernel, which normally prints several hundred lines. `quiet loglevel=3` on
#      the command line silences it; nothing is lost, since it all remains in dmesg.
#      A second menu entry boots verbosely for when something is actually wrong.
#
#   3. Userspace init, which prints the service list. A branded banner is printed
#      before it so the console leads with the system's name.
#
# Plymouth-style animated splash is deliberately not attempted: it needs an initramfs
# (this system has none, by design) and a framebuffer console (CONFIG_FB is off). The
# result would be a large dependency for an animation nobody watches on a server.
#
# Run as root:  bash 21-boot-splash.sh
set -euo pipefail

LFS=${LFS:-/mnt/lfs}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
SRC="$LFS/sources/blfs"
FREETYPE_VER=2.14.1
FREETYPE_URL="https://downloads.sourceforge.net/freetype/freetype-$FREETYPE_VER.tar.xz"

mountpoint -q "$LFS" || { echo "FATAL: $LFS not mounted"; exit 1; }
mkdir -p "$SRC" "$LFS/boot/grub/themes/bastion" "$LFS/boot/grub/fonts"

mkdir -p "$LFS"/{dev,proc,sys,run}
mountpoint -q "$LFS/dev"  || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/proc" || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"  || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"  || mount -t tmpfs tmpfs "$LFS/run"

##############################################################################
# 1. A font for gfxterm
##############################################################################
if [ ! -x "$LFS/usr/bin/grub-mkfont" ]; then
    echo "==> grub-mkfont is missing; building FreeType so grub can be rebuilt with it"

    if [ ! -f "$SRC/freetype-$FREETYPE_VER.tar.xz" ]; then
        echo "    fetching freetype-$FREETYPE_VER"
        curl -fsSL -o "$SRC/freetype-$FREETYPE_VER.tar.xz" "$FREETYPE_URL" \
            || { echo "FATAL: could not download FreeType"; exit 1; }
    fi

    cat > "$LFS/sources/blfs/freetype-inside.sh" <<EOS
#!/bin/bash
set -e
cd /sources/blfs
rm -rf freetype-$FREETYPE_VER
tar -xf freetype-$FREETYPE_VER.tar.xz
cd freetype-$FREETYPE_VER
# BLFS disables the bytecode interpreter patent workaround toggles; defaults are fine
# here because this build exists only so grub-mkfont can rasterise one font at build
# time. It is not installed for anything else to link against at runtime.
./configure --prefix=/usr --enable-freetype-config --disable-static
make -j\$(nproc)
make install
EOS
    chmod +x "$LFS/sources/blfs/freetype-inside.sh"
    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
        /bin/bash --login /sources/blfs/freetype-inside.sh > /tmp/freetype.log 2>&1 \
        || { echo "FATAL: FreeType build failed"; tail -20 /tmp/freetype.log; exit 1; }
    echo "    FreeType $FREETYPE_VER installed"

    echo "==> Rebuilding grub so grub-mkfont exists"
    GRUBTAR=$(ls "$LFS"/sources/grub-*.tar.* 2>/dev/null | head -1)
    [ -n "$GRUBTAR" ] || { echo "FATAL: no grub tarball in /sources"; exit 1; }
    GV=$(basename "$GRUBTAR" | sed -E 's/^grub-(.+)\.tar\..*$/\1/')
    cat > "$LFS/sources/grub-rebuild.sh" <<EOS
#!/bin/bash
set -e
cd /sources
rm -rf grub-$GV
tar -xf $(basename "$GRUBTAR")
cd grub-$GV
# The book's exact sequence, with --enable-grub-mkfont as the only addition. Do not
# "tidy" any of it:
#
#   * the --image-base sed is load-bearing. Without it configure detects linker support
#     for --image-base and links kernel.img differently, and grub-install then refuses
#     the result with "kernel.img is miscompiled: its start address is 0x9074 instead
#     of 0x9000: ld.gold bug?" -- an error that blames the linker for a configure choice.
#   * unset {C,CPP,CXX,LD}FLAGS keeps stray flags out of a freestanding bootloader build.
#   * in-tree, not a build/ subdirectory, because that is what the book does and this
#     project's rule is to run the book's commands rather than an improvement on them.
unset {C,CPP,CXX,LD}FLAGS
sed 's/--image-base/--nonexist-linker-option/' -i configure
./configure --prefix=/usr           \\
            --sysconfdir=/etc       \\
            --disable-efiemu        \\
            --enable-grub-mkfont    \\
            --disable-werror
make
make -j1 install
EOS
    chmod +x "$LFS/sources/grub-rebuild.sh"
    chroot "$LFS" /usr/bin/env -i HOME=/root TERM="${TERM:-dumb}" PATH=/usr/bin:/usr/sbin \
        /bin/bash --login /sources/grub-rebuild.sh > /tmp/grub-rebuild.log 2>&1 \
        || { echo "FATAL: grub rebuild failed"; tail -25 /tmp/grub-rebuild.log; exit 1; }
    echo "    grub $GV rebuilt with mkfont support"
fi

##############################################################################
# 2. Convert a font to grub's .pf2 format
##############################################################################
echo "==> Building the grub font"
# LFS installs no fonts whatsoever, and grub's own build only emits unicode.pf2 when it
# can find a source font -- which is why rebuilding grub with FreeType was necessary but
# not sufficient. DejaVu is the conventional choice: permissively licensed, stable for
# years, and its Mono face keeps the menu aligned.
DEJAVU_VER=2.37
DEJAVU_TAR="dejavu-fonts-ttf-$DEJAVU_VER.tar.bz2"
DEJAVU_URL="https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_${DEJAVU_VER//./_}/$DEJAVU_TAR"

if [ ! -f "$LFS/usr/share/fonts/dejavu/DejaVuSansMono.ttf" ]; then
    if [ ! -f "$SRC/$DEJAVU_TAR" ]; then
        echo "    fetching DejaVu $DEJAVU_VER"
        curl -fsSL -o "$SRC/$DEJAVU_TAR" "$DEJAVU_URL" \
            || { echo "    could not download DejaVu; falling back to the text menu"; }
    fi
    if [ -f "$SRC/$DEJAVU_TAR" ]; then
        install -d "$LFS/usr/share/fonts/dejavu"
        tar -xf "$SRC/$DEJAVU_TAR" -C /tmp
        install -m644 /tmp/dejavu-fonts-ttf-$DEJAVU_VER/ttf/DejaVuSansMono.ttf \
                      /tmp/dejavu-fonts-ttf-$DEJAVU_VER/ttf/DejaVuSans.ttf \
                      "$LFS/usr/share/fonts/dejavu/" 2>/dev/null || true
        rm -rf "/tmp/dejavu-fonts-ttf-$DEJAVU_VER"
        echo "    installed DejaVu into /usr/share/fonts/dejavu"
    fi
fi

# -n "Unicode" forces the family name, because the theme references the font by name
# ("Unicode Regular 18") and grub silently renders nothing if that string does not match
# what the .pf2 actually calls itself.
if chroot "$LFS" /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
        set -e
        [ -f /usr/share/fonts/dejavu/DejaVuSansMono.ttf ] || exit 1
        grub-mkfont -n "Unicode" -s 18 \
            -o /boot/grub/fonts/unicode.pf2 \
            /usr/share/fonts/dejavu/DejaVuSansMono.ttf
    ' > /dev/null 2>&1; then
    echo "    /boot/grub/fonts/unicode.pf2 built ($(du -h "$LFS/boot/grub/fonts/unicode.pf2" | cut -f1))"
else
    echo "    no usable font source; the text menu will be used instead"
fi

##############################################################################
# 3. Background image and theme
##############################################################################
echo "==> Generating the background image"
python3 "$SCRIPTS/make-splash.py" "$LFS/boot/grub/themes/bastion/background.png" \
    | sed 's/^/    /'

cat > "$LFS/boot/grub/themes/bastion/theme.txt" <<'EOF'
# BastionOS grub theme
desktop-image: "background.png"
desktop-color: "#0e1218"
title-text: ""
terminal-font: "Unicode Regular 18"

+ label {
    top   = 9%
    left  = 0
    width = 100%
    align = "center"
    text  = "BastionOS"
    color = "#e8eef2"
    font  = "Unicode Regular 18"
}

# Sits above the accent rule the background draws at y=150. At 17% the descenders
# landed straight on it and the line struck through the text.
+ label {
    top   = 14%
    left  = 0
    width = 100%
    align = "center"
    text  = "Linux From Scratch 13.0, hardened"
    color = "#5ea8be"
    font  = "Unicode Regular 18"
}

+ boot_menu {
    top        = 30%
    left       = 25%
    width      = 50%
    height     = 40%
    item_color = "#8d9aa5"
    # Light on dark, NOT dark-on-light. The dark value is only correct with a highlight
    # pixmap behind it, and referencing select_*.png files that do not exist leaves the
    # selected entry as dark grey text on a dark background -- invisible, on the one line
    # the user most needs to see.
    selected_item_color = "#9fe8ff"
    item_height  = 30
    item_spacing = 8
}

# Below the lower accent rule at y=678, not on top of it.
+ label {
    top   = 91%
    left  = 0
    width = 100%
    align = "center"
    text  = "enter: boot     e: edit options     c: command line"
    color = "#7f8c96"
    font  = "Unicode Regular 18"
}
EOF
echo "    theme written"

##############################################################################
# 4. Console banner, printed before the service list
##############################################################################
echo "==> Installing the console banner"
cat > "$LFS/etc/rc.d/init.d/banner" <<'EOS'
#!/bin/sh
### BEGIN INIT INFO
# Provides:            banner
# Required-Start:
# Default-Start:       S
# Short-Description:   Prints the BastionOS console banner.
# X-LFS-Provided-By:   BastionOS
### END INIT INFO

# Deliberately no init-functions here: this runs before anything else and only writes
# to the console. Sourcing it would also risk the variable collisions that bit firstboot.

case "$1" in
    start)
        printf '\033[2J\033[H'
        printf '\033[1;36m'
        cat <<'ART'
   ___             _    _              ___   ___
  | _ ) __ _  ___ | |_ (_) ___  _ _   / _ \ / __|
  | _ \/ _` |(_-< |  _|| |/ _ \| ' \ | (_) |\__ \
  |___/\__,_|/__/  \__||_|\___/|_||_| \___/ |___/
ART
        printf '\033[0m'
        printf '\033[0;37m  Linux From Scratch 13.0  --  hardened\033[0m\n\n'
        ;;
esac
EOS
chmod 754 "$LFS/etc/rc.d/init.d/banner"
ln -sfnv ../init.d/banner "$LFS/etc/rc.d/rcS.d/S00banner" > /dev/null
echo "    linked as rcS.d/S00banner (first thing userspace prints)"

echo
echo "==> Done. Re-run 08-make-bootable-image.sh to fold this in."
echo "    grub.cfg picks up the graphical theme automatically when the font exists."
