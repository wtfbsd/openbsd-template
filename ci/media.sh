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
	log "       $PROG live RELEASE ARCH < inputs.tar > live.img"
	exit "${1:-2}"
}

# The directory of the stock images on the media node. doas(1) resets the
# environment, so this is a constant of the helper and not a setting.
STOCK_DIR=/usr/local/share/wtfbsd-media
# The caps, in bytes: stdin, the site set, the response file.
IN_MAX=629145600
SITE_MAX=536870912
CONF_MAX=65536
# The live set (live.tgz) and the uncompressed size of a set the live
# verb checks member by member.
LIVE_MAX=67108864
SET_RAW_MAX=1073741824
# The size of the live image in MB (a sparse file until it is written),
# and the directory of its work directory: the image does not fit in a
# small /tmp (and /var/tmp is a link to /tmp on OpenBSD), so the live verb
# works in a directory of its own next to the stock images, which the
# helper makes root-owned with the mode 0700.
LIVE_MB=7168
LIVE_TMP=/usr/local/share/wtfbsd-media/work
# The live user of the live image: the first free uid from this one up.
LIVE_UID_MIN=1100

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
	printf '%s\n' "$_list" | img="$1" awk 'BEGIN { img = ENVIRON["img"] }
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
# regular file named by $MEMBERS (site.tgz and install.conf for prepare,
# site.tgz and live.tgz for live); print "<name> <size>"
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
	for _c in $MEMBERS; do
		[ "$_nh" = "$(name_hex "$_c")" ] && _name=$_c
	done
	[ -n "$_name" ] || die "the input holds a member the run does not name: '$(dd if="$1" bs=1 count=100 2> /dev/null | tr -d '\000' | tr -c '[:print:]' '?')' (only $MEMBERS_TXT are accepted)"
	_size=$(octal_field "$1" 124 12) || die "the input holds a bad size field for $_name"
	printf '%s %s\n' "$_name" "$_size"
}

# member_max <name> — the cap of a member of the input
member_max() {
	case $1 in
		site.tgz) printf '%s\n' "$SITE_MAX" ;;
		live.tgz) printf '%s\n' "$LIVE_MAX" ;;
		*) printf '%s\n' "$CONF_MAX" ;;
	esac
}

# check_tar <tar> — walk the headers of the tar; it must hold exactly the
# two members of $MEMBERS, each once, under their caps
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
		[ "$_n" -le 2 ] || die "the input holds more than two members (only $MEMBERS_TXT are accepted)"
		_ns=$(check_header "$_hdr") || exit 1
		_name=${_ns% *}
		_size=${_ns#* }
		case $_seen in
			*" $_name "*) die "the input holds the member '$_name' more than once" ;;
		esac
		_seen="$_seen$_name "
		_max=$(member_max "$_name")
		[ "$_size" -le "$_max" ] || die "the input holds $_name of $_size bytes, more than $_max"
		_blk=$((_blk + 1 + (_size + 511) / 512))
	done
	[ "$_n" -eq 2 ] || die "the input holds $_n members: exactly $MEMBERS_TXT are needed"
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

# --- the live verb ---------------------------------------------------------
#
# ci/media.sh live RELEASE ARCH < inputs.tar > live.img
#
# The live image is a disk image (GPT: an EFI system partition and an
# OpenBSD partition with one FFS file system, 'a', mounted on /) that holds
# a whole installed system: the signed sets of the stock image, the
# packages of the site set and of the live set (pkg_add(1) checks their
# signatures), the live user, and the sets themselves, so the live system
# can install the product with <slug>-install. It is written to a USB stick
# or a disk with dd(1) and boots on UEFI and BIOS machines.
#
# stdin holds site.tgz (the site set of the desktop) and live.tgz (the live
# set: the live session, the installer, the doas(1) rule of the live user).
# Neither is ever run on this host: every member of both sets is read from
# its tar header first (a plain regular file, a relative path of plain
# characters, no '..', no link), the parent directories of each member in
# the new root are checked for symbolic links, and the sets are unpacked
# after the last command that runs inside the new root. The packages come
# from the mirror of installurl(5) and are verified by pkg_add(1).

