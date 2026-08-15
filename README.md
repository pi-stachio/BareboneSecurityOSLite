# BastionOS

A hardened **Linux From Scratch 13.0** system — compiled from source, bootable, and
reproducible from a single set of scripts on a Windows machine via WSL2.

No distro packages. No installer. Every binary in the running system was compiled locally
from upstream source, starting from a cross-toolchain built by hand — then compiled a
second time with a hardened compiler.

```
LFS 13.0 (SysV) · x86_64 · kernel 6.18.10 · gcc 15.2.0 · glibc 2.43 · binutils 2.46
651 binaries · 1.5 GB installed · GRUB on MBR · boots in QEMU, Hyper-V or VirtualBox
KASLR · Landlock/Yama/lockdown · no loadable modules · nftables default-deny
full RELRO · PIE · _FORTIFY_SOURCE=3 · CET · stack-clash protection, system-wide
```

---

## Try it without building it

Grab the disk image from [Releases](../../releases), then:

```bash
qemu-system-x86_64 -enable-kvm -m 2048 \
    -drive file=bastionos-1.4.0-x86_64.qcow2,format=qcow2 -nographic
```

The system comes up as **`bastion`**. Log in as **`root`** / **`lfs`**, or as **`admin`** /
**`lfs`** (in the `wheel` group, so `sudo` works). `poweroff` shuts it down; `Ctrl-a` then
`x` detaches. Change both passwords before putting this anywhere real — they are
deliberately trivial so the image is useful to experiment with out of the box.

**SSH refuses passwords by design and ships with no authorised key**, so remote login will
turn you away until you add one from the console:

```
bastionctl add-key 'ssh-ed25519 AAAA... you@host'
```

First boot generates this machine's own host keys and prints their fingerprints on the
console — worth comparing against what `ssh` shows you the first time you connect.

To reach it over the network instead, forward a port and SSH in — root login is disabled,
so use the `admin` account:

```bash
qemu-system-x86_64 -enable-kvm -m 2048 \
    -drive file=bastionos-1.4.0-x86_64.qcow2,format=qcow2 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device e1000,netdev=n0 -display none &
ssh -p 2222 admin@localhost
```

It's a 12 GB virtual disk that compresses to ~530 MB. Works in Hyper-V and VirtualBox too
(convert with `qemu-img convert`). eth0 uses DHCP, so it gets an address on any network.

Once inside, `sudo security-audit` reports what is actually true of the running system:

```
ELF hardening across the whole installed system
    scanned 697 files (690 dynamic, 7 static)
    full RELRO (BIND_NOW)     690/690  100%
    PIE (executables)         580/580  100%
    non-executable stack      690/690  100%
    CET (IBT+SHSTK)           690/690  100%
    stack canary              646/690   93%   (only where the code has a protectable frame)

  57 passed, 0 warnings, 0 failures
```

## Build it yourself

You need Windows 10/11 with WSL2 and about 3 hours (mostly unattended compilation), 8 GB
RAM, and 60 GB of free disk.

```powershell
wsl --install -d Debian --name lfs-host --no-launch

# then, inside the distro, in order:
bash scripts/00-host-setup.sh            # host prep + LFS version checks
bash scripts/01-lfs-partition.sh 40G     # ext4 build filesystem
bash scripts/03-fetch-sources.sh         # ~96 tarballs, md5-verified
bash scripts/05-make-kernel-config.sh    # kernel config
bash scripts/06-configure-jhalfs.sh      # generate the build system
bash scripts/07-run-build.sh             # the long one — resumable
bash scripts/05b-finalize-kernel-config.sh
bash scripts/08-make-bootable-image.sh   # partitioned image + GRUB
bash scripts/09-boot-test.sh             # boot it and verify
```

