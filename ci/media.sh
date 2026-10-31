#!/bin/sh
#
# ci/media.sh — put the site set and the autoinstall(8) response file into
# the stock install media.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
#   ci/media.sh prepare RELEASE ARCH < inputs.tar > media.iso
#
# The stock install image is not an input of the job. The media node holds
# it, root-owned, next to the signed SHA256 file of its release:
#
#   /usr/local/share/wtfbsd-media/install<NN>.iso    (install80.iso)
#   /usr/local/share/wtfbsd-media/SHA256.<rel>       (SHA256.8.0)
#
# The operator fetches both from a mirror, verifies the image with
# signify(1) and installs them root:wheel 0444 (see README.md). The helper
# refuses a run when either file is missing, is a symbolic link, is not
# owned by root or is writable by the group or by others, and it checks
# the sha256 of the image against the line
#
#   SHA256 (install<NN>.iso) = <64 hex digits>
#
# of the SHA256 file before it attaches the image.
#
# The release is the first argument (8.0): it names the stock image
# (install80.iso), the directory of the sets in it (8.0/<arch>) and the
# name of the site set (site80.tgz). The architecture is the second
# argument (amd64). Neither is read out of the environment.
#
# stdin carries exactly two files, as a ustar tar: site.tgz (the site
# set, install.site(5)) and install.conf (the autoinstall(8) response
# file). The helper reads every 512-byte tar header itself with dd(1) and
# od(1) before it extracts anything: the type flag (offset 156) must be
# '0' or NUL, the name (offset 0, 100 bytes) must be exactly one of the
# two names, NUL-terminated, the prefix and the link name must be empty,
# the magic must be "ustar\0" "00" and the checksum must match. Extended
# headers (x, g, L, K) are refused. After the extraction each file must
# be a regular file, not a symbolic link, with one link, and under its
# size cap (site.tgz 512 MB, install.conf 64 KB). stdin itself is capped
# at 600 MB while it is saved.
#
# The stock image is attached with vnconfig(8), which prints the unit it
# allocated, and mounted with -o rdonly,nodev,nosuid. The mounted tree
# must hold only regular files and directories; it is then copied into
# the work directory. Every path the helper writes into or reads from that
# copy is refused when it is a symbolic link or when its directory
# resolves outside the copy.
#
# The ramdisk of bsd.rd is changed with the tools of OpenBSD:
#
#   gzip -dc bsd.rd > bsd.rd.raw     (when bsd.rd is a gzip file)
#   rdsetroot -x bsd.rd.raw rd.img
#   vnconfig rd.img                  (prints the unit it used)
#   mount /dev/vnd1a $WORK/mnt-rd
#   cp auto_install.conf $WORK/mnt-rd
#   umount $WORK/mnt-rd
#   vnconfig -u vnd1
#   rdsetroot bsd.rd.raw rd.img
#   gzip -9n bsd.rd.raw              (when bsd.rd was a gzip file)
#
# and the image is rebuilt with mkhybrid(8) the way the cdfs Makefile of
# the release builds it, into $WORK/out.iso, which is then written to
# stdout. All logging goes to stderr.
#
# The work directory is made with mktemp -d /tmp/wtfbsd-media.XXXXXX; the
# helper checks that the path has that shape and that it is a directory
# owned by root with mode 0700. Every mount point and every file of the
# run lives under it, and it is removed when the run ends, unless a mount
# under it is still up.
#
# The helper needs OpenBSD and root. It is run by the CI job through
# doas(1), never by the test suite (the suite runs it with stubbed tools).

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*" >&2; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG prepare RELEASE ARCH < inputs.tar > media.iso"
	exit "${1:-2}"
}

# The directory of the stock images on the media node. doas(1) resets the
# environment, so this is a constant of the helper and not a setting.
STOCK_DIR=/usr/local/share/wtfbsd-media
# The caps, in bytes: stdin, the site set, the response file.
IN_MAX=629145600
SITE_MAX=536870912
CONF_MAX=65536