# pad_hex <string> <bytes> — the field of that many bytes holding the string
pad_hex() {
	printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' \
		| n="$2" awk 'BEGIN { n = ENVIRON["n"] } { h = $0 } END { while (length(h) < 2 * n) h = h "00"; print h }'
}

# field_str <file> <offset> <length> — a NUL-padded text field; fails when
# the field holds a NUL followed by more text or a byte outside the
# printable ASCII range
field_str() {
	_fs=$(dd if="$1" bs=1 skip="$2" count="$3" 2> /dev/null | tr -d '\000')
	[ "$(pad_hex "$_fs" "$3")" = "$(hex_of "$1" "$2" "$3")" ] || return 1
	case $_fs in
		*[![:print:]]*) return 1 ;;
	esac
	printf '%s\n' "$_fs"
}

# path_ok <path> — a member path: relative, characters A-Z a-z 0-9 . _ @ + -
# and '/', no empty, '.' or '..' component
path_ok() {
	case $1 in
		'' | /* | */ | *[!A-Za-z0-9._@+/-]*) return 1 ;;
	esac
	case /$1/ in
		*//* | */./* | */../*) return 1 ;;
	esac
	return 0
}

# check_set <tgz> <name> <list> — every member of the set is a plain
# regular file with a clean relative path; the paths are written to <list>
check_set() {
	_raw="$WORK/set.tar"
	rm -f "$_raw"
	if ! (ulimit -f $((SET_RAW_MAX / 512 + 1)) && gzip -dc < "$1" > "$_raw") 2> /dev/null; then
		die "$2 is not a gzip compressed tar, or it is larger than $SET_RAW_MAX bytes unpacked"
	fi
	: > "$3"
	_hdr="$WORK/set-header"
	_blk=0
	while :; do
		dd if="$_raw" of="$_hdr" bs=512 skip="$_blk" count=1 2> /dev/null \
			|| die "cannot read a tar header of $2"
		[ "$(wc -c < "$_hdr" | tr -d ' ')" = 512 ] || die "$2 is not a complete tar (no end of archive)"
		[ "$(nul_free_len "$_hdr" 0 512)" != 0 ] || break
		_tf=$(hex_of "$_hdr" 156 1)
		case $_tf in
			30 | 00) ;;
			*) die "$2 holds a member that is not a regular file (tar type flag 0x$_tf): a set holds files only" ;;
		esac
		case $(hex_of "$_hdr" 257 8) in
			7573746172003030 | 7573746172202000) ;;
			*) die "$2 is not a ustar archive (a header has no ustar magic)" ;;
		esac
		_sum=$(octal_field "$_hdr" 148 8) || die "$2 holds a tar header with a bad checksum field"
		_calc=$(od -An -v -tu1 "$_hdr" | awk '
			{ for (i = 1; i <= NF; i++) { b++; s += (b >= 149 && b <= 156) ? 32 : $i } }
			END { print s + 0 }')
		[ "$_sum" = "$_calc" ] || die "$2 holds a tar header whose checksum does not match"
		[ "$(nul_free_len "$_hdr" 157 100)" = 0 ] || die "$2 holds a member with a link name"
		_mn=$(field_str "$_hdr" 0 100) || die "$2 holds a member whose name is not plain text"
		_mp=$(field_str "$_hdr" 345 155) || die "$2 holds a member whose path prefix is not plain text"
		[ -z "$_mp" ] || _mn="$_mp/$_mn"
		path_ok "$_mn" || die "$2 holds a member with a path that is not a plain relative path: '$_mn'"
		_size=$(octal_field "$_hdr" 124 12) || die "$2 holds a bad size field for $_mn"
		printf '%s\n' "$_mn" >> "$3"
		_blk=$((_blk + 1 + (_size + 511) / 512))
	done
	rm -f "$_raw" "$_hdr"
	[ -s "$3" ] || die "$2 holds no file"
}

