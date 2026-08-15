#!/bin/bash
# bpkg -- BastionOS package manager. Installed as /usr/bin/bpkg.
#
# An LFS system can compile anything and install nothing: every addition is a manual
# ./configure && make install that leaves no record, cannot be removed, and silently
# overwrites whatever was there before. That is the single largest usability gap in a
# source-built system, and it is also a security gap -- you cannot audit what you cannot
# enumerate.
#
# Design, deliberately close to CRUX pkgutils and Slackware pkgtools rather than to dpkg
# or rpm. There is no dependency solver, no upgrade transaction, no scriptlets running as
# root at install time. Those are where package managers get complicated and where they
# get exploited, and a system this size does not need them.
#
#   package = tar.zst of a filesystem tree, plus a .PKGINFO metadata file
#   database = /var/lib/bpkg/db/<name>/{PKGINFO,FILES,SHA256SUMS}
#
# Two properties matter more here than convenience:
#
#   * Installing never silently clobbers a file owned by another package. It refuses and
#     names the owner. On a system with no way to reinstall the base, one careless
#     overwrite of libc is unrecoverable.
#   * Every installed file's checksum is recorded, so `bpkg verify` detects modification
#     after the fact. That is a genuine integrity check, not a convenience feature.
set -uo pipefail

DB=${BPKG_DB:-/var/lib/bpkg/db}
ROOT=${BPKG_ROOT:-/}
umask 022

die()  { echo "bpkg: $*" >&2; exit 1; }
warn() { echo "bpkg: $*" >&2; }

usage() {
    cat <<'EOF'
bpkg -- BastionOS package manager

  install <file.bpkg> [...]   install package(s); refuses to overwrite other packages'
                              files unless --force
  remove <name>               remove a package and the files it owns
  list                        installed packages and versions
  info <name>                 metadata for one package
  files <name>                files owned by a package
  owns <path>                 which package owns a path
  verify [name]               re-check installed files against recorded checksums
  create <dir> <name> <ver>   build a .bpkg from a staged DESTDIR tree

Options: --force  --root <dir>
EOF
}

# ---------------------------------------------------------------- helpers ----
pkg_dir() { echo "$DB/$1"; }
is_installed() { [ -d "$DB/$1" ]; }

# Read one key from a PKGINFO file.
pkginfo_get() { sed -n "s/^$2 = //p" "$1" | head -1; }

# ---------------------------------------------------------------- create ----
# Turn a staged tree (what `make DESTDIR=... install` produced) into a package.
cmd_create() {
    local dir=$1 name=$2 ver=$3 out
    [ -d "$dir" ] || die "no such directory: $dir"
    [ -n "$name" ] && [ -n "$ver" ] || die "usage: bpkg create <dir> <name> <version>"
    out="$PWD/$name-$ver.bpkg"
    # Absolute, because the tar below uses two -C options and the second is resolved
    # relative to wherever the first one already moved to -- so a relative staging dir
    # fails with "Cannot open: No such file or directory" naming a path that plainly exists.
    dir=$(cd "$dir" && pwd)

    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # Metadata lives beside the payload, not inside the installed tree.
    {
        echo "name = $name"
        echo "version = $ver"
        echo "arch = $(uname -m)"
        echo "built = $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "size = $(du -sk "$dir" | cut -f1)"
    } > "$tmp/.PKGINFO"

    ( cd "$dir" && find . -type f -o -type l -o -type d ) | sed 's|^\./||' | grep -v '^\.$' \
        | LC_ALL=C sort > "$tmp/.FILES"
    ( cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum ) | sed 's| \./| |' > "$tmp/.SHA256SUMS"

    tar --create --zstd \
        -C "$tmp" .PKGINFO .FILES .SHA256SUMS \
        -C "$dir" . \
        --file "$out" || die "failed to create $out"

    echo "created $out"
    echo "  $(grep -c . "$tmp/.FILES") entries, $(du -h "$out" | cut -f1)"
}

# --------------------------------------------------------------- install ----
cmd_install() {
    local force=0 files=()
    for a in "$@"; do
        case "$a" in --force) force=1 ;; *) files+=("$a") ;; esac
    done
    [ "${#files[@]}" -gt 0 ] || die "usage: bpkg install <file.bpkg>"

    for f in "${files[@]}"; do
        [ -f "$f" ] || die "no such file: $f"
        local tmp; tmp=$(mktemp -d)
        tar --extract --zstd -f "$f" -C "$tmp" .PKGINFO .FILES .SHA256SUMS 2>/dev/null \
            || { rm -rf "$tmp"; die "$f is not a bpkg (no metadata)"; }

        local name ver
        name=$(pkginfo_get "$tmp/.PKGINFO" name)
        ver=$(pkginfo_get "$tmp/.PKGINFO" version)
        [ -n "$name" ] || { rm -rf "$tmp"; die "$f has no package name"; }

        if is_installed "$name"; then
            local cur; cur=$(pkginfo_get "$(pkg_dir "$name")/PKGINFO" version)
            echo "bpkg: $name $cur is already installed; remove it first"
            rm -rf "$tmp"; continue
        fi

        # Refuse to take ownership of a file another package owns. Checked before
        # anything is written, so a rejected install changes nothing at all.
        local conflicts=0
        while read -r rel; do
            [ -n "$rel" ] || continue
            [ -d "$ROOT/$rel" ] && continue
            if [ -e "$ROOT/$rel" ]; then
                local owner; owner=$(owner_of "$rel")
                if [ -n "$owner" ] && [ "$owner" != "$name" ]; then
                    echo "  conflict: /$rel is owned by $owner"
                    conflicts=$((conflicts+1))
                fi
            fi
        done < "$tmp/.FILES"

        if [ "$conflicts" -gt 0 ] && [ "$force" = 0 ]; then
            rm -rf "$tmp"
            die "$name would overwrite $conflicts file(s) owned by another package (--force to override)"
        fi

        echo "installing $name $ver"
        tar --extract --zstd --keep-directory-symlink \
            --exclude=.PKGINFO --exclude=.FILES --exclude=.SHA256SUMS \
            -f "$f" -C "$ROOT" || { rm -rf "$tmp"; die "extraction failed for $name"; }

        install -d "$(pkg_dir "$name")"
        install -m644 "$tmp/.PKGINFO"    "$(pkg_dir "$name")/PKGINFO"
        install -m644 "$tmp/.FILES"      "$(pkg_dir "$name")/FILES"
        install -m644 "$tmp/.SHA256SUMS" "$(pkg_dir "$name")/SHA256SUMS"
        rm -rf "$tmp"
        echo "  $(grep -c . "$(pkg_dir "$name")/FILES") entries recorded"
    done
}

