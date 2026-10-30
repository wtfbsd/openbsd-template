#!/bin/sh
#
# build.sh — build the ExampleBSD site set (siteNN.tgz) for unmodified OpenBSD.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# OVERLAY RULE: the OpenBSD base system is never patched. The overlay is
# turned into a site set (install.site(5)):
#
#   siteNN.tgz    gzip(1) compressed tar(1) archive rooted in /; the
#                 installer unpacks it over the new root and runs the
#                 executable /install.site inside it at the end of the
#                 install, in a chroot(8) based at the new root.
#   install.conf  autoinstall(8) response file ("question = answer" lines).
#   SHA256        checksums of the files above.
#
# NN is the release without the dot: 7.8 -> site78.tgz (install.site(5)).
# The site set is named exactly like that because the installer looks for
# site${VERSION}.tgz next to the sets; a host specific set would be
# site${VERSION}-$(hostname -s).tgz.
#
# The base system itself is built with release(8), and only on OpenBSD:
# OpenBSD has no cross build. See WTFBSD_BUILD_BASE below.
#
# product.conf is flat KEY=value output (parsed, never sourced) of
# wtfbsd/agents scripts/apply-answers.sh; the key list lives in
# wtfbsd/agents questions.yaml.
#
# Usage:
#   ./build.sh -c product.conf [-r 7.8] [-o ./out] [-p desktop|appliance|both]
#               [-u USER -k PUBKEYFILE] [-n]
#
# Environment knobs:
#   WTFBSD_BUILD_BASE=yes  also build the base system with release(8).
#                          OpenBSD hosts only (no cross build).
#   WTFBSD_SRC             unmodified OpenBSD source tree (default /usr/src).

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG -c product.conf [-r 7.8] [-o ./out]"
	log '       [-p desktop|appliance|both] [-u USER -k PUBKEYFILE] [-P HASHFILE] [-n]'
	log ''
	log '  -c  product.conf from wtfbsd/agents scripts/apply-answers.sh'
	log '  -r  OpenBSD release the site set is built for (N.N, default 7.8);'
	log '      7.8 produces site78.tgz (install.site(5))'
	log '  -o  output directory (default: ./out)'
	log '  -p  profile: desktop, appliance or both (default: product.conf PROFILE)'
	log '  -u  name of the operator account the installer creates; required'
	log '  -k  file with the SSH public key of that account; required. The'
	log '      site set is key-only: without an account and a key nobody'
	log '      could log in, so a build without them is refused.'
	log '  -P  file with the bcrypt hash of the password of that account.'
	log '      Required by the desktop profile: sshd is disabled there, so'
	log '      the console is the only way in. Optional for the appliance,'
	log '      whose response file holds 13 asterisks when it is absent.'
	log '      The hash is read from the file, never from the command line,'
	log '      and it is never printed.'
	log '  -n  dry run: validate the config, print the plan, change nothing'
	exit "${1:-2}"
}

DRY=0
CONF=''
RELEASE=7.8
OUT=./out
CHOSEN=''
CIUSER=''
CIKEY=''
PASSHASHFILE=''

while getopts 'c:r:o:p:u:k:P:nh' _opt; do
	case $_opt in
	c) CONF=$OPTARG ;;
	r) RELEASE=$OPTARG ;;
	o) OUT=$OPTARG ;;
	p) CHOSEN=$OPTARG ;;
	u) CIUSER=$OPTARG ;;
	k) CIKEY=$OPTARG ;;
	P) PASSHASHFILE=$OPTARG ;;
	n) DRY=1 ;;
	h) usage 0 ;;
	*) usage 2 >&2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage 2
[ -n "$CONF" ] || { log "$PROG: missing -c product.conf" >&2; usage 2 >&2; }
case $OUT in *[[:space:]]*) die "-o: output path may not contain whitespace: $OUT" ;; esac
[ -f "$CONF" ] || die "no such product.conf: $CONF"

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# --------------------------------------------------------------------------
# load + validate product.conf (flat KEY=value from apply-answers.sh)
# --------------------------------------------------------------------------