# no_link_on_path <root> <list> — no member of the list, and no directory
# above it, is a symbolic link in <root>: tar(1) would write through it
no_link_on_path() {
	while IFS= read -r _p; do
		_cur=$1
		_rest=$_p
		while :; do
			case $_rest in
				*/*) _c=${_rest%%/*}; _rest=${_rest#*/} ;;
				*) _c=$_rest; _rest='' ;;
			esac
			_cur="$_cur/$_c"
			[ ! -L "$_cur" ] || die "the new root holds $_cur as a symbolic link: a set member would be written through it (refused before any write)"
			[ -n "$_rest" ] || break
			[ ! -e "$_cur" ] || [ -d "$_cur" ] \
				|| die "the new root holds $_cur as a file where a set member needs a directory"
		done
		[ ! -e "$_cur" ] || [ -f "$_cur" ] \
			|| die "the new root holds $_cur as something other than a file"
	done < "$2"
}

# pkg_names <file> — the package names of a list ('#' starts a comment,
# names are separated by blanks or new lines); a name holds letters, digits and . _ + - %, and starts with a letter or
# a digit
pkg_names() {
	[ -f "$1" ] || return 0
	sed -e 's/#.*$//' "$1" | tr -s ' \t' '\n\n' \
		| grep -v '^$' | while IFS= read -r _pn; do
		case $_pn in
			[A-Za-z0-9]*) ;;
			*) die "the package list names '$_pn': a package name starts with a letter or a digit" ;;
		esac
		case $_pn in
			*[!A-Za-z0-9._+%-]*) die "the package list names '$_pn': not a package name" ;;
		esac
		printf '%s\n' "$_pn"
	done
}

# in_root <cmd...> — run a command of the new root (signed sets and signed
# packages only: nothing of the job is in the root yet)
in_root() {
	chroot "$LV_ROOT" "$@"
}