owner_of() { # relative path -> package name, or empty
    local rel=$1 p
    for p in "$DB"/*/; do
        [ -d "$p" ] || continue
        if grep -qxF "$rel" "$p/FILES" 2>/dev/null; then
            basename "$p"; return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------- remove ----
cmd_remove() {
    local name=${1:-}
    [ -n "$name" ] || die "usage: bpkg remove <name>"
    is_installed "$name" || die "$name is not installed"

    # Files first, then directories deepest-first, and only if empty. A package that
    # dropped a file into /usr/bin must not take /usr/bin with it.
    local n=0
    while read -r rel; do
        [ -n "$rel" ] || continue
        [ -d "$ROOT/$rel" ] && continue
        if [ -e "$ROOT/$rel" ] || [ -L "$ROOT/$rel" ]; then
            rm -f "$ROOT/$rel" && n=$((n+1))
        fi
    done < "$(pkg_dir "$name")/FILES"

    tac "$(pkg_dir "$name")/FILES" | while read -r rel; do
        [ -n "$rel" ] || continue
        [ -d "$ROOT/$rel" ] && rmdir "$ROOT/$rel" 2>/dev/null || true
    done

    rm -rf "$(pkg_dir "$name")"
    echo "removed $name ($n files)"
}

# ------------------------------------------------------------------ query ----
cmd_list() {
    local any=0
    for p in "$DB"/*/; do
        [ -d "$p" ] || continue
        any=1
        printf '%-24s %s\n' "$(basename "$p")" "$(pkginfo_get "$p/PKGINFO" version)"
    done
    [ "$any" = 1 ] || echo "no packages installed"
}

cmd_info() {
    local name=${1:-}; [ -n "$name" ] || die "usage: bpkg info <name>"
    is_installed "$name" || die "$name is not installed"
    cat "$(pkg_dir "$name")/PKGINFO"
    echo "files = $(grep -c . "$(pkg_dir "$name")/FILES")"
}

cmd_files() {
    local name=${1:-}; [ -n "$name" ] || die "usage: bpkg files <name>"
    is_installed "$name" || die "$name is not installed"
    sed 's|^|/|' "$(pkg_dir "$name")/FILES"
}

cmd_owns() {
    local path=${1:-}; [ -n "$path" ] || die "usage: bpkg owns <path>"
    local rel=${path#/}
    local o; o=$(owner_of "$rel") && echo "$o owns /$rel" || echo "no package owns /$rel"
}

# ----------------------------------------------------------------- verify ----
# Integrity, not just presence: a modified binary has the right name and the wrong
# contents, and that is exactly the case worth catching.
cmd_verify() {
    local names=() rc=0
    if [ $# -gt 0 ]; then names=("$@"); else
        for p in "$DB"/*/; do [ -d "$p" ] && names+=("$(basename "$p")"); done
    fi
    [ "${#names[@]}" -gt 0 ] || { echo "no packages installed"; return 0; }

    for name in "${names[@]}"; do
        is_installed "$name" || { warn "$name is not installed"; rc=1; continue; }
        local miss=0 bad=0
        while read -r sum rel; do
            [ -n "${rel:-}" ] || continue
            if [ ! -e "$ROOT/$rel" ]; then
                echo "  MISSING  /$rel"; miss=$((miss+1)); continue
            fi
            local now; now=$(sha256sum "$ROOT/$rel" 2>/dev/null | cut -d' ' -f1)
            if [ "$now" != "$sum" ]; then
                echo "  MODIFIED /$rel"; bad=$((bad+1))
            fi
        done < "$(pkg_dir "$name")/SHA256SUMS"
        if [ "$miss" = 0 ] && [ "$bad" = 0 ]; then
            printf '%-24s OK\n' "$name"
        else
            printf '%-24s %d modified, %d missing\n' "$name" "$bad" "$miss"; rc=1
        fi
    done
    return $rc
}

# ------------------------------------------------------------------- main ----
cmd=${1:-}; shift 2>/dev/null || true
# --root has to be handled before dispatch, since every command honours it.
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT=$2; DB="$ROOT/var/lib/bpkg/db"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

case "$cmd" in
    install) install -d "$DB"; cmd_install "$@" ;;
    remove)  cmd_remove "$@" ;;
    list)    cmd_list ;;
    info)    cmd_info "$@" ;;
    files)   cmd_files "$@" ;;
    owns)    cmd_owns "$@" ;;
    verify)  cmd_verify "$@" ;;
    create)  cmd_create "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac
