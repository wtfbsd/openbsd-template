#!/bin/sh
#
# ci/media.sh — put the site set and the autoinstall(8) response file into
# the stock install media.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The stock upstream media (installNN.iso) holds the sets of an OpenBSD
# release. install.site(5) calls the site file a "set" that sits next to
# the other sets: the installer unpacks site${VERSION}.tgz over the new
# root and runs /install.site from it.
#
#   ci/media.sh prepare IMAGE SITE_TGZ INSTALL_CONF RELEASE ARCH [OUT_IMAGE]
#
# The release is given: it is the release the sets of the media are for
# (8.0). It is never guessed out of the name of the site set and it is
# never read out of the environment.
#
# The architecture is given too: it is the architecture of the sets of
# the media (amd64, aarch64). It is never read out of the environment
# either, and the helper refuses a run when the tree of the image holds
# no set of that architecture.
#
# OUT_IMAGE is where the rebuilt image is written. It defaults to
# IMAGE: the image that was given is replaced by the rebuilt one.
#
# The image is an ISO9660 image and it is read-only, so the tree is
# copied out of it, the site set and the response file are put into the
# copy, and the image is rebuilt with mkhybrid(8), the way
# src/distrib/amd64/cdfs/Makefile builds the install CD of a release.
# The UEFI entry of the image is the EFI boot file of the release,
# which sits in the directory of the release and of the architecture
# (8.0/amd64/eficdboot): without it the image has no UEFI entry and a
# UEFI machine cannot boot it.
#
# The response file goes into the ramdisk of bsd.rd and NOT into the root
# of the CD: install.sub(8) reads /auto_install.conf from the root of the
# bsd.rd ramdisk (or fetches it over HTTP with the DHCP next-server). A
# file in the root of the CD is never read: the installer waits at the
# (I)nstall/(A)utoinstall prompt.
#
# The ramdisk is changed with rdsetroot(8), the tool of OpenBSD for it:
#
#   gzip -dc bsd.rd > bsd.rd.raw     (when bsd.rd is a gzip file)
#   rdsetroot -x bsd.rd.raw rd.img
#   vnconfig rd.img                  (vnconfig(8) prints the unit it used)
#   mount /dev/vnd1a $WORK/mnt-rd
#   cp auto_install.conf $WORK/mnt-rd
#   umount $WORK/mnt-rd
#   vnconfig -u vnd1
#   rdsetroot bsd.rd.raw rd.img
#   gzip -9n bsd.rd.raw               (when bsd.rd was a gzip file)
#
# Every device is allocated by vnconfig(8), which prints the unit it
# used, and every mount point lives under the work directory of the run:
# the helper names no device and creates no directory in the root of the
# file system, so it cannot take the device or the mount point of
# another owner away.
#
# The helper needs OpenBSD and root: rdsetroot(8), mkhybrid(8), vnconfig(8)
# and mount(8) are the tools of OpenBSD, and the mounts need root. It is
# run by the CI job, never by the test suite.
#
# The helper runs as root, so it touches nothing outside the spool
# directory of the media node (/var/spool/wtfbsd-media). The path is a
# constant of the helper: doas(1) resets the environment of the run, so
# a value of the environment of the job would never reach the root run,
# and the job and the helper would not agree on the directory. The
# image, the site set, the response file, the image it writes and the
# work directory of the run are all inside the spool, none of them is a
# symbolic link, and none of them holds a "..": the helper of the CI
# runs from a directory the account of the job can write, and a root
# that follows a link of that account would run a file of that account.
#
# What it does:
#   1. checks the host, the tools and the spool,
#   2. mounts the image read-only and copies the tree out of it,
#   3. puts the site set next to the sets of the release, in the
#      directory of the release and of the architecture (8.0/amd64),
#   4. points the response file at the sets of the media (Location of
#      sets = cd0, Pathname to the sets = 8.0/amd64),
#   5. puts the response file into the root of the ramdisk of bsd.rd,
#   6. lists the site set in the index.txt of the media, when the media
#      holds one: the helper never creates an index.txt,
#   7. rebuilds the image with mkhybrid(8), with the EFI boot file of
#      the release: an image without it cannot boot on a UEFI machine.

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG prepare IMAGE SITE_TGZ INSTALL_CONF RELEASE ARCH [OUT_IMAGE]"
	exit "${1:-2}"
}

