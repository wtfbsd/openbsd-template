# AGENTS.md — the contract for an agent working in this repository

## What this repository is

A template for shipping a per-product distribution that is an **overlay on
unmodified upstream OpenBSD**. The placeholders are **ExampleBSD** (slug
`examplebsd`) and the host name `example.org`.

The base system is never patched. The overlay becomes a **site set**
(`install.site(5)`): a gzip(1) compressed tar(1) archive named
`site${VERSION}.tgz` (`site80.tgz` for release 8.0), rooted in `/`, which
the installer unpacks over the new root and then runs as `/install.site` in
a chroot(8) based at that root. An unattended install is driven by
`autoinstall(8)` with a response file (`question = answer` lines).

## The overlay rules

1. Never patch the OpenBSD source tree and never patch the ports tree.
2. `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@` and `@BRAND_URL@` are substituted by
   `build.sh` from `product.conf`.
3. A staged path with a literal `@SLUG@` in it is renamed to the slug.
4. `overlay/base/rootfs/etc/motd.template` becomes the live `/etc/motd`.
5. OpenBSD has no `rc.conf.d`: there is one `rc.conf.local` per root. The
   base file is `overlay/base/rootfs/etc/rc.conf.local`; the file a profile
   ships under `rootfs/etc/rc.conf.local` is a fragment that `build.sh`
   appends to the base file.
6. A daemon is enabled the OpenBSD way: `<daemon>_flags=` in
   `rc.conf.local` (`rc.conf(8)`), package daemons in `pkg_scripts`.
7. The site set is archived with the owner `0:0` and a fixed modification
   time, and it holds a **file list only**: no entry for `.` and none for
   a directory, so the installer never changes the owner or the mode of an
   existing directory of the new root. The `tar(1)` of OpenBSD has no
   owner override, so on OpenBSD the build refuses to run as a user other
   than root. The list of the files is read the way the `tar(1)` of the
   host reads it: `-I` on OpenBSD, `-T` with the GNU tar and the bsdtar.
8. Every `rm -rf` in `build.sh` goes through the guard function of `build.sh`; the documented exceptions are the Jenkinsfile, which removes the fixed paths `./out` and `media.iso` of its own workspace, and `ci/media.sh`, whose own `rmrf` guard removes the work directory of the run it made with `mktemp -d` and refuses a path outside it. The media stage builds a tar of the two inputs (`site.tgz`, `install.conf`) and feeds it to the helper on stdin (`ci/media.sh prepare RELEASE ARCH < inputs.tar`), the image coming back on stdout.
9. **No ZFS at all. FFS is the only filesystem choice.** The build refuses
   `FILESYSTEM_ROOT=zfs` and `ZFS_DATA_POOL=yes`.
10. The mt76 wireless driver is never enabled, loaded, configured or even
    mentioned: `build.sh` fails the build when an overlay file mentions it.
11. The name of the host is `/etc/myname`, never a `hostname=` variable.
12. The site set is key-only: the operator account and its public key are
    **required inputs** of the build (`-u USER -k PUBKEYFILE`). A build
    without them is refused; a dry run reports the missing input.
13. The password of the operator account is a **required input of the
    desktop profile** (`-P HASHFILE`, a bcrypt hash). The desktop has no
    sshd, so the console is the only way in. The hash is read from the
    file, never from argv, and never printed. The appliance does not need
    it: its response file holds the 13 asterisks that disable the
    password logins.
14. The operator account is a member of `wheel` and the two profiles ship
    a `doas.conf` (mode 0600, owner root:wheel): `permit nopass :wheel`
    for the appliance, `permit persist :wheel` for the desktop. The
    membership is made by `install.site` (`usermod -G wheel`), because
    `autoinstall(8)` does not ask for the groups of the account.
15. A package that `install.site` cannot install is **not** a silent
    failure: the failed packages are written in `/etc/<slug>-pkg-failed`,
    the message of the day warns about it, and `install.site` exits
    non-zero.
16. A `usermod -G wheel` that fails is **not** a silent failure either:
    the failure is written in `/etc/<slug>-wheel-failed`, the message of
    the day warns about it, `install.site` goes on with the packages and
    exits non-zero at the end.
17. The warnings of the message of the day are appended **once**: a
    second run of `install.site` does not repeat them.