# rmrf <path> <guardroot> — rm -rf only for a non-empty path under root
rmrf() {
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

# release_ok <value> — the release is N.N (8.0, 7.10): a run of digits, a
# dot, a run of digits, and nothing else.
release_ok() {
	case $1 in
		'' | *[!0-9.]*) return 1 ;;
	esac
	case $1 in
		*.*) ;;
		*) return 1 ;;
	esac
	_maj=${1%%.*}
	_rest=${1#*.}
	case $_maj in
		'' | *[!0-9]*) return 1 ;;
	esac
	case $_rest in
		'' | *[!0-9]*) return 1 ;;
		*.*) return 1 ;;
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

# is_regular <path> — a regular file that is not a symbolic link
is_regular() {
	[ -f "$1" ] && [ ! -L "$1" ]
}

# The fields of stat(1) on OpenBSD: owner uid, mode bits, links, size.
owner_of() { stat -f %u "$1"; }
mode_of() { stat -f %Lp "$1"; }
links_of() { stat -f %l "$1"; }
size_of() { stat -f %z "$1"; }

# writable_by_others <mode> — the octal mode (444, 0755, 1777) grants
# write to the group or to others
writable_by_others() {
	_o=${1#"${1%?}"}
	_g=${1%?}
	_g=${_g#"${_g%?}"}
	case $_g$_o in
		*[2367]*) return 0 ;;
	esac
	return 1
}

# root_owned_file <path> <what> — refuse unless the path is a regular
# file (no symbolic link), owned by root, not group or other writable.
# With a third argument "dir" the path must be a directory instead.
root_owned() {
	[ ! -L "$1" ] || die "$2 is a symbolic link: $1 (install the real file root:wheel, see README.md: the media node)"
	if [ "${3:-}" = dir ]; then
		[ -d "$1" ] || die "$2 is missing: $1 (see README.md: the media node)"
	else
		[ -f "$1" ] || die "$2 is missing: $1 (see README.md: the media node)"
	fi
	[ "$(owner_of "$1")" = 0 ] || die "$2 is not owned by root: $1 (install it root:wheel, see README.md: the media node)"
	! writable_by_others "$(mode_of "$1")" \
		|| die "$2 is writable by the group or by others: $1 (files 0444, the directory 0755, see README.md: the media node)"
}

# vnd_attach <file> — attach the file to a free device and print the name
# of the device. vnconfig(8) allocates the unit and prints its name; a
# name that is not a device is refused.
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
# vnconfig -l, whose lines look like
#   vnd0: covering /path/to/image on sd0d, inode 3
#   vnd1: not in use
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

# detach_for <unit-known> <image> — detach the unit the run attached: the
# unit vnconfig printed, or, when the run was stopped before it was read,
# the unit that covers the image according to vnconfig -l.
detach_for() {
	_unit=${1:-}
	[ -n "$_unit" ] || _unit=$(vnd_unit_for "$2" 2> /dev/null) || _unit=''
	[ -n "$_unit" ] || return 0
	vnconfig -u "$_unit" 2> /dev/null
}

# hex_of <file> <offset> <length> — the bytes as lowercase hex, no spaces
hex_of() {
	dd if="$1" bs=1 skip="$2" count="$3" 2> /dev/null | od -An -v -tx1 | tr -d ' \n'
}

# nul_free_len <file> <offset> <length> — how many bytes are not NUL
nul_free_len() {
	dd if="$1" bs=1 skip="$2" count="$3" 2> /dev/null | tr -d '\000' | wc -c | tr -d ' '
}

# octal_field <file> <offset> <length> — the decimal value of an octal
# tar field (digits, padded with spaces or NULs); fails when the field
# holds anything else
octal_field() {
	dd if="$1" bs=1 skip="$2" count="$3" 2> /dev/null | tr '\000' ' ' | awk '
		{ s = s $0 }
		END {
			sub(/^ +/, "", s); sub(/ +$/, "", s)
			if (s !~ /^[0-7]+$/) exit 1
			n = 0
			for (i = 1; i <= length(s); i++) n = n * 8 + substr(s, i, 1)
			printf "%d\n", n
		}'
}

# name_hex <name> — the 100-byte name field of a member of that name
name_hex() {
	printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' \
		| awk '{ h = $0 } END { while (length(h) < 200) h = h "00"; print h }'
}

# check_header <header file> — refuse a header that is not a plain ustar
# regular file named site.tgz or install.conf; print "<name> <size>"
check_header() {
	_tf=$(hex_of "$1" 156 1)
	case $_tf in
		30 | 00) ;;
		78 | 67 | 4c | 4b) die "the input holds an extended tar header (type flag 0x$_tf): only plain ustar members are accepted" ;;
		*) die "the input holds a member that is not a regular file (tar type flag 0x$_tf)" ;;
	esac
	[ "$(hex_of "$1" 257 8)" = 7573746172003030 ] \
		|| die 'the input is not a POSIX ustar archive (a header has no "ustar\0" "00" magic)'
	_sum=$(octal_field "$1" 148 8) || die 'the input holds a tar header with a bad checksum field'
	_calc=$(od -An -v -tu1 "$1" | awk '
		{ for (i = 1; i <= NF; i++) { b++; s += (b >= 149 && b <= 156) ? 32 : $i } }
		END { print s + 0 }')
	[ "$_sum" = "$_calc" ] || die 'the input holds a tar header whose checksum does not match'
	[ "$(nul_free_len "$1" 157 100)" = 0 ] || die 'the input holds a member with a link name'
	[ "$(nul_free_len "$1" 345 155)" = 0 ] || die 'the input holds a member with a path prefix'
	_nh=$(hex_of "$1" 0 100)
	_name=''
	for _c in site.tgz install.conf; do
		[ "$_nh" = "$(name_hex "$_c")" ] && _name=$_c
	done
	[ -n "$_name" ] || die "the input holds a member the run does not name: '$(dd if="$1" bs=1 count=100 2> /dev/null | tr -d '\000' | tr -c '[:print:]' '?')' (only site.tgz and install.conf are accepted)"
	_size=$(octal_field "$1" 124 12) || die "the input holds a bad size field for $_name"
	printf '%s %s\n' "$_name" "$_size"
}