# product.conf is NEVER sourced: it is parsed line by line, only the known
# questions.yaml keys are accepted, and values may not contain shell
# metacharacters. One pair of outer quotes is stripped: apply-answers.sh
# writes KEY='value' (a ' inside a value is written as '\''), the template
# fixtures use KEY="value".
KNOWN_KEYS='DISTRO_OS DISTRO_NAME DISTRO_SLUG DISTRO_ARCH FILESYSTEM_ROOT
ZFS_DATA_POOL ZFS_POOL_NAME PROFILE PACKAGE_SET INSTALLER MOTD BRAND_COLOR
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG'
for _k in $KNOWN_KEYS; do unset "$_k"; done
while IFS= read -r _line || [ -n "$_line" ]; do
	case $_line in '' | '#'*) continue ;; esac
	case $_line in
	[A-Z]*=*) ;;
	*) die "product.conf: not a KEY=value line: $_line" ;;
	esac
	_k=${_line%%=*}
	_v=${_line#*=}
	case " $(printf %s "$KNOWN_KEYS" | tr '\n' ' ') " in
	*" $_k "*) ;;
	*) die "product.conf: unknown key: $_k (known: $(printf %s "$KNOWN_KEYS" | tr '\n' ' '); see wtfbsd/agents questions.yaml)" ;;
	esac
	case $_v in
	\'*\')
		_v=${_v#\'}
		_v=${_v%\'}
		_v=$(printf '%s' "$_v" | sed "s/'\\\\''/'/g")
		;;
	\"*\")
		_v=${_v#\"}
		_v=${_v%\"}
		;;
	esac
	case $_v in
	*[\$\`\\\"]* | *[[:cntrl:]]*) die "product.conf: $_k contains a forbidden character (\$, backquote, backslash, double quote or control character)" ;;
	esac
	# plain assignments, no eval: the value is pure data
	case $_k in
	DISTRO_OS) DISTRO_OS=$_v ;;
	DISTRO_NAME) DISTRO_NAME=$_v ;;
	DISTRO_SLUG) DISTRO_SLUG=$_v ;;
	DISTRO_ARCH) DISTRO_ARCH=$_v ;;
	FILESYSTEM_ROOT) FILESYSTEM_ROOT=$_v ;;
	ZFS_DATA_POOL) ZFS_DATA_POOL=$_v ;;
	ZFS_POOL_NAME) ZFS_POOL_NAME=$_v ;;
	PROFILE) PROFILE=$_v ;;
	PACKAGE_SET) PACKAGE_SET=$_v ;;
	INSTALLER) INSTALLER=$_v ;;
	MOTD) MOTD=$_v ;;
	BRAND_COLOR) BRAND_COLOR=$_v ;;
	BRAND_URL) BRAND_URL=$_v ;;
	CI_ENABLED) CI_ENABLED=$_v ;;
	PUBLISH_METHOD) PUBLISH_METHOD=$_v ;;
	PUBLISH_TARGET) PUBLISH_TARGET=$_v ;;
	PUBLISHER_ORG) PUBLISHER_ORG=$_v ;;
	esac
done < "$CONF"

[ "${DISTRO_OS:-}" = openbsd ] \
	|| die "DISTRO_OS must be openbsd (got ${DISTRO_OS:-<empty>}); this template builds OpenBSD only"

# The no-ZFS rule. OpenBSD has no ZFS at all: FFS is the only filesystem
# choice (wtfbsd/agents questions.yaml, per_os row openbsd).
case ${FILESYSTEM_ROOT:-ffs} in
ffs) FILESYSTEM_ROOT=ffs ;;
zfs) die "FILESYSTEM_ROOT=zfs: No ZFS at all. FFS is the only filesystem choice." ;;
*) die "FILESYSTEM_ROOT must be ffs for openbsd (got: ${FILESYSTEM_ROOT:-<empty>})" ;;
esac
case ${ZFS_DATA_POOL:-no} in
no) ZFS_DATA_POOL=no ;;
yes) die "ZFS_DATA_POOL=yes: No ZFS at all. FFS is the only filesystem choice." ;;
*) die "ZFS_DATA_POOL must be yes or no (got: ${ZFS_DATA_POOL:-<empty>})" ;;
esac

# anchored checks without interval expressions (portable ERE)
# The value is ONE line: a pattern that is matched line by line (grep)
# would accept the first line of a value that holds a newline, so a value
# with a newline is refused before the pattern is tried.
chk() { # chk <anchored-ere> <value> <message>
	v=$2
	case $v in
	*'
'*) die "$3 (the value holds a newline)" ;;
	esac
	[ "${#v}" -le 4096 ] || die "$3 (the value is too long: ${#v} characters)"
	printf '%s\n' "$v" | grep -qE -- "$1" || die "$3 (got: $v)"
}

# slug: lowercase/digits/hyphens, starts with a letter, 2..32 chars
chk '^[a-z][a-z0-9-]*$' "${DISTRO_SLUG:-}" 'DISTRO_SLUG must match ^[a-z][a-z0-9-]*$'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -ge 2 ] || die 'DISTRO_SLUG too short (min 2)'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -le 32 ] || die 'DISTRO_SLUG too long (max 32)'

case ${DISTRO_NAME:-} in *[[:cntrl:]]*) die 'DISTRO_NAME contains control characters' ;; esac
[ -n "${DISTRO_NAME:-}" ] || die 'DISTRO_NAME is empty'
[ "$(printf %s "$DISTRO_NAME" | wc -c)" -le 64 ] || die 'DISTRO_NAME too long (max 64)'

# The release the site set is built for: N.N. install.site(5) names the
# set after the release without the dot: 7.8 -> site78.tgz.
chk '^[0-9]+\.[0-9]+$' "$RELEASE" "release must be N.N, e.g. 7.8 (got: $RELEASE)"
SITENUM=$(printf '%s' "$RELEASE" | tr -d '.')

chk '^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$' \
	"${BRAND_COLOR:-3b6ea5}" 'BRAND_COLOR must be six hex digits'
BRAND_URL=${BRAND_URL:-https://example.org}
chk '^https://[A-Za-z0-9.-]+$' "$BRAND_URL" 'BRAND_URL must be https, hostname only'

PROF=${CHOSEN:-${PROFILE:-appliance}}
case $PROF in
desktop | appliance | both) ;;
*) die "-p must be desktop, appliance or both (got: $PROF)" ;;
esac

# --------------------------------------------------------------------------
# the login path: the operator account and its public key
# --------------------------------------------------------------------------

# The site set is key-only: the appliance sshd refuses password logins
# (sshd_config) and the root password is locked. The operator account and
# its public key are therefore REQUIRED inputs of the build: without them
# the installed system has no way in, and a boot test that only looks for
# "login:" and for a port 22 would not notice.
#
# The name of the account is a user name: a lowercase name that starts with
# a letter or an underscore, at most 32 characters.
USER_RE='^[a-z_][a-z0-9_-]{0,31}$'

# The security key types carry the domain of OpenSSH. That domain has the
# shape of a mail address, so it is kept in a variable: this file must not
# hold the shape of a mail address.
SKDOMAIN=openssh.com

# keyprefix <line> — the key types an authorized_keys file (and the
# installer) accepts. The same list as the FreeBSD template. The first
# field of the line is matched exactly: a type that is only the beginning
# of a supported type (ssh-ed25519x, say) is not a key type.
keyprefix() {
	_kpt=$(printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//')
	case $_kpt in
	ssh-ed25519 | ssh-rsa | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521) return 0 ;;
	"sk-ssh-ed25519@$SKDOMAIN" | "sk-ecdsa-sha2-nistp256@$SKDOMAIN") return 0 ;;
	*) return 1 ;;
	esac
}

LOGIN_USER=''
LOGIN_KEY=''
if [ -n "$CIUSER" ] || [ -n "$CIKEY" ]; then
	[ -n "$CIUSER" ] && [ -n "$CIKEY" ] \
		|| die 'build.sh: -u USER and -k PUBKEYFILE must be given together'
	case $CIUSER in
	*[[:cntrl:]]*) die 'build.sh: -u: the operator account name holds a control character' ;;
	esac
	chk "$USER_RE" "$CIUSER" 'build.sh: -u: the operator account name must match ^[a-z_][a-z0-9_-]{0,31}$'
	[ -f "$CIKEY" ] || die "build.sh: no such public key file: $CIKEY"
	_nkeys=0
	while IFS= read -r _kl || [ -n "$_kl" ]; do
		case $_kl in
		'' | '#'*) continue ;;
		esac
		case $_kl in
		*[[:cntrl:]]*) die "build.sh: $CIKEY: the key line holds a control character" ;;
		esac
		keyprefix "$_kl" \
			|| die "build.sh: $CIKEY: the type of the key is not one of the supported ssh public key types"
		# The key material is the second field of the line (the type,
		# the key and an optional comment). Only the type and the key
		# are kept: the comment is free text and the installer writes
		# the line into the authorized_keys of the account.
		# A refusal never quotes the line: the line holds the key
		# material, and a key that is written into a log is a key that
		# is kept. The refusal names the check and the file.
		_kf=$(printf '%s\n' "$_kl" | sed -e 's/^[^[:space:]]*[[:space:]]*//' -e 's/[[:space:]].*$//')
		_kt=$(printf '%s\n' "$_kl" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//')
		case $_kf in
		'') die "build.sh: $CIKEY: the key line holds no key material" ;;
		*[!A-Za-z0-9+/=]*) die "build.sh: $CIKEY: the material of the key is not a valid ssh public key" ;;
		esac
		_nkeys=$((_nkeys + 1))
		LOGIN_KEY="$_kt $_kf"
	done < "$CIKEY"
	[ "$_nkeys" -gt 0 ] || die "build.sh: no ssh public key line in $CIKEY"
	[ "$_nkeys" -eq 1 ] \
		|| die "build.sh: $CIKEY holds $_nkeys keys: the installer takes one key for the operator account"
	LOGIN_USER=$CIUSER
fi

# --------------------------------------------------------------------------
# the password of the operator account
# --------------------------------------------------------------------------

# The hash is read from a file and never from the command line: an
# argument of a command is in the list of processes of every user of the
# machine, and a hash that is printed is a hash that is kept. The hash
# is never printed, not even in the message of a refusal.
#
# A bcrypt hash: the marker $2a$, $2b$ or $2y$, the cost, and 53
# characters of the alphabet of bcrypt.
PASSHASH=''
# 13 asterisks disable the password logins and leave only key based
# access (autoinstall(8)). The appliance holds them when no hash was
# given: the installer must not stop on the question.
PWSTARS='*************'
if [ -n "$PASSHASHFILE" ]; then
	[ -f "$PASSHASHFILE" ] || die "no such password hash file: $PASSHASHFILE"
	_nh=0
	while IFS= read -r _hl || [ -n "$_hl" ]; do
		case $_hl in
		'' | '#'*) continue ;;
		esac
		_nh=$((_nh + 1))
		PASSHASH=$(printf '%s' "$_hl" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	done < "$PASSHASHFILE"
	[ "$_nh" -eq 1 ] \
		|| die "$PASSHASHFILE holds $_nh hashes: the file must hold exactly one"
	# The refusal names the shape of the hash and never the hash: a
	# hash that is written into a log is a hash that is kept.
	printf '%s\n' "$PASSHASH" \
		| grep -qE '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' \
		|| die 'the password hash is not a bcrypt hash ($2a$, $2b$ or $2y$, the cost, and 53 characters of the alphabet of bcrypt)'
fi

# informational defaults mirroring questions.yaml (used downstream)
PACKAGE_SET=${PACKAGE_SET:-minimal}
INSTALLER=${INSTALLER:-tui}
MOTD=${MOTD:-built from the wtfbsd templates}
case $MOTD in *[[:cntrl:]]*) die 'MOTD contains control characters' ;; esac
[ "$(printf %s "$MOTD" | wc -c)" -le 120 ] || die 'MOTD too long (max 120)'

: "${DISTRO_ARCH:=amd64}" # questions.yaml per_os default
case $DISTRO_ARCH in
amd64 | aarch64) ;;
*) die "DISTRO_ARCH must be amd64 or aarch64 (got: ${DISTRO_ARCH:-<empty>})" ;;
esac

# The base system is built with release(8), which only runs on OpenBSD.
BUILD_BASE=${WTFBSD_BUILD_BASE:-no}
case $BUILD_BASE in
yes | no) ;;
*) die "WTFBSD_BUILD_BASE must be yes or no (got: $BUILD_BASE)" ;;
esac
SRC=${WTFBSD_SRC:-/usr/src}

# --------------------------------------------------------------------------
# static checks
# --------------------------------------------------------------------------

# The mt76 rule: the wireless driver is never enabled, loaded or configured
# by this template; an overlay file may not mention it at all.
[ -d "$ROOT/overlay" ] || die "mt76 guard: missing $ROOT/overlay"
_rc=0
grep -rna 'mt76' "$ROOT/overlay" || _rc=$?
case $_rc in
1) ;; # no match: good
0) die 'mt76 guard: an overlay file references the mt76 wireless driver; it must never be enabled or loaded by this template' ;;
*) die "mt76 guard: could not scan $ROOT/overlay (grep exit $_rc)" ;;
esac

[ -f "$ROOT/overlay/base/rootfs/install.site" ] || die "missing $ROOT/overlay/base/rootfs/install.site"
[ -f "$ROOT/autoinstall/install.conf.template" ] || die "missing $ROOT/autoinstall/install.conf.template"

if [ "$DRY" -ne 1 ]; then
	for t in tar sed grep find cp awk; do
		command -v "$t" > /dev/null 2>&1 || die "required tool missing: $t"
	done
	command -v sha256sum > /dev/null 2>&1 || command -v sha256 > /dev/null 2>&1 \
		|| die 'no sha256 tool found (need sha256sum or sha256)'
fi

if [ "$BUILD_BASE" = yes ]; then
	[ "$(uname -s)" = OpenBSD ] \
		|| die "building the base system needs OpenBSD: release(8) cannot be cross-built (this host is $(uname -s)). Build the site set only, or run the build on OpenBSD."
	[ -d "$SRC" ] || die "no such source tree: $SRC (set WTFBSD_SRC to an unmodified OpenBSD source tree)"
fi

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

step() { # step <cmd...> — execute, or print in a dry run
	if [ "$DRY" -eq 1 ]; then printf '    + %s\n' "$*"; else "$@"; fi
}

rmrf() { # rmrf <path> <guardroot> — rm -rf only for non-empty paths under root
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

pkg_list() { # pkg_list file... — flatten lists to shell words (missing files are skipped)
	_files=''
	for _f in "$@"; do
		[ -f "$_f" ] || continue
		_files="$_files $_f"
	done
	[ -n "$_files" ] || return 0
	# shellcheck disable=SC2086
	sed -e 's/[[:space:]]*#.*$//' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' $_files | grep -v '^$' | tr '\n' ' '
}

sed_esc() { # escape a value for use inside a sed replacement
	printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'
}

conf_for_profile() { # conf_for_profile <template> <profile> — the answers of that profile
	# A block of the template that belongs to another profile is dropped:
	#   #@profile desktop
	#   ... the answers of the desktop ...
	#   #@endprofile
	awk -v prof="$2" '
		/^#@profile / {
			inblock = 1
			keep = 0
			for (i = 2; i <= NF; i++) if ($i == prof) keep = 1
			next
		}
		/^#@endprofile/ { inblock = 0; keep = 0; next }
		inblock && !keep { next }
		{ print }
	' "$1"
}

copy_tree() { # copy_tree <src> <dst> [skip-relpath] — copy the files of a tree
	[ -d "$1" ] || return 0
	case $1 in
	/*) _src=$1 ;;
	*) _src="$PWD/$1" ;;
	esac
	case $2 in
	/*) _dst=$2 ;;
	*) _dst="$PWD/$2" ;;
	esac
	( cd "$_src" && find . -type f | while IFS= read -r _f; do
		if [ -n "${3:-}" ] && [ "$_f" = "./$3" ]; then continue; fi
		mkdir -p "$_dst/$(dirname -- "$_f")"
		cp "$_src/$_f" "$_dst/$_f"
	done )
}

tar_flavour() { # gnu | bsd | openbsd — how to spell "tar" on this host
	if tar --version 2>/dev/null | grep -q 'GNU tar'; then
		printf 'gnu\n'
	elif [ "$(uname -s)" = OpenBSD ]; then
		printf 'openbsd\n'
	else
		printf 'bsd\n'
	fi
}

tar_site() { # tar_site <archive> <dir> <list> — the site set is rooted in /
	# The archive holds a FILE LIST only. It has no entry for "./" and
	# none for a directory: the installer unpacks the archive over the
	# new root, and a directory entry would hand the mode and the owner
	# of the staged directory to /etc, /usr and the rest of that root.
	case $(tar_flavour) in
	gnu)
		tar -czf "$1" -C "$2" --owner=0 --group=0 --numeric-owner --mtime=@0 -T "$3"
		;;
	bsd)
		tar -czf "$1" -C "$2" --uid 0 --gid 0 --uname root --gname root -T "$3"
		;;
	openbsd)
		# OpenBSD ships the pax tar(1); it has no owner override, so
		# the staged tree is owned by root (the build refuses to run
		# as another user). The tar(1) of OpenBSD reads the list of
		# the files with -I: -T is the GNU tar and the bsdtar.
		tar czf "$1" -C "$2" -I "$3"
		;;
	esac
}

stage_list() { # stage_list <dir> <listfile> — the names of the files, relative to the root
	( cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$2"
}

abspath() { # abspath <path> — the absolute form of a path (the file may not exist)
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s/%s\n' "$(pwd)" "$1" ;;
	esac
}

# The site set is unpacked over the new root by the installer: every
# member has to be owned by root. The tar(1) of OpenBSD has no owner
# override, so there the build has to run as root: the members would
# otherwise keep the uid of the builder.
if [ "$(tar_flavour)" = openbsd ] && [ "$(id -u)" != 0 ]; then
	if [ "$DRY" -ne 1 ]; then
		die 'the site set has to be owned by root: the tar(1) of OpenBSD has no owner override, so the build has to run as root'
	fi
	log 'note: on OpenBSD the build has to run as root: the tar(1) has no owner override'
fi

sha256_line() { # sha256_line <file> — "<hash>  <name>" on one line
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1"
	elif command -v sha256 > /dev/null 2>&1; then
		# sha256(1) -r prints the reverse (cksum style) format.
		sha256 -r "$1"
	else
		die 'no sha256 tool found (need sha256sum or sha256)'
	fi
}

SUBFILE=''
PWPROG=''
# The substitution programs hold the answers of the build: the public key
# of the operator account and the hash of its password. They are removed
# when the build ends, also when it fails.
cleanup_programs() {
	[ -n "$SUBFILE" ] && rm -f "$SUBFILE"
	[ -n "$PWPROG" ] && rm -f "$PWPROG"
	return 0
}
trap cleanup_programs EXIT
trap 'cleanup_programs; exit 130' INT
trap 'cleanup_programs; exit 143' TERM

mk_subst() { # write the sed program under $OUT; pick a delimiter absent from values
	SUBFILE="$OUT/.subst.sed"
	d=''
	for cand in '|' ',' ';' ':' '%'; do
		case "$DISTRO_NAME$MOTD$DISTRO_SLUG$BRAND_URL$LOGIN_USER$LOGIN_KEY" in *"$cand"*) ;; *) d=$cand; break ;; esac
	done
	[ -n "$d" ] || die 'DISTRO_NAME/MOTD/DISTRO_SLUG/BRAND_URL/USER/PUBKEY contain every candidate sed delimiter (| , ; : %); remove one of those characters in product.conf'
	{
		printf 's%s@DISTRO_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_NAME")" "$d"
		printf 's%s@MOTD@%s%s%sg\n' "$d" "$d" "$(sed_esc "$MOTD")" "$d"
		printf 's%s@SLUG@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_SLUG")" "$d"
		printf 's%s@BRAND_URL@%s%s%sg\n' "$d" "$d" "$(sed_esc "$BRAND_URL")" "$d"
		printf 's%s@USER@%s%s%sg\n' "$d" "$d" "$(sed_esc "$LOGIN_USER")" "$d"
		printf 's%s@PUBKEY@%s%s%sg\n' "$d" "$d" "$(sed_esc "$LOGIN_KEY")" "$d"
	} > "$SUBFILE"
}

subst_tree() { # subst_tree <dir> — substitute the placeholders in every file
	find "$1" -type f | while IFS= read -r _f; do
		sed -f "$SUBFILE" "$_f" > "$_f.new" && mv "$_f.new" "$_f"
	done
}

rename_slug() { # rename_slug <dir> — a staged path with @SLUG@ in it gets the slug
	find "$1" -name '*@SLUG@*' | while IFS= read -r _f; do
		_n=$(printf '%s' "$_f" | sed "s/@SLUG@/$DISTRO_SLUG/g")
		mkdir -p "$(dirname -- "$_n")"
		mv -- "$_f" "$_n"
	done
}

# The login path is not optional: a site set without an operator account
# and without a public key installs a system nobody can log in to.
if [ -z "$LOGIN_USER" ] && [ "$DRY" -ne 1 ]; then
	die 'the operator account and its public key are required: -u USER and -k PUBKEYFILE (the site set is key-only: without them nobody could log in)'
fi

# The password of the operator account is not optional on the desktop:
# sshd is disabled there (the fragment of the profile sets
# sshd_flags=NO), so the console is the only way in, and a console
# without a password is a console nobody can use.
case $PROF in
desktop | both) NEEDPASSWORD=yes ;;
*) NEEDPASSWORD=no ;;
esac
if [ "$NEEDPASSWORD" = yes ] && [ -z "$PASSHASH" ] && [ "$DRY" -ne 1 ]; then
	die 'the desktop profile needs the password of the operator account: -P HASHFILE (a bcrypt hash; the desktop has no sshd, so the console is the only way in)'
fi

# --------------------------------------------------------------------------
# plan header
# --------------------------------------------------------------------------

log ''
log 'plan:'
log "  distro   $DISTRO_NAME ($DISTRO_SLUG), openbsd/$DISTRO_ARCH"
log "  rootfs   $FILESYSTEM_ROOT (OpenBSD has no ZFS)"
log "  release  $RELEASE -> site$SITENUM.tgz"
log "  profile  $PROF (package set: $PACKAGE_SET, installer: $INSTALLER)"
log "  out      $OUT"
if [ -n "$LOGIN_USER" ]; then
	log "  login    $LOGIN_USER (public key from $CIKEY)"
else
	log '  login    MISSING: -u USER and -k PUBKEYFILE'
	log '           a dry run reports this; a real build refuses to run without it'
fi
if [ -n "$PASSHASH" ]; then
	# the path of the file, never the hash itself
	log "  password bcrypt hash (from $PASSHASHFILE)"
elif [ "$NEEDPASSWORD" = yes ]; then
	log '  password MISSING: -P HASHFILE'
	log '           the desktop profile needs it; a dry run reports this,'
	log '           a real build refuses to run without it'
else
	log '  password none: the appliance is key-only'
fi
log "  base     $([ "$BUILD_BASE" = yes ] && printf 'release(8) in %s (OpenBSD only)' "$SRC" || printf 'stock upstream OpenBSD (site set only)')"

# --------------------------------------------------------------------------
# per-profile pipeline
# --------------------------------------------------------------------------

# The site set holds: the base overlay, the profile overlay, the merged
# package list and the /install.site script.
build_profile() { # build_profile <profile> <outdir>
	_p=$1
	_od=$2
	_stage="$OUT/.stage/$_p"
	_tgz="$_od/site$SITENUM.tgz"

	log ''
	log "profile $_p:"

	if [ "$DRY" -eq 1 ]; then
		# print the file list the site set would hold
		( cd "$ROOT/overlay/base/rootfs" && find . -type f | sed 's|^\./||' ) \
			| sed 's|^etc/motd.template$|etc/motd|'
		if [ -d "$ROOT/overlay/profiles/$_p/rootfs" ]; then
			( cd "$ROOT/overlay/profiles/$_p/rootfs" && find . -type f | sed 's|^\./||' )
		fi
		log "    + write $_tgz"
		log "    + write $_od/install.conf"
		log "    + write $_od/install.conf.redacted"
		log "    + write $_od/SHA256"
		return 0
	fi

	mkdir -p "$_od"
	rmrf "$_stage" "$OUT/.stage"
	mkdir -p "$_stage"

	# --- stage the overlay ------------------------------------------------
	copy_tree "$ROOT/overlay/base/rootfs" "$_stage"
	if [ -d "$ROOT/overlay/profiles/$_p/rootfs" ]; then
		# OpenBSD has one rc.conf.local per root (rc.conf(8)); the
		# profile file is a FRAGMENT that is appended to the base file.
		if [ -f "$ROOT/overlay/profiles/$_p/rootfs/etc/rc.conf.local" ]; then
			copy_tree "$ROOT/overlay/profiles/$_p/rootfs" "$_stage" 'etc/rc.conf.local'
			printf '\n' >> "$_stage/etc/rc.conf.local"
			cat "$ROOT/overlay/profiles/$_p/rootfs/etc/rc.conf.local" >> "$_stage/etc/rc.conf.local"
		else
			copy_tree "$ROOT/overlay/profiles/$_p/rootfs" "$_stage"
		fi
	fi

	# OpenBSD has no rc.d/motd: the template becomes the live /etc/motd.
	if [ -f "$_stage/etc/motd.template" ]; then
		mv "$_stage/etc/motd.template" "$_stage/etc/motd"
	fi

	# the merged package list travels with the site set
	mkdir -p "$_stage/usr/local/share/@SLUG@"
	{
		printf '# packages.list — the packages /install.site installs with\n'
		printf '# pkg_add(1), once the installer has brought the network up.\n'
		printf '#\n'
		printf '# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).\n'
		printf '#\n'
		printf '# One package name per line; %s starts a comment.\n' "'#'"
		printf '\n'
		printf '# base\n'
		pkg_list "$ROOT/overlay/base/packages.list"
		printf '\n'
		printf '# profile: %s\n' "$_p"
		pkg_list "$ROOT/overlay/profiles/$_p/packages.list"
	} > "$_stage/usr/local/share/@SLUG@/packages.list"

	# --- substitute the placeholders --------------------------------------
	mk_subst
	subst_tree "$_stage"
	rename_slug "$_stage"

	# --- modes -------------------------------------------------------------
	find "$_stage" -type d -exec chmod 0755 {} +
	find "$_stage" -type f -exec chmod 0644 {} +
	chmod 0755 "$_stage/install.site"
	# the session of a new account is started by the X server: both files
	# have to be executable
	for _f in etc/skel/.xsession etc/skel/.xinitrc; do
		if [ -f "$_stage/$_f" ]; then
			chmod 0755 "$_stage/$_f"
		fi
	done
	# doas.conf(5) is read by root and by nobody else: the rules of
	# doas(1) are a list of the things an account may do.
	if [ -f "$_stage/etc/doas.conf" ]; then
		chmod 0600 "$_stage/etc/doas.conf"
	fi

	# --- owner 0:0 ---------------------------------------------------------
	# A build that is not root is refused on OpenBSD above, so there is
	# no branch here that could tell a builder that the members of the
	# archive keep their uid: that build never reaches this point.
	if [ "$(id -u)" = 0 ]; then
		chown -R 0:0 "$_stage"
	fi

	# --- deterministic mtime ------------------------------------------------
	TZ=UTC find "$_stage" -exec touch -t 197001010000 {} +

	# --- the site set ------------------------------------------------------
	# The archive holds the files only: a directory entry would hand the
	# owner and the mode of the staged directory to /etc, /usr and the
	# rest of the new root when the installer unpacks the archive.
	_list=$(abspath "$_stage.list")
	stage_list "$_stage" "$_list"
	tar_site "$_tgz" "$_stage" "$_list"
	rm -f "$_list"
	log "    + $_tgz"

	# --- the autoinstall response file -------------------------------------
	# autoinstall(8) reads "question = answer" lines; comment and blank
	# lines are stripped so the generated file holds answers only. The
	# blocks of the template that belong to another profile are dropped
	# first: the answers of the desktop are not answers of the appliance.
	#
	# The password of the operator account: the desktop holds the hash
	# (it is a required input there), the appliance holds the hash too
	# when there is one and the 13 asterisks otherwise, because its
	# sshd refuses the password logins and the installer must not stop
	# on the question.
	case $_p in
	desktop) _ph=$PASSHASH ;;
	*) _ph=${PASSHASH:-$PWSTARS} ;;
	esac
	# The program is a file of its own and the hash is never an
	# argument of a process: an argument is in the list of processes of
	# every user of the machine. The alphabet of bcrypt holds no '|',
	# so the delimiter of the program is safe.
	PWPROG="$OUT/.subst-pass.sed"
	printf 's%s@PASSHASH@%s%s%sg\n' '|' '|' "$(sed_esc "$_ph")" '|' > "$PWPROG"
	# The response file holds the hash of the password of the operator
	# account: it is a secret. It is written with a umask of 077, so
	# only the builder reads it.
	( umask 077
	  conf_for_profile "$ROOT/autoinstall/install.conf.template" "$_p" \
		| sed -e 's/[[:space:]]*#.*$//' \
			-e 's/^[[:space:]]*//' \
			-e 's/[[:space:]]*$//' \
		| grep -v '^$' \
		| sed -f "$SUBFILE" \
		| sed -f "$PWPROG" > "$_od/install.conf" )
	log "    + $_od/install.conf"

	# The redacted copy of the response file: the value of the password
	# of the operator account is replaced by <redacted>. It is the copy
	# the CI archives: a build artefact must not carry a secret.
	( umask 022
	  sed -e 's|^\(Password for user[[:space:]]*=[[:space:]]*\).*$|\1<redacted>|' \
		"$_od/install.conf" > "$_od/install.conf.redacted" )
	log "    + $_od/install.conf.redacted"

	# --- checksums ---------------------------------------------------------
	# The checksums are the ones of the artefacts that leave the build:
	# the site set and the redacted response file.
	( cd "$_od" && sha256_line "site$SITENUM.tgz" \
		&& sha256_line install.conf.redacted ) > "$_od/SHA256"
	log "    + $_od/SHA256"

	# the packages the site set installs
	_pkgs=$(pkg_list "$ROOT/overlay/base/packages.list" "$ROOT/overlay/profiles/$_p/packages.list")
	log "    packages: ${_pkgs:-<none>}"
}

case $PROF in
both)
	OUT_APPLIANCE="$OUT/appliance"
	OUT_DESKTOP="$OUT/desktop"
	;;
appliance) OUT_APPLIANCE="$OUT" ;;
desktop) OUT_DESKTOP="$OUT" ;;
esac

if [ "$BUILD_BASE" = yes ]; then
	log ''
	log 'base system (release(8), OpenBSD only):'
	step make -C "$SRC" release
	step make -C "$SRC" install
fi

case $PROF in
appliance | both)
	build_profile appliance "$OUT_APPLIANCE"
	;;
esac
case $PROF in
desktop | both)
	build_profile desktop "$OUT_DESKTOP"
	;;
esac

if [ "$DRY" -ne 1 ]; then
	rmrf "$OUT/.stage" "$OUT"
	rm -f "$OUT/.subst.sed" "$OUT/.subst-pass.sed"
fi

log ''
case $PROF in
both) log "done: both site sets for OpenBSD $RELEASE (site$SITENUM.tgz)" ;;
*) log "done: $PROF site set for OpenBSD $RELEASE (site$SITENUM.tgz)" ;;
esac
