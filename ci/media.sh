#!/bin/sh
#
# ci/media.sh — put the site set into the stock install media.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The stock upstream media (installNN.img, installNN.iso) holds the sets of
# an OpenBSD release. install.site(5) calls the site file a "set" that sits
# next to the other sets: the installer unpacks site${VERSION}.tgz over the
# new root and runs /install.site from it.
#
# This script copies the site set and the autoinstall(8) response file into
# a copy of the stock media:
#
#   ci/media.sh prepare IMAGE SITE_TGZ INSTALL_CONF
#
# It needs OpenBSD and root (vnconfig(8) and mount(8)): it is run by the CI
# job, never by the test suite.
#
# What it does:
#   1. attaches the image to a vnd(4) device: vnconfig(8) writes the image
#      into the device, so the partitions of the image are visible,
#   2. mounts the first partition of that device (the partition 'a' of the
#      disklabel of the install image),
#   3. puts the site set next to the sets of the release, in the directory
#      of the release and of the architecture (7.8/amd64),
#   4. writes the response file as /auto_install.conf, the name the
#      installer looks for on the media, and points it at the sets of the
#      media (Location of sets = disk) instead of a server,
#   5. lists the site set in index.txt, when the media holds one: a site
#      set that is fetched over HTTP(S) has to be listed there, otherwise
#      the installer does not select it.

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG prepare IMAGE SITE_TGZ INSTALL_CONF"
	exit "${1:-2}"
}

# The verb comes first: the CI calls the helper with it. The three files
# follow it.
case ${1:-} in
prepare) shift ;;
esac
[ $# -eq 3 ] || usage 2
IMAGE=$1
SITE=$2
CONF=$3

[ -f "$IMAGE" ] || die "no such image: $IMAGE"
[ -f "$SITE" ] || die "no such site set: $SITE"
[ -f "$CONF" ] || die "no such response file: $CONF"
[ "$(id -u)" = 0 ] || die 'mounting the media needs root'

command -v vnconfig > /dev/null 2>&1 || die 'vnconfig(8) is missing: this helper runs on OpenBSD'
command -v mount > /dev/null 2>&1 || die 'mount(8) is missing'
command -v umount > /dev/null 2>&1 || die 'umount(8) is missing'

VND=${WTFBSD_VM_VND:-vnd0}
MNT=${WTFBSD_VM_MNT:-/mnt}
SITENAME=$(basename -- "$SITE")
# The release and the architecture of the sets: the media holds them in
# <release>/<arch>/, e.g. 7.8/amd64. The release is the name of the site
# set without the dot (site78.tgz -> 7.8).
RELEASE=${WTFBSD_RELEASE:-}
ARCH=${WTFBSD_ARCH:-amd64}
if [ -z "$RELEASE" ]; then
	_num=${SITENAME#site}
	_num=${_num%.tgz}
	case $_num in
	[0-9][0-9] | [0-9][0-9][0-9])
		# 78 -> 7.8, 710 -> 7.10: the first digit is the major, the
		# rest is the minor.
		_major=${_num%"${_num#?}"}
		_minor=${_num#?}
		RELEASE="$_major.$_minor"
		;;
	*) die "cannot read the release out of the name of the site set: $SITENAME" ;;
	esac
fi

# The cleanup runs once, whichever trap fires first: a signal trap calls
# it and then exits with the code of the signal, and the exit trap calls
# it again on the way out. It is idempotent, so the second call does
# nothing.
cleanup() {
	if [ -n "${_cleaned:-}" ]; then return 0; fi
	_cleaned=1
	umount "$MNT" 2> /dev/null || true
	vnconfig -u "$VND" 2> /dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# vnconfig(8) with a file writes that file into the device: the image
# becomes a disk with the partitions of the install media.
vnconfig "$VND" "$IMAGE" > /dev/null || die "vnconfig(8): cannot attach $IMAGE to $VND"
mkdir -p "$MNT"
# The partition 'a' of the disklabel holds the sets of the release.
mount "/dev/${VND}a" "$MNT" || die "mount(8): cannot mount /dev/${VND}a on $MNT"

SETDIR="$MNT/$RELEASE/$ARCH"
mkdir -p "$SETDIR"
cp "$SITE" "$SETDIR/$SITENAME" || die "cannot copy the site set into the media"
log "site set: $SETDIR/$SITENAME"

# The response file: the installer looks for /auto_install.conf on the
# media. The sets come from the media itself, so the answer that names a
# server is dropped.
sed -e 's/^[[:space:]]*Location of sets[[:space:]]*=.*/Location of sets = disk/' \
	-e '/^[[:space:]]*HTTP Server[[:space:]]*=/d' \
	"$CONF" > "$MNT/auto_install.conf" || die 'cannot write the response file into the media'
log 'response file: /auto_install.conf (the sets come from the media)'

# install.site(5): a site set that is fetched over HTTP(S) has to be
# listed in index.txt, otherwise the installer does not offer it. The
# index.txt of the media sits next to the sets.
for _idx in "$SETDIR/index.txt" "$MNT/index.txt"; do
	[ -f "$_idx" ] || continue
	if ! grep -q "^$SITENAME\$" "$_idx"; then
		printf '%s\n' "$SITENAME" >> "$_idx"
		log "index.txt: added $SITENAME"
	fi
done

log "prepared $IMAGE: $SITENAME and auto_install.conf are in the media"