# check_tar <tar> — walk the headers of the tar; it must hold exactly
# site.tgz and install.conf, each once, under their caps
check_tar() {
	_hdr="$WORK/header"
	_blk=0
	_n=0
	_seen=' '
	while :; do
		dd if="$1" of="$_hdr" bs=512 skip="$_blk" count=1 2> /dev/null \
			|| die 'cannot read a tar header of the input'
		[ "$(wc -c < "$_hdr" | tr -d ' ')" = 512 ] || die 'the input is not a complete tar (no end of archive)'
		[ "$(nul_free_len "$_hdr" 0 512)" != 0 ] || break
		_n=$((_n + 1))
		[ "$_n" -le 2 ] || die 'the input holds more than two members (only site.tgz and install.conf are accepted)'
		_ns=$(check_header "$_hdr") || exit 1
		_name=${_ns% *}
		_size=${_ns#* }
		case $_seen in
			*" $_name "*) die "the input holds the member '$_name' more than once" ;;
		esac
		_seen="$_seen$_name "
		_max=$SITE_MAX
		[ "$_name" = site.tgz ] || _max=$CONF_MAX
		[ "$_size" -le "$_max" ] || die "the input holds $_name of $_size bytes, more than $_max"
		_blk=$((_blk + 1 + (_size + 511) / 512))
	done
	[ "$_n" -eq 2 ] || die "the input holds $_n members: exactly site.tgz and install.conf are needed"
}