# rmrf <path> <guardroot> — rm -rf only for a non-empty path under root
rmrf() {
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

# release_ok <value> — the release is N.N (8.0, 7.10)
release_ok() {
	case $1 in
	'' | *[!0-9.]*) return 1 ;;
	*.*) ;;
	*) return 1 ;;
	esac
	case $1 in
	*.*.*) return 1 ;;
	esac
	_maj=${1%%.*}
	_min=${1#*.}
	[ -n "$_maj" ] || return 1
	[ -n "$_min" ] || return 1
	case "${_maj}${_min}" in
	*[!0-9]*) return 1 ;;
	esac
	return 0
}

# arch_ok <value> — the architecture is a lowercase name: amd64, aarch64
arch_ok() {
	case $1 in
	'' | *[!a-z0-9]*) return 1 ;;
	esac
	return 0
}

# vnd_attach <file> — attach the file to a free device and print the name
# of the device. vnconfig(8) allocates the unit and prints its name; a
# name that is not a device is refused, so the helper never builds a
# device path out of something it does not understand.
vnd_attach() {
	_name=$(vnconfig "$1" 2> /dev/null) || return 1
	_name=${_name%% *}
	case $_name in
	vnd[0-9] | vnd[0-9][0-9] | vnd[0-9][0-9][0-9]) ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$_name"
}

# vnd_unit_for <image> — the unit that covers the image, according to
# vnconfig -l. The lines of the list look like
#   vnd0: covering /path/to/image on sd0a, inode 12345
# and an unused unit prints
#   vnd1: not in use
# The unit is the one of the image that was given: a unit that covers
# another image is the unit of another owner.
vnd_unit_for() {
	_list=$(vnconfig -l 2> /dev/null) || return 1
	printf '%s\n' "$_list" | awk -v img="$1" '
		{
			unit = $1
			sub(/:$/, "", unit)
			path = $0
			sub(/^vnd[0-9]+: covering /, "", path)
			sub(/ on [^ ]+, inode [0-9]+$/, "", path)
			if (path == img) { print unit; exit }
		}'
}