18. The response file holds the hash of the password of the operator
    account: it is a secret. It is written with the mode **0600**, and
    the CI archives `install.conf.redacted` — never `install.conf`.

## How to build

```sh
./build.sh -c product.conf -n -u operator -k operator.pub   # dry run: writes nothing
./build.sh -c product.conf -r 8.0 -u operator -k operator.pub # out/site80.tgz
./build.sh -c product.conf -r 8.0 -u operator -k operator.pub -p both
./build.sh -c product.conf -r 8.0 -u operator -k operator.pub -P pw.hash -p desktop
```

`product.conf` is parsed, never sourced: only the keys of wtfbsd/agents
`questions.yaml` are accepted — the name, the slug, the architecture, the
filesystem, the packages, the installer, the motd, the brand and the
network (`NET_IF`, `NET_IPV4`, `NET_NETMASK`, `NET_GATEWAY`, `NET_DNS`
and `DOMAIN`) — and a value with a shell metacharacter is refused. The
base system itself is built with `release(8)` and only on OpenBSD
(`WTFBSD_BUILD_BASE=yes`); the build refuses that path anywhere else.

## The install media

`ci/media.sh prepare RELEASE ARCH < inputs.tar > media.iso`
puts the site set and the response file into a copy of the stock install
image of the release and rebuilds it with `mkhybrid(8)`; it runs on
OpenBSD, as root. The release and the architecture are given, never
guessed from the name of the site set and never read out of the
environment. The response file goes into the **root of the ramdisk of
`bsd.rd`** (with `rdsetroot(8)`), never into the root of the CD.

The stock image is not job input: the media node holds it root-owned,
`/usr/local/share/wtfbsd-media/install80.iso`, with the signed `SHA256`
file of the release next to it (`SHA256.8.0`); the helper refuses a
missing, symlinked, non-root or group/other-writable file and checks the
sha256 before it mounts the image `-o rdonly,nodev,nosuid`. The image tree
must hold only regular files and directories, and every path of the copy
is refused when it is a link or resolves outside the copy.

stdin carries exactly `site.tgz` and `install.conf` as a POSIX `ustar`
tar. The helper checks each 512-byte header by its bytes (type flag `0`
or NUL, the exact name, no prefix, no link name, magic, checksum; `x`,
`g`, `L`, `K` refused), never by a `tar -t` listing, then each extracted
file (regular, one link, under its cap). The work directory comes from
`mktemp -d /tmp/wtfbsd-media.XXXXXX` and is checked to be root-owned,
mode `0700`. The image is written to `$WORK/out.iso`, then to stdout,
only after every step succeeded; the logging goes to stderr.

The CI runs the installed copy of the helper through `doas(1)`, never the
copy of the workspace: `permit nopass <jenkins-user> as root cmd
/usr/local/libexec/wtfbsd-media`.

## How to test

```sh
tests/run-tests.sh    # no root, no network, no hypervisor
```

Every case needs a red run against the code before the behaviour existed.
Never weaken a case to make it pass. The VM tests drive `ci/vm.sh` with the
fake provider in `tests/fixtures`, so no real machine is started.

## The generic template rule

This repository is public and generic: anyone must be able to fork it and
run it on their own Jenkins.

- No organisation specific name anywhere: no company or project name other
  than `wtfbsd` and `ExampleBSD`, no real host name, no real address, no
  internal service name, no ticket number, no user name.
- No credential in the repository. A Jenkins credential is referenced by its
  documented ID only.
- Every `ssh` and every `scp` a step of this repository runs is hardened:
  `-o BatchMode=yes`, `-o StrictHostKeyChecking=accept-new` and
  `-o UserKnownHostsFile=<a file in the workspace>`.
- Every VM operation goes through `ci/vm.sh`, which dispatches to
  `ci/providers/<provider>.sh` or to the file named by
  `$WTFBSD_VM_PROVIDER_PATH`. An unknown provider fails closed.
- `tests/run-tests.sh` fails when a file holds something that looks like a
  secret: an address, a mail address, a key, a token. The names of an
  organisation are never in this repository: the deny-list that holds
  them is private and is named by `$WTFBSD_DENYLIST`.
- A round report is never tracked: `ROUND-REPORT*.md` is in `.gitignore`
  and the test suite fails when one of them is tracked.