# check_input_file <path> <cap> — a regular file with one link, under cap
check_input_file() {
	is_regular "$1" || die "the input holds '${1##*/}' as a link or a directory, not a regular file"
	[ "$(links_of "$1")" = 1 ] || die "the input holds '${1##*/}' with more than one link"
	[ "$(size_of "$1")" -le "$2" ] || die "the input holds '${1##*/}' larger than $2 bytes"
}

# refuse_odd_entries <dir> — the tree holds only regular files and
# directories: no symbolic link, device, fifo or socket
refuse_odd_entries() {
	_odd=$(find "$1" ! -type f ! -type d 2> /dev/null | head -n 1)
	[ -z "$_odd" ] \
		|| die "the stock image holds an entry that is not a regular file or a directory: ${_odd#"$1"/} (refused before any write)"
}

# in_tree <path> — refuse a path of the tree that is a symbolic link or
# whose directory resolves outside the tree; called before every read and
# write of a path of the tree
in_tree() {
	[ ! -L "$1" ] || die "refusing a symbolic link in the tree of the image: ${1#"$CD_TREE"/}"
	_dir=$(dirname -- "$1")
	_real=$(cd -P -- "$_dir" 2> /dev/null && pwd -P) \
		|| die "refusing a path whose directory does not resolve: ${1#"$CD_TREE"/}"
	case $_real in
		"$TREE_REAL" | "$TREE_REAL"/*) ;;
		*) die "refusing a path that resolves outside the tree of the image: ${1#"$CD_TREE"/}" ;;
	esac
}

# The verb comes first, then the release and the architecture.
case ${1:-} in
	prepare) shift ;;
	*) usage 2 ;;
esac
[ "$#" -eq 2 ] || usage 2
RELEASE=$1
ARCH=$2
[ -n "$RELEASE" ] \
	|| die 'the release is required: give it as the first argument (N.N, e.g. 8.0)'
release_ok "$RELEASE" || die "the release must be N.N, e.g. 8.0 (got: $RELEASE)"
[ -n "$ARCH" ] \
	|| die 'the architecture is required: give it as the second argument (ARCH, e.g. amd64)'
arch_ok "$ARCH" || die "the architecture must be a lowercase name, e.g. amd64 (got: $ARCH)"

[ "$(uname -s)" = OpenBSD ] \
	|| die "this helper runs on OpenBSD (uname -s says $(uname -s)): the ramdisk of bsd.rd is changed with rdsetroot(8)"
[ "$(id -u)" = 0 ] || die 'mounting the media needs root'
for _t in tar vnconfig mount umount rdsetroot mkhybrid gzip sha256 stat dd od find mktemp; do
	command -v "$_t" > /dev/null 2>&1 || die "required tool missing: $_t (stock on OpenBSD)"
done

# The stock image and the SHA256 file of its release.
NN=$(printf '%s' "$RELEASE" | tr -d '.')
ISONAME=install$NN.iso
STOCK_ISO="$STOCK_DIR/$ISONAME"
STOCK_SUMS="$STOCK_DIR/SHA256.$RELEASE"
SITENAME=site$NN.tgz
root_owned "$STOCK_DIR" 'the directory of the stock images' dir
root_owned "$STOCK_ISO" 'the stock image'
root_owned "$STOCK_SUMS" 'the SHA256 file of the release'
_want=$(awk -v n="($ISONAME)" '
	$1 == "SHA256" && $2 == n && $3 == "=" && NF == 4 { print $4; c++ }
	END { if (c != 1) exit 1 }' "$STOCK_SUMS") \
	|| die "the SHA256 file names $ISONAME not exactly once: $STOCK_SUMS"
case $_want in
	*[!0-9a-f]*) die "the SHA256 file holds no sha256 for $ISONAME: $STOCK_SUMS" ;;
esac
[ "${#_want}" -eq 64 ] || die "the SHA256 file holds no sha256 for $ISONAME: $STOCK_SUMS"
_have=$(sha256 -q "$STOCK_ISO") || die "sha256(1): cannot read $STOCK_ISO"
[ "$_have" = "$_want" ] \
	|| die "the sha256 of $STOCK_ISO does not match $STOCK_SUMS: the image is refused"
log "stock image: $ISONAME (sha256 matches SHA256.$RELEASE)"

# The work directory: mktemp -d as root, checked for its shape, its
# owner and its mode.
WORK=$(mktemp -d /tmp/wtfbsd-media.XXXXXX) || die 'cannot create the work directory'
case $WORK in
	/tmp/wtfbsd-media.??????) ;;
	*) die "the work directory does not have the shape /tmp/wtfbsd-media.XXXXXX: $WORK" ;;
esac
case ${WORK#/tmp/wtfbsd-media.} in
	*[!A-Za-z0-9]*) die "the work directory does not have the shape /tmp/wtfbsd-media.XXXXXX: $WORK" ;;
esac
[ -d "$WORK" ] && [ ! -L "$WORK" ] || die "the work directory is not a directory: $WORK"
[ "$(owner_of "$WORK")" = 0 ] || die "the work directory is not owned by root: $WORK"
case $(mode_of "$WORK") in
	700 | 0700) ;;
	*) die "the work directory does not have the mode 0700: $WORK" ;;
esac
CD_TREE="$WORK/tree"
MNT="$WORK/mnt"
RD_MNT="$WORK/mnt-rd"
INDIR="$WORK/in"
IN="$WORK/input.tar"
OUT="$WORK/out.iso"

# The flags of the cleanup: a flag is set BEFORE the command that takes
# the resource, so a cleanup after a signal in the middle of that command
# still knows about it, and it is cleared when the step is undone.
CD_PATH=''
CD_VND=''
CD_MOUNTED=''
RD_PATH=''
RD_VND=''
RD_MOUNTED=''
_cleanup_failed=0

# The cleanup runs once, whichever trap fires first, and undoes only the
# steps that ran, in reverse order: unmount the ramdisk, detach its
# device, unmount the image, detach its device. A mount that is still up
# and a device that is still attached are reported, and the work
# directory stays where it is while a mount under it is up.
cleanup() {
	if [ -n "${_cleaned:-}" ]; then return 0; fi
	_cleaned=1
	if [ -n "${RD_MOUNTED:-}" ]; then
		umount "$RD_MNT" 2> /dev/null && RD_MOUNTED=''
	fi
	if [ -n "${RD_PATH:-}" ]; then
		detach_for "${RD_VND:-}" "$RD_PATH" && RD_PATH='' && RD_VND=''
	fi
	if [ -n "${CD_MOUNTED:-}" ]; then
		umount "$MNT" 2> /dev/null && CD_MOUNTED=''
	fi
	if [ -n "${CD_PATH:-}" ]; then
		detach_for "${CD_VND:-}" "$CD_PATH" && CD_PATH='' && CD_VND=''
	fi
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
	if [ -z "${CD_MOUNTED:-}${RD_MOUNTED:-}" ]; then
		rmrf "$WORK" /tmp 2> /dev/null || true
	fi
	return 0
}
trap 'rc=$?; cleanup; if [ "$_cleanup_failed" -eq 1 ] && [ "$rc" -eq 0 ]; then exit 1; fi; exit "$rc"' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# stdin is saved under a file size limit (ulimit -f counts 512-byte
# blocks), so a stream without end cannot fill the disk, and the saved
# size is then checked against the cap.
if ! (ulimit -f $((IN_MAX / 512 + 1)) && cat > "$IN") 2> /dev/null; then
	die "cannot read the input from stdin, or it is larger than $IN_MAX bytes"
fi
[ "$(size_of "$IN")" -le "$IN_MAX" ] || die "the input is larger than $IN_MAX bytes"

# The headers are checked byte by byte before anything is extracted.
check_tar "$IN"
mkdir -m 0700 "$INDIR"
tar -xf "$IN" -C "$INDIR" || die 'cannot extract the input'
check_input_file "$INDIR/site.tgz" "$SITE_MAX"
check_input_file "$INDIR/install.conf" "$CONF_MAX"

# The stock image: attached, mounted read-only, checked for entries that
# are not regular files or directories, copied out, unmounted, detached.
mkdir -p "$CD_TREE" "$MNT"
TREE_REAL=$(cd -P -- "$CD_TREE" && pwd -P)
CD_PATH=$STOCK_ISO
if ! VND=$(vnd_attach "$STOCK_ISO"); then
	CD_PATH=''
	die "vnconfig(8): cannot attach the image to a free device"
fi
CD_VND=$VND
CD_MOUNTED=1
if ! mount -t cd9660 -o rdonly,nodev,nosuid "/dev/${VND}c" "$MNT"; then
	CD_MOUNTED=''
	die "mount(8): cannot mount /dev/${VND}c on the work directory (the stock image must be the ISO9660 install image installNN.iso)"
fi
refuse_odd_entries "$MNT"
( cd "$MNT" && tar cf - . ) | ( cd "$CD_TREE" && tar xf - ) \
	|| die 'cannot copy the tree of the image'
if ! umount "$MNT"; then
	die 'umount(8): cannot unmount the image'
fi
CD_MOUNTED=''
if ! vnconfig -u "$VND"; then
	die "vnconfig(8): cannot detach $VND"
fi
CD_PATH=''
CD_VND=''

# The directory of the sets: <release>/<arch>, raw names (8.0, not 8_0).
SETDIR="$CD_TREE/$RELEASE/$ARCH"
in_tree "$CD_TREE/$RELEASE"
in_tree "$SETDIR"
[ -d "$SETDIR" ] \
	|| die "the media holds no $RELEASE/$ARCH directory: the release is $RELEASE and the architecture is $ARCH (the tree holds: $(ls "$CD_TREE" 2> /dev/null | tr '\n' ' '))"

in_tree "$SETDIR/$SITENAME"
[ ! -e "$SETDIR/$SITENAME" ] || is_regular "$SETDIR/$SITENAME" \
	|| die "the media holds $RELEASE/$ARCH/$SITENAME as something other than a file"
cp "$INDIR/site.tgz" "$SETDIR/$SITENAME" || die 'cannot copy the site set into the media'
log "site set: /$RELEASE/$ARCH/$SITENAME"

# install.site(5): a set fetched over HTTP(S) must be listed in index.txt.
# The install is from the CD and install80.iso holds no index.txt, so the
# helper creates none; when the media does hold one, the site set is
# listed in it once.
in_tree "$SETDIR/index.txt"
if [ -f "$SETDIR/index.txt" ]; then
	if ! grep -qxF "$SITENAME" "$SETDIR/index.txt"; then
		printf '%s\n' "$SITENAME" >> "$SETDIR/index.txt"
		log "index.txt: added $SITENAME"
	fi
fi

# The response file: the sets are on the CD, so the server answers are
# dropped and the installer is pointed at cd0 and <release>/<arch>.
RESP="$WORK/auto_install.conf"
sed -e 's/^[[:space:]]*Location of sets[[:space:]]*=.*/Location of sets = cd0/' \
	-e '/^[[:space:]]*HTTP Server[[:space:]]*=/d' \
	-e '/^[[:space:]]*Pathname to the sets[[:space:]]*=/d' \
	"$INDIR/install.conf" > "$RESP" || die 'cannot read the response file'
printf 'Pathname to the sets = %s/%s\n' "$RELEASE" "$ARCH" >> "$RESP"
log "response file: Location of sets = cd0, Pathname to the sets = $RELEASE/$ARCH"

# The ramdisk of bsd.rd: install.sub reads /auto_install.conf from its
# root. In the media of a release bsd.rd is a gzip file.
is_gzip() {
	_magic=$(od -An -tx1 -N2 "$1" 2> /dev/null | tr -d ' \n')
	[ "$_magic" = 1f8b ]
}

RDPATH="$SETDIR/bsd.rd"
in_tree "$RDPATH"
is_regular "$RDPATH" \
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
rdsetroot -x "$RD_RAW" "$RD_IMG" || die 'rdsetroot(8): cannot extract the ramdisk image'
RD_PATH=$RD_IMG
if ! RD_VND=$(vnd_attach "$RD_IMG"); then
	RD_PATH=''
	die 'vnconfig(8): cannot attach the ramdisk image to a free device'
fi
mkdir -p "$RD_MNT"
RD_MOUNTED=1
if ! mount "/dev/${RD_VND}a" "$RD_MNT"; then
	RD_MOUNTED=''
	die "mount(8): cannot mount /dev/${RD_VND}a"
fi
[ ! -L "$RD_MNT/auto_install.conf" ] || die 'the ramdisk holds /auto_install.conf as a symbolic link'
cp "$RESP" "$RD_MNT/auto_install.conf" || die 'cannot write the response file into the ramdisk'
log 'response file: /auto_install.conf in the ramdisk of bsd.rd'
if ! umount "$RD_MNT"; then
	die 'umount(8): cannot unmount the ramdisk'
fi
RD_MOUNTED=''
if ! vnconfig -u "$RD_VND"; then
	die "vnconfig(8): cannot detach $RD_VND"
fi
RD_PATH=''
RD_VND=''
rdsetroot "$RD_RAW" "$RD_IMG" || die 'rdsetroot(8): cannot write the ramdisk back into bsd.rd'
in_tree "$RDPATH"
if [ "$GZ" -eq 1 ]; then
	# gzip -9n writes no name and no timestamp into the header.
	gzip -9n "$RD_RAW" || die 'gzip(1): cannot compress the ramdisk'
	mv "$RD_RAW.gz" "$RDPATH" || die 'cannot put the ramdisk back into the tree'
else
	cp "$RD_RAW" "$RDPATH" || die 'cannot put the ramdisk back into the tree'
fi

# The image is rebuilt the way src/distrib/<arch>/cdfs/Makefile builds the
# install CD. The El Torito images are <rel>/<arch>/cdbr (BIOS) and
# <rel>/<arch>/eficdboot (UEFI); without eficdboot a UEFI machine could
# not boot the result, so the helper refuses it.
for _f in cdbr boot.catalog; do
	in_tree "$SETDIR/$_f"
	is_regular "$SETDIR/$_f" || die "the media holds no $RELEASE/$ARCH/$_f"
done
in_tree "$SETDIR/eficdboot"
is_regular "$SETDIR/eficdboot" \
	|| die "the media has no EFI boot file $RELEASE/$ARCH/eficdboot: a UEFI machine could not boot the result"
YEAR=$(date +%Y)
COPYRIGHT=${WTFBSD_MEDIA_COPYRIGHT:-"Copyright (c) $YEAR The OpenBSD Project"}
PUBLISHER=${WTFBSD_MEDIA_PUBLISHER:-"The OpenBSD Project"}
set -- -a -R -T -L -l -d -D -N -o "$OUT" -v -v \
	-A "OpenBSD $RELEASE $ARCH Install CD" \
	-P "$COPYRIGHT" \
	-p "$PUBLISHER" \
	-V "OpenBSD/$ARCH $RELEASE Install CD" \
	-b "$RELEASE/$ARCH/cdbr" \
	-c "$RELEASE/$ARCH/boot.catalog" \
	-e "$RELEASE/$ARCH/eficdboot" \
	"$CD_TREE"
mkhybrid "$@" || die 'mkhybrid(8): cannot build the image'

# The image goes to stdout, only after every step succeeded.
cat "$OUT"