# The verb comes first: the CI calls the helper with it. The three files
# follow it, the release of the media is the fourth argument, the
# architecture of the media is the fifth one and the image it writes is
# the sixth one.
case ${1:-} in
prepare) shift ;;
esac
[ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage 2
IMAGE=$1
SITE=$2
CONF=$3
# The release is the release of the sets of the media. It is given, and
# it is never read out of the name of the site set: site100.tgz is the
# site set of the release 10.0, not of the release 1.00.
RELEASE=${4:-}
# The architecture is the architecture of the sets of the media: the
# sets of the media sit in the directory of the release and of the
# architecture (8.0/amd64). It is given too, and it is never read out
# of the environment.
ARCH=${5:-}
# The image the helper writes: the image that was given, when the caller
# does not name another one.
OUT=${6:-$IMAGE}
[ -n "$RELEASE" ] \
	|| die 'the release is required: give it as the fourth argument (N.N)'
release_ok "$RELEASE" || die "the release must be N.N, e.g. 8.0 (got: $RELEASE)"
[ -n "$ARCH" ] \
	|| die 'the architecture is required: give it as the fifth argument (amd64)'
arch_ok "$ARCH" || die "the architecture must be a lowercase name, e.g. amd64 (got: $ARCH)"

# The ramdisk of the install media is changed with the tools of OpenBSD:
# there is no rdsetroot(8) and no mkhybrid(8) anywhere else, and the
# mounts need root.
[ "$(uname -s)" = OpenBSD ] \
	|| die "this helper runs on OpenBSD (uname -s says $(uname -s)): the ramdisk of bsd.rd is changed with rdsetroot(8)"
[ "$(id -u)" = 0 ] || die 'mounting the media needs root'
for _t in vnconfig mount umount rdsetroot mkhybrid gzip; do
	command -v "$_t" > /dev/null 2>&1 || die "required tool missing: $_t (stock on OpenBSD)"
done

# The spool directory of the media node: the helper, running as root,
# touches nothing outside it. The path is a constant of the helper:
# doas(1) resets the environment of the run, so a value of the
# environment of the job would never reach the root run, and the job and
# the helper would not agree on the directory. The directory must exist,
# and it must not be writable by others: a directory another account can
# write is a directory another account can put a file in, and the helper
# would read it as root.
SPOOL=/var/spool/wtfbsd-media
case "/$SPOOL/" in
*/../*) die "the spool directory holds a ..: $SPOOL" ;;
esac
[ -d "$SPOOL" ] \
	|| die "the spool directory does not exist: $SPOOL (the media node holds it: mkdir -p $SPOOL)"
_mode=$(ls -ld "$SPOOL" 2> /dev/null | cut -c1-10)
case $_mode in
'') die "cannot read the mode of the spool directory: $SPOOL" ;;
????????w*) die "the spool directory is writable by others: $SPOOL" ;;
esac

# spool_path <path> <what> — the path is inside the spool, it is not a
# symbolic link and it holds no "..".
spool_path() {
	_p=$1
	_what=$2
	case $_p in
	/*) ;;
	*) _p="$PWD/$_p" ;;
	esac
	case "/$_p/" in
	*/../*) die "the $_what holds a ..: $1" ;;
	esac
	if [ -L "$_p" ]; then
		die "the $_what is a symbolic link: $1"
	fi
	case $_p in
	"$SPOOL"/*) ;;
	*) die "the $_what is not under the spool directory $SPOOL: $1" ;;
	esac
}

spool_path "$IMAGE" 'image'
spool_path "$SITE" 'site set'
spool_path "$CONF" 'response file'
spool_path "$OUT" 'image it writes'

[ -f "$IMAGE" ] || die "no such image: $IMAGE"
[ -f "$SITE" ] || die "no such site set: $SITE"
[ -f "$CONF" ] || die "no such response file: $CONF"

SITENAME=$(basename -- "$SITE")

# The tree is copied out of the image, because the image is read-only.
# The copy is the tree the new image is built from, and it is removed
# when the helper ends. The mount points live under it: the helper never
# creates a directory in the root of the file system, and it creates
# nothing outside the spool either.
WORK=$(mktemp -d "$SPOOL/work.XXXXXX") \
	|| die "cannot create a work directory under the spool directory $SPOOL"
CD_TREE="$WORK/tree"
MNT="$WORK/mnt"
RD_MNT="$WORK/mnt-rd"
# The devices vnconfig(8) allocated, and the steps that ran. A flag is
# set BEFORE the command that takes the resource, so the cleanup of a
# run that was signalled in the middle of that command still knows about
# it. The flag is cleared in the branch that handles the failure of the
# command.
CD_PATH=''
CD_VND=''
CD_MOUNTED=''
RD_PATH=''
RD_VND=''
RD_MOUNTED=''
# The cleanup sets it when a mount could not be unmounted: the work
# directory of a mount that is still up stays where it is.
_cleanup_failed=0

# The cleanup runs once, whichever trap fires first: a signal trap calls
# it and then exits with the code of the signal, and the exit trap calls
# it again on the way out. It is idempotent, so the second call does
# nothing.
#
# Only the steps that ran are undone: a flag is set before every attach
# and every mount, and cleared when the step is undone. The steps are
# undone in the reverse order of the mounting: the ramdisk is unmounted,
# its device is detached, the media is unmounted and its device is
# detached. A step that was never reached is never undone, so the
# cleanup never takes the device or the mount point of another owner.
#
# The device of an attach is the unit vnconfig(8) printed. When the run
# was signalled before the name was read, the unit is the one that
# covers the image, according to vnconfig -l: the unit of another image
# belongs to another owner and is never detached.
cleanup() {
	if [ -n "${_cleaned:-}" ]; then return 0; fi
	_cleaned=1
	if [ -n "${RD_MOUNTED:-}" ]; then
		if umount "$RD_MNT" 2> /dev/null; then
			RD_MOUNTED=''
		fi
	fi
	if [ -n "${RD_PATH:-}" ]; then
		_unit=${RD_VND:-}
		if [ -z "$_unit" ]; then
			_unit=$(vnd_unit_for "$RD_PATH" 2> /dev/null) || _unit=''
		fi
		if [ -n "$_unit" ]; then
			if vnconfig -u "$_unit" 2> /dev/null; then
				RD_PATH=''
				RD_VND=''
			fi
		fi
	fi
	if [ -n "${CD_MOUNTED:-}" ]; then
		if umount "$MNT" 2> /dev/null; then
			CD_MOUNTED=''
		fi
	fi
	if [ -n "${CD_PATH:-}" ]; then
		_unit=${CD_VND:-}
		if [ -z "$_unit" ]; then
			_unit=$(vnd_unit_for "$CD_PATH" 2> /dev/null) || _unit=''
		fi
		if [ -n "$_unit" ]; then
			if vnconfig -u "$_unit" 2> /dev/null; then
				CD_PATH=''
				CD_VND=''
			fi
		fi
	fi
	# A mount that is still up is reported, and the work directory of
	# the run stays where it is: the tree of a mount that is still up
	# lives under it. A device that is still attached is reported too:
	# the device of another owner is never detached, so a device of
	# this run that stays attached is a leak.
	if [ -n "${RD_MOUNTED:-}" ]; then
		printf '%s: %s is still mounted\n' "$PROG" "$RD_MNT" >&2
		_cleanup_failed=1
	fi
	if [ -n "${CD_MOUNTED:-}" ]; then
		printf '%s: %s is still mounted\n' "$PROG" "$MNT" >&2
		_cleanup_failed=1
	fi
	if [ -n "${RD_PATH:-}" ]; then
		printf '%s: the device of %s is still attached\n' "$PROG" "$RD_PATH" >&2
		_cleanup_failed=1
	fi
	if [ -n "${CD_PATH:-}" ]; then
		printf '%s: the device of %s is still attached\n' "$PROG" "$CD_PATH" >&2
		_cleanup_failed=1
	fi
	# The work directory goes only when no mount is left: the tree of a
	# mount that is still up lives under it.
	if [ -z "${CD_MOUNTED:-}${RD_MOUNTED:-}" ]; then
		( rmrf "$WORK" "$SPOOL" ) 2> /dev/null || true
	fi
	return 0
}
# The trap is armed before the first directory under the work directory
# is made: a failure between the two would leave the work directory
# behind.
trap 'rc=$?; cleanup; if [ "$_cleanup_failed" -eq 1 ] && [ "$rc" -eq 0 ]; then exit 1; fi; exit "$rc"' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$CD_TREE"

# vnconfig(8) with a file attaches the file to a free device and prints
# the name of the device it used. The image is mounted read-only: the
# 'c' partition of the device is the whole disc.
CD_PATH=$IMAGE
if ! VND=$(vnd_attach "$IMAGE"); then
	CD_PATH=''
	die "vnconfig(8): cannot attach $IMAGE to a free device"
fi
CD_VND=$VND
mkdir -p "$MNT"
CD_MOUNTED=1
if ! mount -t cd9660 "/dev/${VND}c" "$MNT"; then
	CD_MOUNTED=''
	die "mount(8): cannot mount /dev/${VND}c on $MNT (the image must be the ISO9660 install image installNN.iso)"
fi
# The copy keeps the symbolic links and the modes of the media.
( cd "$MNT" && tar cf - . ) | ( cd "$CD_TREE" && tar xf - ) \
	|| die "cannot copy the tree of the image out of $MNT"
# A mount that is still up keeps its flag: the cleanup tries to unmount
# it again, and the work directory of the run stays where it is when it
# cannot.
if ! umount "$MNT"; then
	die "umount(8): cannot unmount $MNT"
fi
CD_MOUNTED=''
if ! vnconfig -u "$VND"; then
	die "vnconfig(8): cannot detach $VND"
fi
CD_PATH=''
CD_VND=''

# The names of the tree are the raw ones (8.0, not 8_0 and not 8.0;1):
# the boot loader opens cd0a:/8.0/amd64/bsd.rd by its name.
SETDIR="$CD_TREE/$RELEASE/$ARCH"
[ -d "$SETDIR" ] \
	|| die "the media holds no $RELEASE/$ARCH directory: the release is $RELEASE and the architecture is $ARCH (the tree holds: $(ls "$CD_TREE" 2> /dev/null | tr '\n' ' '))"

mkdir -p "$SETDIR"
cp "$SITE" "$SETDIR/$SITENAME" || die "cannot copy the site set into the media"
log "site set: /$RELEASE/$ARCH/$SITENAME"

# install.site(5): a site set that is fetched over HTTP(S) has to be
# listed in index.txt, otherwise the installer does not offer it. The
# install is from the CD and the media of a release holds no index.txt:
# the helper never creates one. It lists the site set in the index.txt of
# the media only when the media holds one.
if [ -f "$SETDIR/index.txt" ]; then
	if ! grep -qxF "$SITENAME" "$SETDIR/index.txt"; then
		printf '%s\n' "$SITENAME" >> "$SETDIR/index.txt"
		log "index.txt: added $SITENAME"
	fi
fi

# The response file: the sets are on the media, so the answer that names
# a server is dropped and the installer is pointed at the CD. The
# pathname of the sets is the one of the tree: <release>/<arch>.
RESP="$WORK/auto_install.conf"
sed -e 's/^[[:space:]]*Location of sets[[:space:]]*=.*/Location of sets = cd0/' \
	-e '/^[[:space:]]*HTTP Server[[:space:]]*=/d' \
	-e '/^[[:space:]]*Pathname to the sets[[:space:]]*=/d' \
	"$CONF" > "$RESP" || die 'cannot read the response file'
printf 'Pathname to the sets = %s/%s\n' "$RELEASE" "$ARCH" >> "$RESP"
log "response file: Location of sets = cd0, Pathname to the sets = $RELEASE/$ARCH"

# The ramdisk of bsd.rd: the installer reads /auto_install.conf from its
# root. In the media of a release bsd.rd is a gzip file.
is_gzip() { # is_gzip <file> — the file starts with the magic number of gzip(1)
	[ -f "$1" ] || return 1
	_magic=$(od -An -tx1 -N2 "$1" 2> /dev/null | tr -d ' \n')
	[ "$_magic" = 1f8b ]
}

RDPATH="$SETDIR/bsd.rd"
[ -f "$RDPATH" ] \
	|| die "the media holds no $RELEASE/$ARCH/bsd.rd: the release is $RELEASE and the architecture is $ARCH"
RD_RAW="$WORK/bsd.rd.raw"
RD_IMG="$WORK/rd.img"
GZ=0
if is_gzip "$RDPATH"; then
	GZ=1
	gzip -dc "$RDPATH" > "$RD_RAW" || die 'gzip(1): cannot uncompress bsd.rd'
else
	cp "$RDPATH" "$RD_RAW" || die 'cannot copy bsd.rd'
fi
# rdsetroot(8) -x builds the image of the ramdisk out of the raw
# ramdisk; rdsetroot(8) writes the ramdisk of the image back into the
# raw ramdisk.
rdsetroot -x "$RD_RAW" "$RD_IMG" || die "rdsetroot(8): cannot build $RD_IMG"
RD_PATH=$RD_IMG
if ! RD_VND=$(vnd_attach "$RD_IMG"); then
	RD_PATH=''
	die "vnconfig(8): cannot attach $RD_IMG to a free device"
fi
mkdir -p "$RD_MNT"
RD_MOUNTED=1
if ! mount "/dev/${RD_VND}a" "$RD_MNT"; then
	RD_MOUNTED=''
	die "mount(8): cannot mount /dev/${RD_VND}a on $RD_MNT"
fi
cp "$RESP" "$RD_MNT/auto_install.conf" || die 'cannot write the response file into the ramdisk'
log "response file: /auto_install.conf in the ramdisk of bsd.rd"
# The ramdisk is unmounted before it is written back: the write needs
# the raw ramdisk, and a mount that is still up would hold it.
if ! umount "$RD_MNT"; then
	die "umount(8): cannot unmount $RD_MNT"
fi
RD_MOUNTED=''
if ! vnconfig -u "$RD_VND"; then
	die "vnconfig(8): cannot detach $RD_VND"
fi
RD_PATH=''
RD_VND=''
rdsetroot "$RD_RAW" "$RD_IMG" || die "rdsetroot(8): cannot write the ramdisk back into $RD_RAW"
if [ "$GZ" -eq 1 ]; then
	# gzip -9n writes no name and no timestamp in the header: the
	# image of a build is the image of every other build of it.
	gzip -9n "$RD_RAW" || die 'gzip(1): cannot compress the ramdisk'
	mv "$RD_RAW.gz" "$RDPATH" || die 'cannot put the ramdisk back into the tree'
else
	cp "$RD_RAW" "$RDPATH" || die 'cannot put the ramdisk back into the tree'
fi

# The image is rebuilt the way src/distrib/amd64/cdfs/Makefile builds the
# install CD of a release. The UEFI entry is the EFI boot file of the
# release: the media holds it in the directory of the release and of the
# architecture (8.0/amd64/eficdboot), and the name of it is the raw one.
for _f in cdbr boot.catalog; do
	[ -f "$SETDIR/$_f" ] || die "the media holds no $RELEASE/$ARCH/$_f"
done
# A media without that file has no UEFI entry: the image would boot on a
# BIOS machine only, so the helper refuses it.
[ -f "$SETDIR/eficdboot" ] \
	|| die "the media has no EFI boot file $RELEASE/$ARCH/eficdboot: a UEFI machine could not boot the result"
YEAR=$(date +%Y)
COPYRIGHT=${WTFBSD_MEDIA_COPYRIGHT:-"Copyright (c) $YEAR The OpenBSD Project"}
PUBLISHER=${WTFBSD_MEDIA_PUBLISHER:-"The OpenBSD Project"}
NEWISO="$WORK/install.iso"
set -- -a -R -T -L -l -d -D -N -o "$NEWISO" -v -v \
	-A "OpenBSD $RELEASE $ARCH Install CD" \
	-P "$COPYRIGHT" \
	-p "$PUBLISHER" \
	-V "OpenBSD/$ARCH $RELEASE Install CD" \
	-b "$RELEASE/$ARCH/cdbr" \
	-c "$RELEASE/$ARCH/boot.catalog" \
	-e "$RELEASE/$ARCH/eficdboot"
set -- "$@" "$CD_TREE"
mkhybrid "$@" || die 'mkhybrid(8): cannot build the image'

# The rebuilt image replaces the one that was given, or is written where
# the caller asked for it. The mode is 0644: the account that runs the
# job reads the result out of the spool, and the file of a root is not
# readable by anybody else otherwise.
cp "$NEWISO" "$OUT" || die "cannot write the image $OUT"
chmod 0644 "$OUT" 2> /dev/null || true
log "prepared $OUT: $SITENAME and the response file are in the media"
