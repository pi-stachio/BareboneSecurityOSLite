# BareboneSecurityOSLite

A complete **Linux From Scratch 13.0** system — compiled from source, bootable, and
reproducible from a single set of scripts on a Windows machine via WSL2.

No distro packages. No installer. Every binary in the running system was compiled locally
from upstream source, starting from a cross-toolchain built by hand.

```
LFS 13.0 (SysV) · x86_64 · kernel 6.18.10 · gcc 15.2.0 · glibc 2.43 · binutils 2.46
651 binaries · 1.5 GB installed · GRUB on MBR · boots in QEMU, Hyper-V or VirtualBox
```

---

## Try it without building it

Grab the disk image from [Releases](../../releases), then:

```bash
qemu-system-x86_64 -enable-kvm -m 2048 \
    -drive file=lfs-13.0-sysv.qcow2,format=qcow2 -nographic
```

Log in as **`root`** / **`lfs`**. `poweroff` shuts it down; `Ctrl-a` then `x` detaches.

It's a 12 GB virtual disk that compresses to ~489 MB. Works in Hyper-V and VirtualBox too
(convert with `qemu-img convert`).

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

### Optional: make it administrable

The base LFS system has no `ping`, no `ssh`, no `sudo` and no TLS trust store. Two more
scripts add a minimal, useful set from BLFS:

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

## Credits

Built and maintained by [**pi-stachio**](https://github.com/pi-stachio).

Standing on the shoulders of the [Linux From Scratch](https://www.linuxfromscratch.org/)
project — the book, [jhalfs](https://github.com/lfs-book/jhalfs), and BLFS are theirs, and
this repository is a set of scripts for running their work reproducibly, not a substitute
for reading it.

## Licence

Not yet chosen — until one is added, default copyright applies and reuse rights are
reserved. The scripts here are original; the LFS book and package sources they fetch carry
their own separate licences.