The build is driven by [jhalfs](https://github.com/lfs-book/jhalfs), the LFS project's own
automation, which reads the book's XML and runs the book's commands — so this isn't a
reimplementation of LFS, it's LFS. `07-run-build.sh` is resumable: it stamps each completed
target, so re-running continues from a failure rather than restarting.

The hardened rebuild in `17-rebuild-userland.sh` re-executes those same extracted commands
against the modified compiler, so it inherits the book rather than forking it. Measured
cost on this machine: **2.8× the original wall time** for chapter 8 (2 h 25 m). Most of
that is I/O, not codegen — `man-pages`, which compiles nothing at all and only copies
files, still took 5.8× longer, while compile-bound gcc took 1.8×.

### The hardening layer

```bash
bash scripts/12-harden-kernel.sh         # hardened kernel, no loadable modules
bash scripts/13-firewall.sh              # nftables, default-deny inbound
bash scripts/14-harden-config.sh         # sysctl, sshd, umask, SUID trim
bash scripts/15-rebuild-gmp-portable.sh  # remove build-CPU tuning from GMP
bash scripts/16-harden-toolchain.sh      # make gcc emit hardened code by default
bash scripts/17-rebuild-userland.sh      # rebuild all of chapter 8 with it (~3 h)
bash scripts/08-make-bootable-image.sh   # fold into a new image
```

**The kernel** gets KASLR, hardened usercopy, `INIT_ON_ALLOC`/`INIT_ON_FREE`, slab freelist
hardening and randomised kmalloc caches, plus **Landlock, Yama and lockdown** as LSMs.
Loadable module support is compiled out entirely, along with `/dev/mem`, `/proc/kcore`,
kexec, hibernation and 32-bit syscall emulation.

**The configuration** gets a default-deny nftables ruleset that loads *before* the network
comes up, a hardened sysctl set, key-only SSH restricted to the `wheel` group, yescrypt
password hashing, and a SUID trim from 11 binaries to 8 — with `ping`, `ping6` and
`traceroute` moved from setuid-root to a `cap_net_raw` capability.

**The toolchain** tier is the one that touches every binary in the system. Rather than
setting `CFLAGS` — which only works for packages that bother to honour it — the flags go
into a GCC **specs file**, so a package would have to actively fight the compiler to opt
out. Every chapter 8 package is then rebuilt with it, using the book's own commands that
jhalfs already extracted. That gives `_FORTIFY_SOURCE=3`, `-fstack-clash-protection`,
`-fcf-protection=full` (CET), `_GLIBCXX_ASSERTIONS`, `-ftrivial-auto-var-init=zero`, and
full RELRO with `BIND_NOW` on executables *and* shared libraries. PIE and stack-protector
were already LFS defaults.

Run `security-audit` on the running system to check all of it. It scans every binary and
library rather than a sample, names any outliers, and re-checks the shipped compiler by
compiling a program with it.

### Actually using it

A hardened system nobody can log into is not much use. These fix the parts that made a
downloaded image awkward — or, in one case, impossible — to run:

```bash
bash scripts/19-firstboot.sh     # first-boot setup + bastionctl
bash scripts/21-boot-splash.sh   # graphical boot menu, quiet boot, console banner
bash scripts/22-seed-packages.sh # bpkg + chrony, dcron, log rotation
```

**First boot** generates this machine's own SSH host keys and prints their fingerprints
on the console, then grows the root filesystem to fill whatever disk it was given. Both
matter: up to v1.3.1 the host keys were generated on the *build* machine and baked in, so
every download shared one host identity and host-key verification — the thing that detects
a man-in-the-middle — was worth nothing.

**No SSH key is baked into released images** any more either. Earlier releases authorised
the build machine's key, which meant the image was reachable by whoever built it and, since
password auth is off, *unreachable over SSH by everyone else*. Access is now provisioned by
the operator from the console:

```
bastionctl add-key 'ssh-ed25519 AAAA... you@host'
bastionctl status        # host, address, firewall, keys, advisories, first-boot state
bastionctl fingerprints  # compare against what ssh shows you on first connect
```

`20-package-image.sh` refuses to package an image that still contains an authorised key,
host keys, or a completed first-boot marker, so that class of mistake cannot ship twice.

**A package manager.** An LFS system can compile anything and install nothing: every
addition is a manual `make install` that leaves no record, cannot be removed, and silently
overwrites whatever was there. `bpkg` is deliberately small — a package is a `tar.zst` of a
filesystem tree plus metadata, the database is a directory of text files, and there is no
dependency solver, no upgrade transaction and no install-time scriptlets running as root.

```bash
bpkg install foo-1.0.bpkg     bpkg owns /usr/bin/foo
bpkg remove foo               bpkg verify          # SHA256 of every installed file
bpkg list / info / files      bpkg create <dir> <name> <ver>
```

Two properties were worth more than convenience. Installing **never silently overwrites a
file owned by another package** — it checks every path before writing anything and aborts
naming the owner, because on a system with no way to reinstall the base, one careless
overwrite of libc is unrecoverable. And every file's checksum is recorded, so `bpkg verify`
detects modification after the fact and `security-audit` reports it.

Three packages ship built with it, each closing a real gap: **chrony** (there was no time
sync at all, and a drifting clock breaks TLS with errors that blame the certificate),
**dcron**, and a small **log rotation** job (sysklogd wrote to `/var/log` without bound).

### Knowing what you're running

Everything above is about how the system was *built*. It says nothing about whether the
versions it pins are known to be broken — and a source-built system has no package
manager, so it has no patch notifications either. Left there, the honest answer to "is
anything in here vulnerable?" is *nobody knows*.

```bash
bash scripts/18-vuln-scan.sh          # inventory + check against NVD
```

This builds a manifest of every installed package from the book commands that actually
built them, checks each version against the [NVD](https://nvd.nist.gov/) CVE database,
and ships the result inside the image:

```
/etc/bastionos/packages.tsv     what is installed
/etc/bastionos/vuln-report.txt  what is known about it, and when that was checked
/usr/sbin/vuln-scan             refresh it (needs network)
```

`security-audit` summarises the cached report and warns when it goes stale, rather than
querying the network itself — an audit that needs the internet to finish is an audit that
gets skipped.

Two things this deliberately does *not* do. It does not treat advisories as failures:
they are upstream facts about pinned versions, not defects in this build, and failing on
them would mean the boot test could never pass. And it does not claim the CVEs are
exploitable here — the kernel figure in particular covers drivers and subsystems this
build does not compile in, so read it as an upper bound.

**What it currently finds**, against the versions LFS 13.0 pins:

```
critical=17 high=48 medium=68 low=13    20 of 94 packages affected

curl      8.18.0   crit=8  high=12      openssh  10.2p1   crit=0  high=2
perl      5.42.0   crit=3  high=1       Python   3.14.3   crit=0  high=3
openssl   3.6.1    crit=2  high=16      dhcpcd   10.3.0   crit=0  high=1
inetutils 2.7      crit=2  high=1       vim      9.2.0078 crit=1  high=7
glibc     2.43     crit=1  high=5
```

Published as found. A release whose whole point is that the system can tell you what it's
running would be a poor place to start hiding things.

#### On trusting the numbers

NVD's `cpeName` parameter needs the exact CPE vendor, which is often not the obvious one —
curl's is `haxx`, and querying `curl:curl` returns zero results rather than an error, so a
naive scanner reports a clean bill of health. Using a wildcard vendor fixes that but
introduces the opposite problem: product names are not unique across vendors, and the
collisions are not subtle.

An unfiltered scan of this system reports 18 advisories against `tar`, of which **one** is
GNU tar — the other 17 are the `node-tar` npm package. `zlib` matches Cloudflare's fork and
Ruby's binding but not zlib itself. `ninja` matches an unrelated ITRS Group product. Left
alone, about a quarter of the high-severity count is software that isn't installed.

So `vuln-scan.py` carries a verified vendor allow-list, discards non-matching advisories
(27 of them here), and reports anything it *can't* disambiguate as UNVERIFIED rather than
guessing in either direction. The same class of error bites the manifest: LFS builds udev
from the systemd tarball, so taking the tarball name at face value reports a `systemd` that
isn't installed — there is no `systemctl` here and there are no units.

### The administrable layer

A pure LFS system has no `ping`, no `ssh`, no `sudo` and no TLS trust store — it can
compile anything but you can't log into it remotely or verify a certificate. Two more
scripts add a minimal, useful set from BLFS (already included in the released image):

```bash
bash scripts/10-blfs-sources.sh   # md5-verified against the BLFS book
bash scripts/11-blfs-build.sh     # builds them in the chroot
bash scripts/08-make-bootable-image.sh   # fold into a new image
```

That adds `sudo`, `openssh`, `dhcpcd`, `iputils`, `curl` (with `libpsl`), and `make-ca` with
a real 172-certificate Mozilla trust store, plus an `admin` account in the `wheel` group.
Root SSH login stays disabled.

## Scripts

| Script | Purpose |
|---|---|
| `00-host-setup.sh` | Host prep: `wsl.conf`, `/bin/sh`→bash, build deps, version check |
| `01-lfs-partition.sh` | Create/format/mount the ext4 build filesystem |
| `02-lfs-user.sh` | The `lfs` build user and its environment (manual builds) |
| `03-fetch-sources.sh` | Download + md5-verify every source tarball |
| `04-enter-chroot.sh` | Mount kernel filesystems and chroot in (manual builds) |
| `05-make-kernel-config.sh` | Kernel config from `x86_64_defconfig` + bootability options |
| `05b-finalize-kernel-config.sh` | Re-resolve that config with the *target* compiler |
| `06-configure-jhalfs.sh` | Drive jhalfs non-interactively |
| `07-run-build.sh` | Run the build (resumable) |
| `08-make-bootable-image.sh` | Partitioned image, GRUB, hostname, getty, password |
| `09-boot-test.sh` | Boot in QEMU and verify over SSH |
| `10-blfs-sources.sh` / `11-blfs-build.sh` | The optional admin toolset |
| `12-harden-kernel.sh` | Hardened kernel: mitigations on, modules and legacy interfaces off |
| `13-firewall.sh` | nftables with a default-deny inbound ruleset |
| `14-harden-config.sh` | sysctl, sshd, password and umask policy, SUID trim |
| `15-rebuild-gmp-portable.sh` | Rebuild GMP without build-CPU tuning |
| `16-harden-toolchain.sh` | Hardened GCC specs (`full`/`no-fortify`/`link-only`/`off`) |
| `17-rebuild-userland.sh` | Rebuild every chapter 8 package with it — resumable |
| `18-vuln-scan.sh` / `vuln-scan.py` | Inventory packages and check them against NVD |
| `19-firstboot.sh` | First-boot service: host keys, rootfs growth, motd |
| `20-package-image.sh` | Convert to qcow2, refusing to package a test image |
| `21-boot-splash.sh` / `make-splash.py` | Graphical GRUB menu, quiet boot, console banner |
| `22-seed-packages.sh` | Build chrony, dcron and log rotation as `bpkg` packages |
| `bpkg.sh` | The package manager, installed as `/usr/bin/bpkg` |
| `bastionctl.sh` | Operator helper, installed as `/usr/sbin/bastionctl` |
| `security-audit.sh` | Installed as `/usr/sbin/security-audit` on the image |
| `ppm2png.py` | Convert a QEMU screendump for inspection |
| `render-book.sh` | Render the LFS book locally from its GitHub mirror |
| `run-lfs.sh` / `run-lfs-gui.sh` | Boot the finished system, text or windowed |
| `watch-build.sh` / `watch-blfs.sh` | Progress and failure watchers |
| `check-env.sh` | Verify the environment after a WSL restart |

## Notes from actually doing this

Things that cost real debugging time and aren't in the book. If you're attempting LFS in a
similar setup, these are the parts that will bite you.

**Backgrounding the build silently breaks Python.** A shell that starts a background job
without job control sets `SIGINT`/`SIGQUIT` to `SIG_IGN`, and that disposition is inherited
all the way into the chroot. CPython refuses to install its own SIGINT handler when it
inherits `SIG_IGN`, so `test_generators.SignalAndYieldFromTest` fails during Python's PGO
training run and takes the whole build down — deterministically, ~2h in. Check with
`grep SigIgn /proc/<pid>/status`; bit `0x2` set means broken. The fix is to reset the
disposition, not to skip the test:

```bash
exec perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' make
```

**A kernel config generated on the host is not complete for the target.** Some Kconfig
symbols only exist if the *compiler* supports them — `CONFIG_GCC_PLUGINS` appears only when
gcc ships plugin headers. Debian's gcc-14 lacks them; LFS's gcc-15.2.0 has them. So the
symbol shows up as NEW inside the chroot, the book's `timeout 60 make oldconfig` stops to
ask a question nobody can answer, and the build dies with exit 124. Run `olddefconfig` with
the target toolchain instead (`05b-finalize-kernel-config.sh`).

**jhalfs leaves chapter 9 placeholders in place.** `/etc/hostname` and `/etc/hosts` keep
literal `**EDITME**` strings, and root's entry in `/etc/shadow` is a literal `x` — which is
not a valid hash, so the account cannot be logged into at all. A system that builds, boots,
and cannot be used.

**udev renames your NIC out from under the book.** LFS's chapter 9 network config is written
for `eth0`, but predictable naming calls it `enp0s3`, so the network bootscript fails at
boot. `net.ifnames=0` on the kernel command line makes the book's own config correct.

**Don't build curl without libpsl.** Its configure will fail rather than silently continue,
and `--without-libpsl` is the tempting one-word fix — but BLFS and curl upstream both warn
against it for security reasons (it's what prevents cookies being set across public suffixes
like `.co.uk`). Build `libunistring` → `libidn2` → `libpsl` instead.

**Mirror checksum lists are not interchangeable.** The `md5sums` on the package mirror is the
*systemd* list; five SysV-only packages are simply absent from it. Verify against the book's
own checksums, not the mirror's.

**`ping` needs a capability that meson's install doesn't grant.** Fresh out of the build it
fails for non-root users with `missing cap_net_raw+p capability or setuid?`. Grant just that
one capability — `setcap cap_net_raw+p /usr/bin/ping` — rather than making it setuid root.
`rsync -aHAX` preserves it when copying into the disk image; plain `rsync -a` would not.

**QEMU's `hostfwd` accepts TCP connections whether or not the guest is listening.** So
"wait until the port is open" is not a readiness check — it succeeds within seconds of
starting QEMU and you then connect to nothing. Probe with a real SSH handshake instead.

**GMP bakes in the build machine's CPU.** Its configure script probes the host and emits
something like `-march=broadwell -mtune=skylake`. Every binary linking libgmp — `nft`, and
crucially **`gcc`** — then executes those instructions, so the system dies with SIGILL on
any older CPU or under an emulator presenting a generic one. If you intend to run the
result anywhere but the machine that built it, configure GMP with `--host=none-linux-gnu`.
This is easy to miss because testing under `qemu -cpu host` with KVM reproduces the build
CPU exactly and hides the bug completely.

**An fstab entry for a filesystem the kernel lacks halts the boot.** Adding
`securityfs` before enabling `CONFIG_SECURITYFS` makes LFS' `S40mountfs` bootscript exit 1,
and init stops at a "Press Enter to continue" prompt — an unbootable system caused by a
purely cosmetic auditing feature. `CONFIG_SECURITYFS` is a separate symbol from the LSMs;
enabling Landlock/Yama/lockdown does not imply it.

**`CONFIG_MODULES=n` silently drops every `=m` symbol.** Disabling loadable modules is a
large, cheap attack-surface win — but everything defconfig had marked as a module simply
vanishes rather than becoming built-in. Anything you actually need (here: all the netfilter
symbols) has to be forced to `=y` explicitly, or you get a kernel with no firewall support
and no error message saying so.

**`-fhardened` does not harden shared libraries.** It drops its own link hardening whenever
any other link option is on the command line — and `-shared` is one, so *every* `.so` in the
system comes out with lazy binding while executables look perfect. Since closing exactly
that gap is the point of the exercise, the `-z relro -z now` has to go into the `*link:`
spec separately. The give-away is that `readelf -d` on a library shows no `BIND_NOW` even
though the compiler claims to be applying it.

**GCC specs files need exactly one blank line between specs, and the error never says so.**
Two blank lines gets you `specs file malformed after N characters`, pointing at a byte
offset in a 10 KB file. Zero blank lines is worse: the new spec is quietly absorbed into
the *previous* one, and the first thing you hear about it is
`gcc: fatal error: cannot execute '*self_spec:': No such file or directory` at the next
link. `gcc -dumpspecs` already ends with that blank line, so append directly to it. Also
note `-dumpspecs` prints the **effective** specs — dump while your own specs file is
installed and you get a file with the flags applied twice and a duplicate `*self_spec`, so
delete it before regenerating.

**CET marking is an intersection, and glibc decides it for the whole system.** The
`IBT`/`SHSTK` note in `.note.gnu.property` survives only if *every* input object carries
it, and the linker drops it silently otherwise. glibc supplies `crt1.o`, `crti.o` and
`crtn.o` to every binary that gets linked, so a glibc built without `-fcf-protection`
strips CET marking off the entire OS — the `endbr64` instructions are still emitted, they
are just never enforced, because the loader has nothing telling it to turn CET on. Which is
the worst outcome: it looks hardened and costs the code size without buying the protection.
Verify with `readelf -n` on a binary, not by grepping the asm for `endbr64`.

**A graphical boot menu can stop the machine from booting.** GRUB's `gfxpayload=keep`
hands its graphics mode straight to the kernel, which is right only if the kernel can
drive it. With `CONFIG_FB` and `CONFIG_FRAMEBUFFER_CONSOLE` off, the VT is left unusable,
`setfont` fails, LFS' `S70console` exits 1, and init halts at "Press Enter to continue"
with nobody there to press it. `gfxpayload=text` keeps the menu graphical and restores
text mode before handing over. This is the second time a purely cosmetic feature has
produced an unbootable system in this project — the first was an fstab entry for
`securityfs`.

**A shell variable called `STAMP` is not yours.** `/lib/lsb/init-functions` assigns one
inside `log_info_msg` without declaring it local, so it silently overwrites a caller's
variable of the same name. A first-boot script that recorded "already ran" in `$STAMP`
wrote its marker to a file called `Aug 14 14:24:57 +00:00 bastion` in `/`, never found it
again, and therefore re-ran on *every* boot — regenerating SSH host keys each time. There
is no error message; the only symptom is a host whose fingerprints keep changing.
`init-functions` also owns `BOOTLOG`, `BRACKET`, `COL`, `INFO`, `NORMAL`, `SCRIPT_STAT`,
`SUCCESS`, `FAILURE` and `WARNING`.

**Do not improve on the book's grub build.** Rebuilding grub with a hand-written configure
line — dropping `sed 's/--image-base/--nonexist-linker-option/'`, which looks like a
workaround for something long fixed — makes `grub-install` refuse the result:
`kernel.img is miscompiled: its start address is 0x9074 instead of 0x9000: ld.gold bug?`.
The error blames the linker for a configure choice.

**The book's commands are written to run exactly once.** Six of them use `ln -sv` with no
`-f`, so on a rebuild the link already exists, `ln` fails, and `set -e` takes the package
down with it. One of those points at a directory, where `ln -sf` does something worse than
fail — it cheerfully creates the new link *inside* the old target — so the fix is `ln -sfn`.
Worth scanning for before starting a multi-hour rebuild rather than discovering them one
package at a time.

## Credits

Built and maintained by [**pi-stachio**](https://github.com/pi-stachio).

Standing on the shoulders of the [Linux From Scratch](https://www.linuxfromscratch.org/)
project — the book, [jhalfs](https://github.com/lfs-book/jhalfs), and BLFS are theirs, and
this repository is a set of scripts for running their work reproducibly, not a substitute
for reading it. BastionOS is not affiliated with or endorsed by the LFS project.

*Previously released as BareboneSecurityOSLite; renamed at v1.3.0.*

## Licence

[MIT](LICENSE) — the scripts in this repository are original work and free to reuse.

This covers the scripts only. The LFS book, jhalfs, and every package these scripts
download carry their own separate licences, and the built system is a composite of them.