build_live() {
	SETS='base comp man game xbase xshare xfont xserv'
	LV_ROOT="$WORK/root"
	LV_IMG="$WORK/live.img"

	# The two sets are checked member by member and unpacked into the
	# work directory, where the package lists and the name of the
	# product are read from.
	check_set "$INDIR/site.tgz" site.tgz "$WORK/site.list"
	check_set "$INDIR/live.tgz" live.tgz "$WORK/live.list"
	_slug=$(sed -n 's|^usr/local/share/\([^/]*\)/packages\.list$|\1|p' "$WORK/site.list")
	[ "$(printf '%s\n' "$_slug" | grep -c .)" = 1 ] \
		|| die 'site.tgz must hold exactly one usr/local/share/<slug>/packages.list'
	case $_slug in
		[a-z]*) ;;
		*) die "the slug of the site set must start with a lowercase letter: $_slug" ;;
	esac
	case $_slug in
		*[!a-z0-9-]*) die "the slug of the site set must match [a-z][a-z0-9-]*: $_slug" ;;
	esac
	grep -qx "usr/local/share/$_slug/live-packages.list" "$WORK/live.list" \
		|| die "live.tgz holds no usr/local/share/$_slug/live-packages.list"
	mkdir -m 0700 "$WORK/site-x" "$WORK/live-x"
	tar -xzf "$INDIR/site.tgz" -C "$WORK/site-x" || die 'cannot unpack site.tgz'
	tar -xzf "$INDIR/live.tgz" -C "$WORK/live-x" || die 'cannot unpack live.tgz'
	pkg_names "$WORK/site-x/usr/local/share/$_slug/packages.list" > "$WORK/pkgs.site" || exit 1
	pkg_names "$WORK/live-x/usr/local/share/$_slug/live-packages.list" > "$WORK/pkgs.live" || exit 1
	PKGS=$(tr '\n' ' ' < "$WORK/pkgs.site")
	PKGS=${PKGS% }
	LIVEPKGS=$(tr '\n' ' ' < "$WORK/pkgs.live")
	LIVEPKGS=${LIVEPKGS% }
	log "live: product $_slug; packages: ${PKGS:-<none>}; live packages: ${LIVEPKGS:-<none>}"

	# The stock image: attached and mounted read-only; the sets are read
	# from it.
	mkdir -p "$MNT"
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
	SETDIR="$MNT/$RELEASE/$ARCH"
	[ -d "$SETDIR" ] \
		|| die "the media holds no $RELEASE/$ARCH directory: the release is $RELEASE and the architecture is $ARCH"
	for _s in $SETS; do
		is_regular "$SETDIR/$_s$NN.tgz" || die "the media holds no $RELEASE/$ARCH/$_s$NN.tgz"
	done
	for _k in bsd bsd.mp bsd.rd; do
		is_regular "$SETDIR/$_k" || die "the media holds no $RELEASE/$ARCH/$_k"
	done

	# The image: GPT with the EFI system partition the installer makes
	# (fdisk -gy -b 532480), one 'a' partition over the rest, FFS.
	dd if=/dev/zero of="$LV_IMG" bs=1048576 count=0 seek="$LIVE_MB" 2> /dev/null \
		|| die "cannot create the image of $LIVE_MB MB"
	LV_PATH=$LV_IMG
	if ! LV_VND=$(vnd_attach "$LV_IMG"); then
		LV_PATH=''
		die 'vnconfig(8): cannot attach the live image to a free device'
	fi
	fdisk -gy -b 532480 "$LV_VND" > /dev/null || die "fdisk(8): cannot write the GPT of $LV_VND"
	printf '/ 1G-* 100%%\n' > "$WORK/disklabel.template"
	disklabel -w -A -T "$WORK/disklabel.template" "$LV_VND" \
		|| die "disklabel(8): cannot write the label of $LV_VND"
	DUID=$(disklabel "$LV_VND" 2> /dev/null | awk '$1 == "duid:" { print $2; exit }')
	case $DUID in
		[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
		*) die "disklabel(8): the label of $LV_VND has no DUID" ;;
	esac
	newfs -q "/dev/r${LV_VND}a" > /dev/null || die "newfs(8): cannot make the file system of ${LV_VND}a"
	installboot -p "$LV_VND" > /dev/null || die "installboot(8): cannot prepare the EFI system partition of $LV_VND"
	mkdir -p "$LV_ROOT"
	LV_MOUNTS=$LV_ROOT
	# async: the image is unmounted cleanly at the end, and the sets
	# unpack an order of magnitude faster than with synchronous metadata
	mount -o async "/dev/${LV_VND}a" "$LV_ROOT" || { LV_MOUNTS=''; die "mount(8): cannot mount /dev/${LV_VND}a"; }

	# The signed sets of the stock image, then the kernels.
	for _s in $SETS; do
		log "live: unpacking $_s$NN.tgz"
		tar -xzphf "$SETDIR/$_s$NN.tgz" -C "$LV_ROOT" || die "cannot unpack $_s$NN.tgz"
		# /etc of a new install comes from the etc.tgz (xetc.tgz) the base
		# (xbase) set holds, as the installer unpacks it (install.sub)
		case $_s in
			base | xbase)
				_etc="$LV_ROOT/var/sysmerge/${_s%base}etc.tgz"
				is_regular "$_etc" || die "$_s$NN.tgz holds no var/sysmerge/${_s%base}etc.tgz"
				tar -xzphf "$_etc" -C "$LV_ROOT" || die "cannot unpack ${_s%base}etc.tgz"
				;;
		esac
	done
	cp "$SETDIR/bsd.mp" "$LV_ROOT/bsd" && cp "$SETDIR/bsd" "$LV_ROOT/bsd.sp" \
		&& cp "$SETDIR/bsd.rd" "$LV_ROOT/bsd.rd" || die 'cannot copy the kernels'
	chmod 0600 "$LV_ROOT/bsd" "$LV_ROOT/bsd.sp" "$LV_ROOT/bsd.rd"
	sha256 "$LV_ROOT/bsd" | sed "s|$LV_ROOT||" > "$LV_ROOT/var/db/kernel.SHA256"
	chmod 0600 "$LV_ROOT/var/db/kernel.SHA256"

	# What the installer writes into a new root (install.sub finish_up).
	printf '%s.a / ffs rw,softdep,noatime 1 1\n' "$DUID" > "$LV_ROOT/etc/fstab"
	printf 'https://cdn.openbsd.org/pub/OpenBSD\n' > "$LV_ROOT/etc/installurl"
	ln -sf /usr/share/zoneinfo/UTC "$LV_ROOT/etc/localtime"
	dd if=/dev/random of="$LV_ROOT/etc/random.seed" bs=512 count=1 2> /dev/null
	dd if=/dev/random of="$LV_ROOT/var/db/host.random" bs=65536 count=1 2> /dev/null
	chmod u=rw-t,go= "$LV_ROOT/etc/random.seed" "$LV_ROOT/var/db/host.random"
	( cd "$LV_ROOT/dev" && sh ./MAKEDEV all ) || die 'MAKEDEV(8): cannot make the device nodes'
	mkdir -p "$LV_ROOT/usr/src" "$LV_ROOT/usr/obj" "$LV_ROOT/usr/xobj"
	in_root chown build:wobj /usr/obj /usr/xobj && chmod 770 "$LV_ROOT/usr/obj" "$LV_ROOT/usr/xobj"
	in_root chown root:wsrc /usr/src && chmod 775 "$LV_ROOT/usr/src"

	# The packages, inside the new root: the site set's into a cache the
	# live system installs the product from, then the live set's. The
	# resolver of this host is lent to the new root for the downloads.
	# The mirror is the one of installurl(5), or the one the operator
	# names in $STOCK_DIR/installurl (a local mirror of the packages of
	# the release); pkg_add(1) checks the signature of every package
	# whichever mirror served it.
	cp /etc/resolv.conf "$LV_ROOT/etc/resolv.conf" || die 'cannot lend /etc/resolv.conf to the new root'
	in_root ldconfig /usr/lib /usr/X11R6/lib /usr/local/lib
	_mirror=https://cdn.openbsd.org/pub/OpenBSD
	if [ -e "$STOCK_DIR/installurl" ] || [ -L "$STOCK_DIR/installurl" ]; then
		root_owned "$STOCK_DIR/installurl" 'the package mirror of the media node'
		_mirror=$(sed -n '1p' "$STOCK_DIR/installurl")
		case $_mirror in
			http://* | https://*) ;;
			*) die "the package mirror of the media node is not an http(s) URL: $STOCK_DIR/installurl" ;;
		esac
		case ${_mirror#*://} in
			'' | *[!A-Za-z0-9._~:/%+-]*) die "the package mirror of the media node is not a plain URL: $STOCK_DIR/installurl" ;;
		esac
		_mirror=${_mirror%/}
	fi
	_pkgpath="$_mirror/$RELEASE/packages/$ARCH/"
	log "live: packages from $_pkgpath"
	_cache="/usr/local/share/$_slug/packages"
	mkdir -p "$LV_ROOT$_cache"
	if [ -n "$PKGS" ]; then
		log "live: pkg_add $PKGS"
		# shellcheck disable=SC2086
		in_root env PKG_PATH="$_pkgpath" PKG_CACHE="$_cache/" pkg_add -I $PKGS > "$WORK/pkg_add.log" 2>&1 \
			|| { tail -n 20 "$WORK/pkg_add.log" >&2; die "pkg_add(1): the packages of the site set could not be installed: $PKGS"; }
		# pkg_add(1) reports a package it cannot find and goes on
		! grep -q "^Can't find \|^Can't install " "$WORK/pkg_add.log" \
			|| { tail -n 20 "$WORK/pkg_add.log" >&2; die "pkg_add(1): the packages of the site set could not be installed: $PKGS"; }
		_cached=0
		for _c in "$LV_ROOT$_cache"/*.tgz; do
			[ -f "$_c" ] && _cached=1
		done
		[ "$_cached" -eq 1 ] \
			|| { tail -n 20 "$WORK/pkg_add.log" >&2; die "pkg_add(1) left no package in the cache $_cache"; }
	fi
	if [ -n "$LIVEPKGS" ]; then
		log "live: pkg_add $LIVEPKGS (live only)"
		# shellcheck disable=SC2086
		in_root env PKG_PATH="$_pkgpath" pkg_add -I $LIVEPKGS > "$WORK/pkg_add-live.log" 2>&1 \
			|| { tail -n 20 "$WORK/pkg_add-live.log" >&2; die "pkg_add(1): the packages of the live set could not be installed: $LIVEPKGS"; }
		! grep -q "^Can't find \|^Can't install " "$WORK/pkg_add-live.log" \
			|| { tail -n 20 "$WORK/pkg_add-live.log" >&2; die "pkg_add(1): the packages of the live set could not be installed: $LIVEPKGS"; }
	fi
	# The firmware of every driver (Wi-Fi, GPU, ...): downloaded once into
	# the live image, where the install command takes what the machine
	# needs with fw_update -p (no network), and installed on the live
	# system itself, so it drives the same hardware. fw_update(8) checks
	# the signatures (SHA256.sig of the firmware directory).
	_fw="/usr/local/share/$_slug/firmware"
	if [ -e "$STOCK_DIR/installurl" ]; then
		_fwsrc="$_mirror/firmware/$RELEASE/"
	else
		_fwsrc="https://firmware.openbsd.org/firmware/$RELEASE/"
	fi
	mkdir -p "$LV_ROOT$_fw"
	log "live: firmware from $_fwsrc"
	# fw_update -F downloads from the default location only (it refuses
	# -F with -p). The digests of the list are base64. The signed list and the files it names are fetched here
	# with ftp(1) into the work directory, checked with signify(1) and the
	# firmware key of the new root (base set), then copied into the image.
	_fwd="$WORK/firmware"
	mkdir -m 0700 "$_fwd"
	( cd "$_fwd" && ftp -V -o SHA256.sig "${_fwsrc}SHA256.sig" ) > "$WORK/fw_update.log" 2>&1 \
		|| { tail -n 20 "$WORK/fw_update.log" >&2; die "cannot download ${_fwsrc}SHA256.sig"; }
	for _f in $(sed -n 's/^SHA256 (\([A-Za-z0-9._+-]*\.tgz\)) = [A-Za-z0-9+/=]*$/\1/p' "$_fwd/SHA256.sig"); do
		( cd "$_fwd" && ftp -V -o "$_f" "$_fwsrc$_f" ) >> "$WORK/fw_update.log" 2>&1 \
			|| { tail -n 20 "$WORK/fw_update.log" >&2; die "cannot download the firmware $_f"; }
	done
	( cd "$_fwd" && signify -C -p "$LV_ROOT/etc/signify/openbsd-$NN-fw.pub" -x SHA256.sig ) >> "$WORK/fw_update.log" 2>&1 \
		|| { tail -n 20 "$WORK/fw_update.log" >&2; die 'signify(1): the firmware does not match its signed list'; }
	cp "$_fwd"/* "$LV_ROOT$_fw/" || die 'cannot copy the firmware into the image'
	[ -f "$LV_ROOT$_fw/SHA256.sig" ] \
		|| { tail -n 20 "$WORK/fw_update.log" >&2; die 'fw_update(8) left no SHA256.sig in the firmware directory'; }
	# fw_update reads the boot messages even with -a, and takes the release
	# (the name of the signify key) from their first line: a file with that
	# line stands in for them in the new root, and goes again afterwards
	mkdir -p "$LV_ROOT/var/run"
	printf 'OpenBSD %s (GENERIC.MP) #0\n' "$RELEASE" > "$LV_ROOT/var/run/dmesg.boot"
	in_root fw_update -a -p "$_fw" >> "$WORK/fw_update.log" 2>&1 \
		|| { tail -n 20 "$WORK/fw_update.log" >&2; die 'fw_update(8) cannot install the firmware on the live system'; }
	rm -f "$LV_ROOT/etc/resolv.conf" "$LV_ROOT/var/run/ld.so.hints" "$LV_ROOT/var/run/dmesg.boot"

	# The live user: the first free uid from LIVE_UID_MIN up, no
	# password (the live system is a live system: the account exists on
	# the live image only, and the installed system never has it).
	_uid=$LIVE_UID_MIN
	while u="$_uid" awk -F: 'BEGIN { u = ENVIRON["u"] } $3 == u { f = 1 } END { exit !f }' "$LV_ROOT/etc/passwd" \
		|| u="$_uid" awk -F: 'BEGIN { u = ENVIRON["u"] } $3 == u { f = 1 } END { exit !f }' "$LV_ROOT/etc/group"; do
		_uid=$((_uid + 1))
	done
	in_root groupadd -g "$_uid" live || die 'groupadd(8): cannot create the group live'
	in_root useradd -m -u "$_uid" -g live -c 'Live user' -s /bin/ksh -p '' live \
		|| die 'useradd(8): cannot create the live user'
	log "live: the live user has the uid $_uid"

	# The sets the live system installs from: the signed sets of the
	# release, the kernels, the signed SHA256 list and the site set.
	_sets="/usr/local/share/$_slug/sets/$RELEASE/$ARCH"
	mkdir -p "$LV_ROOT$_sets"
	for _s in $SETS; do
		cp "$SETDIR/$_s$NN.tgz" "$LV_ROOT$_sets/" || die "cannot copy $_s$NN.tgz"
	done
	for _k in bsd bsd.mp bsd.rd; do
		cp "$SETDIR/$_k" "$LV_ROOT$_sets/" || die "cannot copy $_k"
	done
	cp "$STOCK_SUMS" "$LV_ROOT$_sets/SHA256.sig" || die 'cannot copy the SHA256 file of the release'
	cp "$INDIR/site.tgz" "$LV_ROOT$_sets/$SITENAME" || die 'cannot copy the site set'
	chmod 0444 "$LV_ROOT$_sets"/*

	# Nothing of the job ran in the new root. Now the two sets are
	# unpacked over it, the site set first, then the live set; no command
	# of the new root runs after this point.
	no_link_on_path "$LV_ROOT" "$WORK/site.list"
	tar -xzpf "$INDIR/site.tgz" -C "$LV_ROOT" || die 'cannot unpack the site set into the new root'
	no_link_on_path "$LV_ROOT" "$WORK/live.list"
	tar -xzpf "$INDIR/live.tgz" -C "$LV_ROOT" || die 'cannot unpack the live set into the new root'
	# The base system of the identity is what the image holds: the version
	# string of its kernel (OpenBSD <release> (GENERIC...)). It must agree
	# with the BASE the site set was built for, and with the release of
	# this helper; the line on the greeter and the wallpaper say the same.
	_kv=$(LC_ALL=C grep -a -o 'OpenBSD [0-9][0-9.]*[A-Za-z0-9-]* (GENERIC[A-Za-z0-9.]*)' "$LV_ROOT/bsd" 2> /dev/null | head -n 1)
	[ -n "$_kv" ] || die 'the kernel of the image (/bsd) holds no version string "OpenBSD <release> (GENERIC...)"'
	_kr=${_kv#OpenBSD }
	_kr=${_kr%% *}
	case $_kr in
		"$RELEASE" | "$RELEASE"-*) ;;
		*) die "the kernel of the image is OpenBSD $_kr, not the release $RELEASE" ;;
	esac
	_id="$LV_ROOT/usr/local/share/$_slug/identity"
	[ -f "$_id" ] || die "the site set holds no usr/local/share/$_slug/identity"
	_ib=$(sed -n 's/^BASE=//p' "$_id")
	[ "$_ib" = "OpenBSD $_kr" ] \
		|| die "the identity of the site set says BASE=${_ib:-<none>}, the kernel of the image is OpenBSD $_kr"
	log "live: base system OpenBSD $_kr (the kernel: $_kv)"
	# the stock installer runs /install.site and leaves it; the live
	# image never runs it, so it is not left behind
	rm -f "$LV_ROOT/install.site"
	chown -R "$_uid:$_uid" "$LV_ROOT/home/live"

	# The boot loader, from the new root's /usr/mdec (base set).
	installboot -r "$LV_ROOT" "$LV_VND" > /dev/null || die "installboot(8): cannot install the boot loader on $LV_VND"
	sync
	df -h "$LV_ROOT" >&2 || true
	if ! umount "$LV_ROOT"; then
		die 'umount(8): cannot unmount the live image'
	fi
	LV_MOUNTS=''
	if ! vnconfig -u "$LV_VND"; then
		die "vnconfig(8): cannot detach $LV_VND"
	fi
	LV_PATH=''
	LV_VND=''
	if ! umount "$MNT"; then
		die 'umount(8): cannot unmount the image'
	fi
	CD_MOUNTED=''
	if ! vnconfig -u "$CD_VND"; then
		die "vnconfig(8): cannot detach $CD_VND"
	fi
	CD_PATH=''
	CD_VND=''

	# The image goes to stdout, only after every step succeeded.
	log "live: the image is $LIVE_MB MB"
	cat "$LV_IMG"
}

# The verb comes first, then the release and the architecture.
#   prepare  the install CD: stdin holds site.tgz and install.conf
#   live     the live disk image: stdin holds site.tgz and live.tgz
case ${1:-} in
	prepare)
		VERB=prepare
		MEMBERS='site.tgz install.conf'
		MEMBERS_TXT='site.tgz and install.conf'
		WORK_TMP=/tmp
		WORK_NAME=wtfbsd-media
		shift
		;;
	live)
		VERB=live
		MEMBERS='site.tgz live.tgz'
		MEMBERS_TXT='site.tgz and live.tgz'
		WORK_TMP=$LIVE_TMP
		WORK_NAME=wtfbsd-live
		shift
		;;
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

if [ "$VERB" = prepare ]; then
	[ "$(uname -s)" = OpenBSD ] \
		|| die "this helper runs on OpenBSD (uname -s says $(uname -s)): the ramdisk of bsd.rd is changed with rdsetroot(8)"
	_tools='tar vnconfig mount umount rdsetroot mkhybrid gzip sha256 stat dd od find mktemp'
else
	[ "$(uname -s)" = OpenBSD ] \
		|| die "this helper runs on OpenBSD (uname -s says $(uname -s)): the live image is partitioned with fdisk(8) and disklabel(8)"
	_tools='tar vnconfig mount umount fdisk disklabel newfs installboot chroot ftp signify gzip sha256 stat dd od find mktemp'
fi
[ "$(id -u)" = 0 ] || die 'mounting the media needs root'
for _t in $_tools; do
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
_want=$(n="($ISONAME)" awk 'BEGIN { n = ENVIRON["n"] }
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
if [ "$VERB" = live ]; then
	if [ ! -e "$WORK_TMP" ] && [ ! -L "$WORK_TMP" ]; then
		mkdir -m 0700 "$WORK_TMP" || die "cannot create the work directory of the live verb: $WORK_TMP"
	fi
	root_owned "$WORK_TMP" 'the work directory of the live verb' dir
fi
WORK=$(mktemp -d "$WORK_TMP/$WORK_NAME.XXXXXX") || die 'cannot create the work directory'
case $WORK in
	"$WORK_TMP/$WORK_NAME".??????) ;;
	*) die "the work directory does not have the shape $WORK_TMP/$WORK_NAME.XXXXXX: $WORK" ;;
esac
case ${WORK#"$WORK_TMP/$WORK_NAME".} in
	*[!A-Za-z0-9]*) die "the work directory does not have the shape $WORK_TMP/$WORK_NAME.XXXXXX: $WORK" ;;
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
LV_PATH=''
LV_VND=''
LV_MOUNTS=''
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
	# the live verb: the file systems of the image, innermost first,
	# then its device
	if [ -n "${LV_MOUNTS:-}" ]; then
		for _m in $LV_MOUNTS; do
			umount "$_m" 2> /dev/null || true
		done
		_still=''
		for _m in $LV_MOUNTS; do
			if mount | m="$_m" awk 'BEGIN { m = ENVIRON["m"] } $3 == m { f = 1 } END { exit !f }'; then
				_still="$_still $_m"
			fi
		done
		LV_MOUNTS=${_still# }
	fi
	if [ -n "${LV_PATH:-}" ] && [ -z "${LV_MOUNTS:-}" ]; then
		detach_for "${LV_VND:-}" "$LV_PATH" && LV_PATH='' && LV_VND=''
	fi
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
	if [ -n "${LV_MOUNTS:-}" ]; then
		printf '%s: %s is still mounted\n' "$PROG" "$LV_MOUNTS" >&2
		_cleanup_failed=1
	fi
	if [ -n "${LV_PATH:-}" ]; then
		printf '%s: the device of %s is still attached\n' "$PROG" "$LV_PATH" >&2
		_cleanup_failed=1
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
	if [ -z "${CD_MOUNTED:-}${RD_MOUNTED:-}${LV_MOUNTS:-}" ]; then
		rmrf "$WORK" "$WORK_TMP" 2> /dev/null || true
	fi
	return 0
}
# shellcheck disable=SC2154 # rc is assigned first in the same trap string
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
if [ "$VERB" = live ]; then
	check_input_file "$INDIR/live.tgz" "$LIVE_MAX"
	build_live
	exit 0
fi
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
