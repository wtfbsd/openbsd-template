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
# NN is the release without the dot: 8.0 -> site80.tgz (install.site(5)).
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
#   ./build.sh -c product.conf [-r 8.0] [-o ./out] [-p desktop|appliance|both]
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
	log "usage: $PROG -c product.conf [-r 8.0] [-o ./out]"
	log '       [-p desktop|appliance|both] [-u USER -k PUBKEYFILE] [-P HASHFILE] [-n]'
	log ''
	log '  -c  product.conf from wtfbsd/agents scripts/apply-answers.sh'
	log '  -r  OpenBSD release the site set is built for (N.N, default 8.0);'
	log '      8.0 produces site80.tgz (install.site(5))'
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
RELEASE=8.0
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
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG
NET_IF NET_IPV4 NET_NETMASK NET_GATEWAY NET_DNS DOMAIN
INSTALLER_REF INSTALLER_URL INSTALLER_DIR
ARTWORK_REF ARTWORK_URL ARTWORK_DIR ARTWORK_VARIANT PRODUCT_VERSION
ARTWORK_PACK ARTWORK_PACK_SHA256 ARTWORK_RELEASES ARTWORK_SHA256'
for _k in $KNOWN_KEYS; do unset "$_k"; done
# The answers of the network are optional: they are empty when the
# product.conf does not hold them.
NET_IF=''
NET_IPV4=''
NET_NETMASK=''
NET_GATEWAY=''
NET_DNS=''
DOMAIN=''
# The installer-template of the live set (desktop): a local directory, or a
# git ref of a repository URL. Neither means the stand-in launcher of
# overlay/live (the text installer in a terminal).
INSTALLER_REF=''
INSTALLER_URL=''
INSTALLER_DIR=''
# The artwork template (the branding spots of OpenBSD) and its variant, and
# the version of the product in the identity line.
ARTWORK_REF=''
ARTWORK_URL=''
ARTWORK_DIR=''
ARTWORK_PACK=''
ARTWORK_PACK_SHA256=''
# the sha256 of the artwork pack of ARTWORK_REF (wtfbsd/agents product.conf):
# empty means the sum pinned below for the template's own pack
ARTWORK_SHA256=''
# The root of the unpacked artwork pack of the build (the directory the
# pack holds): the wallpaper helper of the session is installed in the
# site set and in the live set from it.
ARTWORK_PACK_ROOT=''
# The pinned commits of the installer-template and the artwork template:
# used when product.conf names neither a ref nor a directory ("none" turns
# either off: the stand-in installer, the branding this template ships).
INSTALLER_PIN=49bc24d10748c4853de98e02ea2240071bda8803
# The live image names its medium in /var/run/wtfbsd-live-medium
# (libexec/<slug>/live-medium, from rc.d/<slug>_live); with yes the
# installer offers no disk when a memory root does not name its medium.
LIVE_MEDIUM_REQUIRED=yes
ARTWORK_PIN=ce8e9714a2b47e3f17ff36ea647dbcc02f4399ac
# The pre-rendered packs published for the pinned artwork commit (release
# pack-<commit12> of the artwork template): <commit12>:<variant>:<name>:<sha256>.
# A ref with a pack here is downloaded and checked, not rendered.
ARTWORK_RELEASES=''
ARTWORK_PACK_SUMS='ce8e9714a2b4:default:examplebsd:cf0b37d9a793f8f16cc78f2a82122fac28087253cc27cac384357fd6a6d85ce7
ce8e9714a2b4:cyberpunk:examplebsd:fd02f48114c0e969ed92584953062da72b1923c759b0dff2701fd201cc248669'
ARTWORK_VARIANT=''
PRODUCT_VERSION=''
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
	NET_IF) NET_IF=$_v ;;
	NET_IPV4) NET_IPV4=$_v ;;
	NET_NETMASK) NET_NETMASK=$_v ;;
	NET_GATEWAY) NET_GATEWAY=$_v ;;
	NET_DNS) NET_DNS=$_v ;;
	DOMAIN) DOMAIN=$_v ;;
	INSTALLER_REF) INSTALLER_REF=$_v ;;
	INSTALLER_URL) INSTALLER_URL=$_v ;;
	INSTALLER_DIR) INSTALLER_DIR=$_v ;;
	ARTWORK_REF) ARTWORK_REF=$_v ;;
	ARTWORK_URL) ARTWORK_URL=$_v ;;
	ARTWORK_DIR) ARTWORK_DIR=$_v ;;
	ARTWORK_PACK) ARTWORK_PACK=$_v ;;
	ARTWORK_PACK_SHA256) ARTWORK_PACK_SHA256=$_v ;;
	ARTWORK_RELEASES) ARTWORK_RELEASES=$_v ;;
	ARTWORK_SHA256) ARTWORK_SHA256=$_v ;;
	ARTWORK_VARIANT) ARTWORK_VARIANT=$_v ;;
	PRODUCT_VERSION) PRODUCT_VERSION=$_v ;;
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
# set after the release without the dot: 8.0 -> site80.tgz.
chk '^[0-9]+\.[0-9]+$' "$RELEASE" "release must be N.N, e.g. 8.0 (got: $RELEASE)"
SITENUM=$(printf '%s' "$RELEASE" | tr -d '.')

# The installer-template of the live set: one of INSTALLER_DIR and
# INSTALLER_REF (a git ref of INSTALLER_URL), or neither (the stand-in).
INSTALLER_URL=${INSTALLER_URL:-https://github.com/wtfbsd/installer-template.git}
_inst_pin=yes
[ "$INSTALLER_REF" != none ] || { INSTALLER_REF=''; _inst_pin=no; }
[ -z "$INSTALLER_REF" ] || [ -z "$INSTALLER_DIR" ] \
	|| die 'INSTALLER_REF and INSTALLER_DIR do not go together: name one installer-template'
if [ -n "$INSTALLER_REF" ]; then
	chk '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' "$INSTALLER_REF" 'INSTALLER_REF must be a git ref or commit (letters, digits, . _ / -; not starting with -)'
	chk '^(https|file)://[A-Za-z0-9._~/:@%+-]+$' "$INSTALLER_URL" 'INSTALLER_URL must be an https:// or file:// URL'
fi
case $INSTALLER_DIR in *[[:space:]]*) die "INSTALLER_DIR may not contain whitespace: $INSTALLER_DIR" ;; esac
[ -n "$INSTALLER_DIR" ] || [ "$_inst_pin" = no ] || INSTALLER_REF=${INSTALLER_REF:-$INSTALLER_PIN}


# --------------------------------------------------------------------------
# the network of the install
# --------------------------------------------------------------------------

# The response file can answer the network questions of the installer.
# Without the answers the installer asks the operator, and it aborts
# when there is no DHCP at all: "Question has no answer in response file:
# default ipv4 route? (ipv4 address or 'none')".
#
# The answers are optional: without NET_IPV4 the interface is configured
# with DHCP (the answer "autoconf"), which is what a product.conf without
# a network means.
NETMODE=NET_DHCP
DOMAIN=${DOMAIN:-example.org}

# quad <value> — a dotted quad whose octets are 0..255. An octet with a
# leading zero is refused: 010 is not 10, and it is not what the reader
# of the answer means.
quad() {
	case $1 in
	'' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	IFS=. read -r _quad1 _quad2 _quad3 _quad4 _quadrest << EOF
$1
EOF
	[ -z "${_quadrest:-}" ] || return 1
	for _octet in "$_quad1" "$_quad2" "$_quad3" "$_quad4"; do
		case $_octet in
		'' | *[!0-9]*) return 1 ;;
		esac
		[ "${#_octet}" -le 3 ] || return 1
		if [ "${#_octet}" -gt 1 ]; then
			case $_octet in
			0*) return 1 ;;
			esac
		fi
		[ "$_octet" -le 255 ] || return 1
	done
	return 0
}

# netmask <value> — the mask is a run of one bits followed by a run of
# zero bits: 255.255.255.0, 255.255.240.0, 0.0.0.0 and 255.255.255.255
# are masks, a mask with a hole is not one.
netmask() {
	quad "$1" || return 1
	IFS=. read -r _mask1 _mask2 _mask3 _mask4 _maskrest << EOF
$1
EOF
	[ -z "${_maskrest:-}" ] || return 1
	_bits=''
	for _octet in "$_mask1" "$_mask2" "$_mask3" "$_mask4"; do
		_val=$_octet
		_n=8
		while [ "$_n" -gt 0 ]; do
			_n=$((_n - 1))
			if [ "$_val" -ge $((1 << _n)) ]; then
				_bits="${_bits}1"
				_val=$((_val - (1 << _n)))
			else
				_bits="${_bits}0"
			fi
		done
	done
	# the bits after the leading ones must be zeros
	_rest=$_bits
	while :; do
		case $_rest in
		1*)
			_rest=${_rest#1}
			;;
		*) break ;;
		esac
	done
	case $_rest in
	*1*) return 1 ;;
	esac
	return 0
}

# dnslist <value> — a list of dotted quads, separated by spaces
dnslist() {
	[ -n "${1:-}" ] || return 1
	# The list is split on the white space of the shell, with the
	# pathname expansion off: a glob character of the answer stays a
	# glob character and does not become the names of the files of the
	# directory.
	set -f
	_count=0
	for _server in $1; do
		quad "$_server" || { set +f; return 1; }
		_count=$((_count + 1))
	done
	set +f
	[ "$_count" -gt 0 ] || return 1
	return 0
}

if [ -n "${NET_IPV4:-}" ]; then
	NETMODE=NET_STATIC
	[ -n "${NET_IF:-}" ] || die 'NET_IPV4 is set: NET_IF is required (the interface to configure)'
	[ -n "${NET_NETMASK:-}" ] || die 'NET_IPV4 is set: NET_NETMASK is required'
	[ -n "${NET_GATEWAY:-}" ] || die 'NET_IPV4 is set: NET_GATEWAY is required'
	[ -n "${NET_DNS:-}" ] || die 'NET_IPV4 is set: NET_DNS is required'
	chk '^[a-z]+[0-9]+$' "$NET_IF" "NET_IF must be an interface name like em0 (got: $NET_IF)"
	quad "$NET_IPV4" || die "NET_IPV4 must be a dotted quad, every octet 0-255 (got: $NET_IPV4)"
	[ "$NET_IPV4" != 0.0.0.0 ] \
		|| die 'NET_IPV4 must be the address of the interface, not the unspecified address 0.0.0.0'
	netmask "$NET_NETMASK" \
		|| die "NET_NETMASK must be a contiguous netmask, e.g. 255.255.255.0 (got: $NET_NETMASK)"
	quad "$NET_GATEWAY" || die "NET_GATEWAY must be a dotted quad, every octet 0-255 (got: $NET_GATEWAY)"
	[ "$NET_GATEWAY" != 0.0.0.0 ] \
		|| die 'NET_GATEWAY must be the default route, not the unspecified address 0.0.0.0'
	dnslist "$NET_DNS" || die "NET_DNS must be a list of dotted quads, every octet 0-255 (got: $NET_DNS)"
else
	case ${NET_IF:-}${NET_NETMASK:-}${NET_GATEWAY:-}${NET_DNS:-} in
	'') ;;
	*) die 'NET_IPV4 is not set: the answers of the network would be dropped; set NET_IPV4 or remove the other NET_ keys' ;;
	esac
fi
chk '^[A-Za-z0-9][A-Za-z0-9.-]*$' "$DOMAIN" "DOMAIN must be a domain name (got: $DOMAIN)"

chk '^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$' \
	"${BRAND_COLOR:-3b6ea5}" 'BRAND_COLOR must be six hex digits'
# The title of the xenodm(1) greeter is drawn in the brand colour, made
# lighter (mixed with white) until it has a contrast of at least 4.5:1
# (WCAG AA) against the background of the login box (#1e2440, set by the
# branding of xenodm, overlay/profiles/desktop/.../xenodm/Xresources).
GREET_BG=1e2440
greet_colour() { # greet_colour <rrggbb> — the lightest-needed tint, rrggbb
	c="$1" bg="$GREET_BG" awk 'BEGIN { c = ENVIRON["c"]; bg = ENVIRON["bg"] } 
		function hx(s,  i, v, d) { v = 0; s = tolower(s)
			for (i = 1; i <= length(s); i++) { d = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + d }
			return v }
		function lin(v) { v /= 255; return (v <= 0.03928) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
		function lum(r, g, b) { return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
		BEGIN {
			r = hx(substr(c, 1, 2)); g = hx(substr(c, 3, 2)); b = hx(substr(c, 5, 2))
			lb = lum(hx(substr(bg, 1, 2)), hx(substr(bg, 3, 2)), hx(substr(bg, 5, 2)))
			for (t = 0; t <= 1.0001; t += 0.05) {
				R = int(r + (255 - r) * t + 0.5); G = int(g + (255 - g) * t + 0.5); B = int(b + (255 - b) * t + 0.5)
				l = lum(R, G, B)
				hi = (l > lb) ? l : lb; lo = (l > lb) ? lb : l
				if ((hi + 0.05) / (lo + 0.05) >= 4.5) { printf "%02x%02x%02x\n", R, G, B; exit }
			}
			print "ffffff"
		}'
}
GREET_COLOR=$(greet_colour "${BRAND_COLOR:-3b6ea5}")
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

# The artwork template: a pre-rendered pack (ARTWORK_PACK, a file or an
# https URL, with ARTWORK_PACK_SHA256), a checkout (ARTWORK_DIR) or a git
# ref of ARTWORK_URL (ARTWORK_REF, the pinned commit by default); the last
# two are rendered into a pack with its scripts/pack.sh. ARTWORK_REF=none:
# the branding this template ships. The variant names the palette and the
# art (default, cyberpunk, ...).
ARTWORK_URL=${ARTWORK_URL:-https://github.com/wtfbsd/artwork-template.git}
_art_pin=yes
[ "$ARTWORK_REF" != none ] || { ARTWORK_REF=''; _art_pin=no; }
[ "$(printf '%s' "$ARTWORK_PACK$ARTWORK_DIR" | wc -c)" -eq 0 ] || [ -z "$ARTWORK_REF" ] \
	|| die 'ARTWORK_REF does not go with ARTWORK_DIR or ARTWORK_PACK: name one artwork template'
[ -z "$ARTWORK_PACK" ] || [ -z "$ARTWORK_DIR" ] \
	|| die 'ARTWORK_PACK and ARTWORK_DIR do not go together: name one artwork template'
if [ -n "$ARTWORK_SHA256" ]; then
	chk '^[0-9a-f]{64}$' "$ARTWORK_SHA256" 'ARTWORK_SHA256 must be the sha256 of the artwork pack (64 hex digits)'
	[ -z "$ARTWORK_DIR" ] || die 'ARTWORK_SHA256 does not go with ARTWORK_DIR: a checkout is rendered, not downloaded'
	[ "$_art_pin" = yes ] || die 'ARTWORK_SHA256 does not go with ARTWORK_REF=none: the template'"'"'s own branding is not a pack'
	# a pack file named by ARTWORK_PACK takes it as its sum
	[ -z "$ARTWORK_PACK" ] || [ -n "$ARTWORK_PACK_SHA256" ] || ARTWORK_PACK_SHA256=$ARTWORK_SHA256
fi
if [ -n "$ARTWORK_PACK" ]; then
	chk '^[0-9a-f]{64}$' "$ARTWORK_PACK_SHA256" 'ARTWORK_PACK needs ARTWORK_PACK_SHA256, the sha256 of the pack (64 hex digits)'
	case $ARTWORK_PACK in
		https://*) chk '^https://[A-Za-z0-9._~/:@%+-]+$' "$ARTWORK_PACK" 'ARTWORK_PACK must be a file or an https:// URL' ;;
		*[[:space:]]*) die "ARTWORK_PACK may not contain whitespace: $ARTWORK_PACK" ;;
	esac
fi
[ -n "$ARTWORK_PACK$ARTWORK_DIR" ] || [ "$_art_pin" = no ] || ARTWORK_REF=${ARTWORK_REF:-$ARTWORK_PIN}
# where the packs of a release are downloaded from
ARTWORK_RELEASES=${ARTWORK_RELEASES:-https://github.com/wtfbsd/artwork-template/releases/download}
chk '^(https|file)://[A-Za-z0-9._~/:@%+-]+$' "$ARTWORK_RELEASES" 'ARTWORK_RELEASES must be an https:// or file:// URL'
ARTWORK_VARIANT=${ARTWORK_VARIANT:-default}
# the pinned commit is downloaded as its published pack: the variant must be
# one of the packs pinned here (a product with its own pack gives its sum)
if [ "$ARTWORK_REF" = "$ARTWORK_PIN" ] && [ -z "$ARTWORK_SHA256" ]; then
	printf '%s\n' "$ARTWORK_PACK_SUMS" | v="$ARTWORK_VARIANT" awk -F: 'BEGIN { v = ENVIRON["v"] } $2 == v { f = 1 } END { exit !f }' \
		|| die "the pinned artwork pack has no variant $ARTWORK_VARIANT (pinned: $(printf '%s\n' "$ARTWORK_PACK_SUMS" | cut -d: -f2 | tr '\n' ' '))"
fi
if [ -n "$ARTWORK_REF" ]; then
	chk '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' "$ARTWORK_REF" 'ARTWORK_REF must be a git ref or commit (letters, digits, . _ / -; not starting with -)'
	chk '^(https|file)://[A-Za-z0-9._~/:@%+-]+$' "$ARTWORK_URL" 'ARTWORK_URL must be an https:// or file:// URL'
fi
case $ARTWORK_DIR in *[[:space:]]*) die "ARTWORK_DIR may not contain whitespace: $ARTWORK_DIR" ;; esac
ARTWORK_VARIANT=${ARTWORK_VARIANT:-default}
chk '^[a-z][a-z0-9-]*$' "$ARTWORK_VARIANT" 'ARTWORK_VARIANT must be a lowercase name (default, cyberpunk, ...)'
# The build stamp of the identity: the day of the build (UTC), or the day of
# SOURCE_DATE_EPOCH for a reproducible build.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	chk '^[0-9]+$' "$SOURCE_DATE_EPOCH" 'SOURCE_DATE_EPOCH must be seconds since the epoch'
	BUILD_STAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d 2> /dev/null || date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%d)
else
	BUILD_STAMP=$(date -u +%Y-%m-%d)
fi
# the version of the product: PRODUCT_VERSION, or the year.month of the build
PRODUCT_VERSION=${PRODUCT_VERSION:-$(printf '%s' "$BUILD_STAMP" | sed 's/^\([0-9]*\)-\([0-9]*\)-.*/\1.\2/')}
chk '^[A-Za-z0-9][A-Za-z0-9.+_-]*$' "$PRODUCT_VERSION" 'PRODUCT_VERSION must be a version (letters, digits, . + _ -)'
# The identity (the format of the artwork template, scripts/lib-identity.sh):
# VARIANT is the label of the variant (Default, Cyberpunk); BUILD is the
# day of the build on test builds (WTFBSD_TEST_BUILD=yes) and empty on
# releases. The line, lower left on the greeter and the desktop:
# <Product> <version> · <base> · <variant> · <arch> [· build <day>]
ID_VARIANT=$(printf '%s' "$ARTWORK_VARIANT" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$ARTWORK_VARIANT" | cut -c2-)
ID_BUILD=''
[ "${WTFBSD_TEST_BUILD:-no}" != yes ] || ID_BUILD=$BUILD_STAMP
printf '%s' "$DISTRO_NAME" | grep -Eq '^[A-Za-z0-9 ._:+()/-]{1,64}$' \
	|| die 'DISTRO_NAME must be letters, digits, space and . _ : + - ( ) / for the identity line'
IDENTITY_LINE=$(printf '%s %s \302\267 OpenBSD %s \302\267 %s \302\267 %s' \
	"$DISTRO_NAME" "$PRODUCT_VERSION" "$RELEASE" "$ID_VARIANT" "$DISTRO_ARCH")
[ -z "$ID_BUILD" ] || IDENTITY_LINE="$IDENTITY_LINE $(printf '\302\267') build $ID_BUILD"
# the same line for an SVG text element
IDENTITY_XML=$(printf '%s' "$IDENTITY_LINE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

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

conf_for_profile() { # conf_for_profile <template> <profile> <mode> — the answers of that profile
	# A block of the template that belongs to another profile is dropped:
	#   #@profile desktop
	#   ... the answers of the desktop ...
	#   #@endprofile
	# A block that depends on the mode of the build is kept when the mode
	# is the one of the block:
	#   #@if NET_STATIC
	#   ... the answers of that mode ...
	#   #@endif
	#
	# The template is checked while it is read: an #@if without an
	# #@endif, an #@endif without an #@if, an #@else outside an #@if, a
	# second #@else in one #@if, a nested #@if, a #@profile without an
	# #@endprofile, a #@endprofile without a #@profile, a #@profile
	# inside an open #@if, a #@profile inside an open #@profile, an
	# #@endprofile inside an #@if, an indented directive and an unknown
	# directive are refused, and the message names the file and the
	# line. The answers of a broken template would be the answers of
	# half a template, and the installer asks the questions that are
	# missing.
	prof="$2" mode="$3" tmpl="$1" awk 'BEGIN { prof = ENVIRON["prof"]; mode = ENVIRON["mode"]; tmpl = ENVIRON["tmpl"] }
		function fail(msg, line) {
			failed = 1
			printf "%s: line %d: %s\n", tmpl, line, msg | "cat >&2"
			close("cat >&2")
			exit 1
		}
		/^[ \t]*#@/ {
			# A directive is at the start of the line: an indented
			# one is refused, so a directive that is an answer is
			# never read as a directive.
			if ($0 !~ /^#@/) fail("an indented directive: " $1, NR)
			if ($1 == "#@if") {
				if (inif) fail("a nested #@if", NR)
				inif = 1
				ifline = NR
				ifkeep = 0
				inelse = 0
				for (i = 2; i <= NF; i++) if ($i == mode) ifkeep = 1
				next
			}
			if ($1 == "#@else") {
				if (!inif) fail("an #@else outside an #@if", NR)
				if (inelse) fail("a second #@else in one #@if", NR)
				inelse = 1
				ifkeep = !ifkeep
				next
			}
			if ($1 == "#@endif") {
				if (!inif) fail("an #@endif without an #@if", NR)
				inif = 0
				ifkeep = 0
				inelse = 0
				next
			}
			if ($1 == "#@profile") {
				if (inif) fail("a #@profile inside an open #@if", NR)
				if (inblock) fail("a #@profile inside an open #@profile", NR)
				inblock = 1
				profileline = NR
				keep = 0
				for (i = 2; i <= NF; i++) if ($i == prof) keep = 1
				next
			}
			if ($1 == "#@endprofile") {
				if (inif) fail("an #@endprofile inside an open #@if", NR)
				if (!inblock) fail("an #@endprofile without a #@profile", NR)
				inblock = 0
				keep = 0
				next
			}
			fail("unknown directive: " $1, NR)
		}
		inblock && !keep { next }
		inif && !ifkeep { next }
		{ print }
		END {
			if (!failed && inif) fail("an #@if without an #@endif", ifline)
			if (!failed && inblock) fail("a #@profile without an #@endprofile", profileline)
		}
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
		die 'the site set has to be owned by root: the tar(1) of OpenBSD has no owner override, so the build has to run as root; build the site set on a FreeBSD or Linux node (the Build stage'"'"'s AGENT_LABEL); only the Media stage needs the OpenBSD node'
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
		case "$DISTRO_NAME$IDENTITY_XML$MOTD$DISTRO_SLUG$BRAND_URL$LOGIN_USER$LOGIN_KEY$NET_IF$NET_IPV4$NET_NETMASK$NET_GATEWAY$NET_DNS$DOMAIN" in *"$cand"*) ;; *) d=$cand; break ;; esac
	done
	[ -n "$d" ] || die 'DISTRO_NAME/MOTD/DISTRO_SLUG/BRAND_URL/USER/PUBKEY/NET_IF/NET_IPV4/NET_NETMASK/NET_GATEWAY/NET_DNS/DOMAIN contain every candidate sed delimiter (| , ; : %); remove one of those characters in product.conf'
	{
		printf 's%s@DISTRO_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_NAME")" "$d"
		printf 's%s@MOTD@%s%s%sg\n' "$d" "$d" "$(sed_esc "$MOTD")" "$d"
		printf 's%s@SLUG@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_SLUG")" "$d"
		printf 's%s@BRAND_URL@%s%s%sg\n' "$d" "$d" "$(sed_esc "$BRAND_URL")" "$d"
		printf 's%s@USER@%s%s%sg\n' "$d" "$d" "$(sed_esc "$LOGIN_USER")" "$d"
		printf 's%s@PUBKEY@%s%s%sg\n' "$d" "$d" "$(sed_esc "$LOGIN_KEY")" "$d"
		printf 's%s@NET_IF@%s%s%sg\n' "$d" "$d" "$(sed_esc "$NET_IF")" "$d"
		printf 's%s@NET_IPV4@%s%s%sg\n' "$d" "$d" "$(sed_esc "$NET_IPV4")" "$d"
		printf 's%s@NET_NETMASK@%s%s%sg\n' "$d" "$d" "$(sed_esc "$NET_NETMASK")" "$d"
		printf 's%s@NET_GATEWAY@%s%s%sg\n' "$d" "$d" "$(sed_esc "$NET_GATEWAY")" "$d"
		printf 's%s@NET_DNS@%s%s%sg\n' "$d" "$d" "$(sed_esc "$NET_DNS")" "$d"
		printf 's%s@DOMAIN@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DOMAIN")" "$d"
		printf 's%s@BRAND_COLOR@%s%s%sg\n' "$d" "$d" "$(sed_esc "${BRAND_COLOR:-3b6ea5}")" "$d"
		printf 's%s@GREET_COLOR@%s%s%sg\n' "$d" "$d" "$GREET_COLOR" "$d"
		printf 's%s@GREET_BG@%s%s%sg\n' "$d" "$d" "$GREET_BG" "$d"
		printf 's%s@IDENTITY_XML@%s%s%sg\n' "$d" "$d" "$(sed_esc "$IDENTITY_XML")" "$d"
	} > "$SUBFILE"
}

subst_tree() { # subst_tree <dir> — substitute the placeholders in every file
	find "$1" -type f | while IFS= read -r _f; do
		sed -f "$SUBFILE" "$_f" > "$_f.new" && mv "$_f.new" "$_f"
	done
}

rename_slug() { # rename_slug <dir> — a staged path with @SLUG@ in it gets the slug
	# -depth: the entries of a directory are renamed before the directory,
	# and only the last component of a path is renamed, so a name with
	# @SLUG@ inside a directory with @SLUG@ is found where it is
	find "$1" -depth -name '*@SLUG@*' | while IFS= read -r _f; do
		_b=$(basename -- "$_f" | sed "s/@SLUG@/$DISTRO_SLUG/g")
		mv -- "$_f" "$(dirname -- "$_f")/$_b"
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


# --------------------------------------------------------------------------
# the live set (desktop)
# --------------------------------------------------------------------------
#
# live<NN>.tgz is the live layer of the live image (ci/media.sh live): the
# live session (rc.d/<slug>_live, the X server logged in as the live user),
# the installer opened first, the doas.conf(5) rule of the live user, the
# install command <slug>-install and the list of the live-only packages.
# The media helper unpacks it over the live image after the site set; the
# installed system never gets any of it: <slug>-install installs the signed
# sets and the site set only.

artwork_source() { # where the branding of the desktop comes from
	if [ -n "$ARTWORK_PACK" ]; then
		printf 'the pack %s (%s), sha256 %s\n' "$ARTWORK_PACK" "$ARTWORK_VARIANT" "$ARTWORK_PACK_SHA256"
	elif [ -n "$ARTWORK_DIR" ]; then
		printf 'artwork-template from %s (%s), rendered\n' "$ARTWORK_DIR" "$ARTWORK_VARIANT"
	elif [ -z "$ARTWORK_REF" ]; then
		printf 'the branding this template ships (ARTWORK_REF=none)\n'
	elif [ -n "$ARTWORK_SHA256" ]; then
		printf 'artwork-template %s (%s), published pack, sha256 %s (product.conf)\n' "$ARTWORK_REF" "$ARTWORK_VARIANT" "$ARTWORK_SHA256"
	else
		printf 'artwork-template %s (%s), published pack, sha256 pinned by this template\n' "$ARTWORK_REF" "$ARTWORK_VARIANT"
	fi
}

installer_source() { # how the live set gets its installer
	if [ -n "$INSTALLER_DIR" ]; then
		printf 'installer-template from %s\n' "$INSTALLER_DIR"
	elif [ -n "$INSTALLER_REF" ]; then
		printf 'installer-template %s of %s\n' "$INSTALLER_REF" "$INSTALLER_URL"
	else
		printf 'the stand-in text installer (no INSTALLER_REF or INSTALLER_DIR)\n'
	fi
}

# git_checkout KNOB URL REF DIR: clone URL into DIR and detach at REF (KNOB
# names the setting in the messages)
git_checkout() {
	command -v git > /dev/null 2>&1 || die "$1 needs git"
	git clone -q -- "$2" "$4" || die "git clone $2 failed ($1 $3)"
	git -C "$4" -c advice.detachedHead=false checkout -q --detach "$3" \
		|| die "git checkout $3 of $2 failed"
}

fetch_installer() { # fetch_installer <dir> — the installer-template, into <dir>
	# INSTALLER_DIR is copied; INSTALLER_REF is cloned from INSTALLER_URL
	# and checked out. Either way the tree must have install-into-stage.sh.
	_fi=$1
	rmrf "$_fi" "$OUT/.stage"
	if [ -n "$INSTALLER_DIR" ]; then
		[ -d "$INSTALLER_DIR" ] || die "INSTALLER_DIR: no such directory: $INSTALLER_DIR"
		cp -R "$INSTALLER_DIR" "$_fi" || die "cannot copy $INSTALLER_DIR to $_fi"
	else
		git_checkout INSTALLER_REF "$INSTALLER_URL" "$INSTALLER_REF" "$_fi"
	fi
	[ -f "$_fi/install-into-stage.sh" ] \
		|| die "the installer-template ${INSTALLER_DIR:-$INSTALLER_REF} has no install-into-stage.sh"
}

tar_set() { # tar_set <archive> <dir> <list> — a POSIX ustar set rooted in /
	# The media helper reads every header of the live set itself and
	# accepts plain ustar members only: the format is named, never the
	# default of the host (GNU tar writes its own format, the tar(1) of
	# OpenBSD writes pax).
	case $(tar_flavour) in
	gnu)
		tar --format=ustar -czf "$1" -C "$2" --owner=0 --group=0 --numeric-owner --mtime=@0 -T "$3"
		;;
	bsd)
		tar --format ustar -czf "$1" -C "$2" --uid 0 --gid 0 --uname root --gname root -T "$3"
		;;
	openbsd)
		tar -c -z -F ustar -f "$1" -C "$2" -I "$3"
		;;
	esac
}

build_live() { # build_live <outdir> — the live set of the desktop
	_lod=$1
	_ls="$OUT/.stage/live"
	_ltgz="$_lod/live$SITENUM.tgz"
	rmrf "$_ls" "$OUT/.stage"
	mkdir -p "$_ls"
	copy_tree "$ROOT/overlay/live/rootfs" "$_ls"

	# the one rc.conf.local of the live image: the base file, the
	# fragment of the desktop profile, then the live fragment
	mkdir -p "$_ls/etc"
	{
		cat "$ROOT/overlay/base/rootfs/etc/rc.conf.local"
		printf '\n'
		cat "$ROOT/overlay/profiles/desktop/rootfs/etc/rc.conf.local"
		printf '\n'
		cat "$ROOT/overlay/live/rc.conf.local"
	} > "$_ls/etc/rc.conf.local"

	# the packages of the live image only
	mkdir -p "$_ls/usr/local/share/@SLUG@"
	{
		printf '# live-packages.list — the packages of the live image only;\n'
		printf '# the media helper installs them with pkg_add(1).\n'
		printf '#\n'
		printf '# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).\n'
		printf '\n'
		pkg_list "$ROOT/overlay/live/packages.list"
	} > "$_ls/usr/local/share/@SLUG@/live-packages.list"

	# the executables of the overlay keep their mode through the
	# substitution
	_lx="$OUT/.stage/live.exec"
	( cd "$_ls" && find . -type f \( -path './etc/rc.d/*' -o -path './usr/local/bin/*' \
		-o -path './usr/local/sbin/*' -o -path './usr/local/libexec/*' \) | sed 's|^\./||' ) > "$_lx"
	mk_subst
	subst_tree "$_ls"
	rename_slug "$_ls"
	sed "s/@SLUG@/$DISTRO_SLUG/g" "$_lx" > "$_lx.new" && mv "$_lx.new" "$_lx"

	# the installer-template: its launcher replaces the stand-in
	if [ -n "$INSTALLER_DIR$INSTALLER_REF" ]; then
		_it="$OUT/.stage/installer-template"
		fetch_installer "$_it"
		( cd "$_ls" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$OUT/.stage/live.before"
		# the configuration of the installer: this product, on OpenBSD
		_ic="$OUT/.stage/installer.conf"
		{
			printf '# the installer of %s (build.sh, the live set)\n' "$DISTRO_NAME"
			printf 'PRODUCT_NAME=%s\n' "$DISTRO_NAME"
			printf 'PRODUCT_SLUG=%s\n' "$DISTRO_SLUG"
			printf 'OS=openbsd\n'
			printf 'DEFAULT_KEYMAP=us\n'
			printf 'DEFAULT_TZ=UTC\n'
			printf 'LIVE_MEDIUM_REQUIRED=%s\n' "$LIVE_MEDIUM_REQUIRED"
		} > "$_ic"
		# Without root the installer-template writes the owners into a
		# metalog instead; the live set is archived with the owner 0:0
		# (tar_set), so the metalog is not needed afterwards.
		set -- "$_ls" --conf "$_ic"
		[ "$(id -u)" = 0 ] || set -- "$@" --metalog "$OUT/.stage/installer.metalog"
		sh "$_it/install-into-stage.sh" "$@" > /dev/null \
			|| die "$_it/install-into-stage.sh $_ls failed"
		rm -f "$_ic" "$OUT/.stage/installer.metalog"
		[ -f "$_ls/usr/local/bin/wtfbsd-installer" ] \
			|| die "install-into-stage.sh left no launcher $_ls/usr/local/bin/wtfbsd-installer"
		# its menu entry replaces the one of the stand-in
		rm -f "$_ls/usr/local/share/applications/$DISTRO_SLUG-install.desktop"
		# the files of the installer that are executable stay so
		( cd "$_ls" && find . -type f -perm -u+x | sed 's|^\./||' ) >> "$_lx"
		rmrf "$_it" "$OUT/.stage"
	fi

	find "$_ls" -type d -exec chmod 0755 {} +
	find "$_ls" -type f -exec chmod 0644 {} +
	while IFS= read -r _f; do
		[ -f "$_ls/$_f" ] && chmod 0755 "$_ls/$_f"
	done < "$_lx"
	chmod 0755 "$_ls/usr/local/bin/wtfbsd-installer"
	chmod 0600 "$_ls/etc/doas.conf"
	# the wallpaper helper of the artwork pack: the live session gets the
	# same autostart entry and the same script as the installed system
	# (the modes of the two files are set by install_wallpaper)
	if [ -n "$ARTWORK_PACK_ROOT" ]; then
		install_wallpaper "$_ls" "$ARTWORK_PACK_ROOT"
	elif [ -n "$ARTWORK_PACK$ARTWORK_DIR$ARTWORK_REF" ]; then
		# the live set is the set of the desktop profile, and the
		# artwork of the build is pinned: the live session has a
		# wallpaper helper. A live set without one is a silent failure.
		die 'the live set has no wallpaper helper: the pack of the artwork of the build is not there'
	fi
	rm -f "$_lx" "$OUT/.stage/live.before"
	rmrf "$OUT/.stage/artwork" "$OUT/.stage"
	ARTWORK_PACK_ROOT=''
	if [ "$(id -u)" = 0 ]; then
		chown -R 0:0 "$_ls"
	fi
	TZ=UTC find "$_ls" -exec touch -t 197001010000 {} +

	_llist=$(abspath "$_ls.list")
	stage_list "$_ls" "$_llist"
	tar_set "$_ltgz" "$_ls" "$_llist"
	rm -f "$_llist"
	log "    + $_ltgz ($(installer_source))"
}

sha256_of() { # sha256_of <file> — the hex sha256 of a file
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v sha256 > /dev/null 2>&1; then
		sha256 -q "$1"
	else
		die 'no sha256sum or sha256 to check the artwork pack'
	fi
}

fetch_https() { # fetch_https <url> <file>
	case $1 in
		file://*) cp -- "${1#file://}" "$2"; return ;;
	esac
	if command -v curl > /dev/null 2>&1; then
		curl -fsSL -o "$2" -- "$1"
	elif command -v fetch > /dev/null 2>&1; then
		fetch -q -o "$2" "$1"
	else
		ftp -V -o "$2" "$1"
	fi
}

artwork_pack() { # artwork_pack <dir> — the verified pack of the variant, unpacked under <dir>; prints its root
	_ap=$1
	rmrf "$_ap" "$OUT/.stage"
	mkdir -p "$_ap/in" "$_ap/x" || die "cannot create $_ap"
	if [ -n "$ARTWORK_PACK" ]; then
		case $ARTWORK_PACK in
			https://*) fetch_https "$ARTWORK_PACK" "$_ap/in/pack.tar.xz" || die "cannot download $ARTWORK_PACK" ;;
			*)
				[ -f "$ARTWORK_PACK" ] || die "ARTWORK_PACK: no such file: $ARTWORK_PACK"
				cp "$ARTWORK_PACK" "$_ap/in/pack.tar.xz" || die "cannot copy $ARTWORK_PACK"
				;;
		esac
		_want=$ARTWORK_PACK_SHA256
	elif [ -z "$ARTWORK_DIR" ] && [ -n "$ARTWORK_SHA256" ]; then
		# product.conf names the sum of the pack (wtfbsd/agents
		# ARTWORK_SHA256): the published pack of ARTWORK_REF, checked
		# against that sum. Its name is the one pinned for a known commit,
		# else the product's own (a fork's pack is named after its product).
		_c=$(printf '%s' "$ARTWORK_REF" | cut -c1-12)
		_n=$(printf '%s\n' "$ARTWORK_PACK_SUMS" | c="$_c" awk -F: 'BEGIN { c = ENVIRON["c"] } $1 == c { print $3; exit }')
		_n=${_n:-$DISTRO_SLUG}
		_want=$ARTWORK_SHA256
		_u="$ARTWORK_RELEASES/pack-$_c/$_n-$_c-$ARTWORK_VARIANT.tar.xz"
		fetch_https "$_u" "$_ap/in/pack.tar.xz" \
			|| die "cannot download the pack of artwork-template $ARTWORK_REF ($ARTWORK_VARIANT): $_u (check that its pack release has this variant, that ARTWORK_RELEASES is right, and that the host is reachable)"
	elif _rel=$(printf '%s\n' "$ARTWORK_PACK_SUMS" | c="$(printf '%s' "$ARTWORK_REF" | cut -c1-12)" v="$ARTWORK_VARIANT" awk -F: \
		'BEGIN { c = ENVIRON["c"]; v = ENVIRON["v"] } length(c) == 12 && $1 == c && $2 == v { print; f = 1; exit } END { exit !f }'); then
		# the published pack of the pinned commit: downloaded, checked against
		# the sha256 pinned here
		_c=${_rel%%:*}
		_n=$(printf '%s' "$_rel" | cut -d: -f3)
		_want=$(printf '%s' "$_rel" | cut -d: -f4)
		_u="$ARTWORK_RELEASES/pack-$_c/$_n-$_c-$ARTWORK_VARIANT.tar.xz"
		fetch_https "$_u" "$_ap/in/pack.tar.xz" \
			|| die "cannot download the pack of artwork-template $ARTWORK_REF ($ARTWORK_VARIANT): $_u (check that its pack release has this variant, that ARTWORK_RELEASES is right, and that the host is reachable)"
	else
		# a checkout or a ref: its own scripts/pack.sh renders the pack
		_src=$_ap/src
		if [ -n "$ARTWORK_DIR" ]; then
			[ -d "$ARTWORK_DIR" ] || die "ARTWORK_DIR: no such directory: $ARTWORK_DIR"
			cp -R "$ARTWORK_DIR" "$_src" || die "cannot copy $ARTWORK_DIR"
			_c=$(git -C "$_src" rev-parse --short=12 HEAD 2> /dev/null || printf '000000000000')
		else
			git_checkout ARTWORK_REF "$ARTWORK_URL" "$ARTWORK_REF" "$_src"
			_c=$(git -C "$_src" rev-parse --short=12 HEAD)
		fi
		[ -f "$_src/scripts/pack.sh" ] || die "the artwork template ${ARTWORK_DIR:-$ARTWORK_REF} has no scripts/pack.sh"
		( cd "$_src" && sh scripts/pack.sh --commit "$_c" --variant "$ARTWORK_VARIANT" "$_ap/packs" ) > "$_ap/pack.log" 2>&1 \
			|| die "scripts/pack.sh of the artwork template failed (it renders with rsvg-convert, inkscape or cairosvg and ImageMagick): $(tail -n 3 "$_ap/pack.log" | tr '\n' ' ')"
		_pf=$(ls "$_ap/packs/"*"-$ARTWORK_VARIANT.tar.xz" 2> /dev/null | head -n 1)
		[ -n "$_pf" ] || die "scripts/pack.sh wrote no pack of the variant $ARTWORK_VARIANT"
		mv "$_pf" "$_ap/in/pack.tar.xz" || die 'cannot move the pack'
		_want=$(cut -d ' ' -f 1 < "$_pf.sha256")
	fi
	[ "$(sha256_of "$_ap/in/pack.tar.xz")" = "$_want" ] \
		|| die "the artwork pack does not match its sha256 ($_want)"
	xz -dc "$_ap/in/pack.tar.xz" | tar -xf - -C "$_ap/x" || die 'cannot unpack the artwork pack'
	_root=$(find "$_ap/x" -mindepth 1 -maxdepth 1 -type d)
	[ "$(printf '%s\n' "$_root" | grep -c .)" = 1 ] || die 'the artwork pack must hold one directory'
	grep -qx "variant=$ARTWORK_VARIANT" "$_root/PACK" 2> /dev/null \
		|| die "the artwork pack is not of the variant $ARTWORK_VARIANT (its PACK says $(grep '^variant=' "$_root/PACK" 2> /dev/null))"
	[ -f "$_root/branding/spots.tsv" ] || die 'the artwork pack has no branding/spots.tsv'
	printf '%s\n' "$_root"
}

# The columns of branding/spots.tsv this template reads, by name (the
# header of the artwork template): the spot, its OpenBSD cell (the install
# path, "n/a: <reason>" or "check: ..."), the rendered files of the pack.
SPOT_COLS='spot openbsd rendered'
# The spots this template installs from the pack, and the ones that are
# installed elsewhere or not yet (each with its reason, in the README).
# A spot OpenBSD supports that is in neither list fails the build, so a new
# spot of the artwork template is never left at the OpenBSD default unseen.
SPOTS_HERE='xenodm-logo xenodm-colours xenodm-background wallpapers icon-distributor icon-menu icon-installer identity-file identity-line login-issue xfce-theme'
SPOTS_ELSEWHERE='motd installer-header installer-sidebar installer-palette installer-slides installer-name'

# slug_replace <from> <to> <in> <out> — copy <in> to <out>, with every
# literal occurrence of <from> replaced by <to>. The two are strings, not
# regular expressions: the name of a pack is data, and a regular expression
# built from data is a way to fail in a new way.
slug_replace() { # slug_replace <from> <to> <in> <out>
	[ -n "${1:-}" ] || die 'slug_replace: the string to replace is empty'
	awk -v a="$1" -v b="$2" '
		function rep(s,   i, out) {
			out = ""
			while ((i = index(s, a)) > 0) {
				out = out substr(s, 1, i - 1) b
				s = substr(s, i + length(a))
			}
			return out s
		}
		{ print rep($0) }
	' "$3" > "$4" || die "cannot write $4"
}

# The wallpaper helper of the artwork template: an autostart entry for the
# Xfce session and the script it runs. The paths are fixed: the entry is
# /etc/xdg/autostart/<slug>-wallpaper.desktop (mode 0644) and the script is
# /usr/local/share/<slug>/xfce/session/<slug>-wallpaper.sh (mode 0755). The
# Exec= line of the entry is written here, so it always names the script
# that is installed, whatever the slug of the pack is.
#
# install_wallpaper <stage> <pack-root> — the pack holds exactly two files
# for the helper: out/xfce/autostart/<packslug>-wallpaper.desktop and
# out/xfce/session/<packslug>-wallpaper.sh, where <packslug> is the name=
# of the pack's PACK file. The other lines of the entry are the pack's, with
# the slug of the pack replaced by the slug of the product.
install_wallpaper() { # install_wallpaper <stage> <pack-root>
	_sw=$1
	_sp=$2
	_sl=$DISTRO_SLUG
	[ -n "$_sp" ] || die 'the wallpaper helper: no artwork pack'
	[ -f "$_sp/PACK" ] || die "the artwork pack has no PACK file ($_sp)"
	_ps=$(sed -n 's/^name=//p' "$_sp/PACK" | head -n 1)
	chk '^[a-z0-9][a-z0-9-]*$' "$_ps" 'the name of the artwork pack is not a slug'
	_sd="$_sp/out/xfce/autostart/$_ps-wallpaper.desktop"
	_ss="$_sp/out/xfce/session/$_ps-wallpaper.sh"
	_hd=no
	if [ -e "$_sd" ] || [ -L "$_sd" ]; then _hd=yes; fi
	_hs=no
	if [ -e "$_ss" ] || [ -L "$_ss" ]; then _hs=yes; fi
	if [ "$_hd" = no ] && [ "$_hs" = no ]; then
		# a pack of an artwork template that ships no helper: the
		# wallpaper is the one this template sets itself
		log '    + the pack holds no wallpaper helper'
		return 0
	fi
	[ "$_hd" = yes ] || die 'the artwork pack holds the session helper of the wallpaper but no autostart entry'
	[ "$_hs" = yes ] || die 'the artwork pack holds the autostart entry of the wallpaper but no session helper'
	# a link in the pack is a way to name a file outside the pack: the
	# helper is refused, not followed
	[ ! -L "$_sd" ] || die "the autostart entry of the wallpaper of the pack is a link ($_sd)"
	[ ! -L "$_ss" ] || die "the session helper of the wallpaper of the pack is a link ($_ss)"
	_ddst="$_sw/etc/xdg/autostart/$_sl-wallpaper.desktop"
	_sdst="$_sw/usr/local/share/$_sl/xfce/session/$_sl-wallpaper.sh"
	mkdir -p "$_sw/etc/xdg/autostart" "$_sw/usr/local/share/$_sl/xfce/session" \
		|| die 'cannot create the directories of the wallpaper helper'
	chmod 0755 "$_sw/etc/xdg/autostart" "$_sw/usr/local/share/$_sl/xfce/session" \
		|| die 'cannot set the mode of the directories of the wallpaper helper'
	# the entry: the lines of the pack, with the slug of the pack
	# replaced by the slug of the product
	slug_replace "$_ps" "$_sl" "$_sd" "$_ddst"
	# the Exec= line is ours: it names the script that is installed
	_exec="Exec=/bin/sh \"/usr/local/share/$_sl/xfce/session/$_sl-wallpaper.sh\""
	awk -v e="$_exec" '
		/^Exec=/ { if (!done) { print e; done = 1 } next }
		{ print }
		END { if (!done) print e }
	' "$_ddst" > "$_ddst.new" || die 'cannot write the autostart entry of the wallpaper'
	mv "$_ddst.new" "$_ddst" || die 'cannot write the autostart entry of the wallpaper'
	# the script: the script of the pack, with the slug of the pack
	# replaced by the slug of the product (it names the share directory
	# of the product)
	slug_replace "$_ps" "$_sl" "$_ss" "$_sdst"
	chmod 0755 "$_sdst" || die 'cannot set the mode of the session helper of the wallpaper'
	chmod 0644 "$_ddst" || die 'cannot set the mode of the autostart entry of the wallpaper'
	log "    + the wallpaper helper of the pack (etc/xdg/autostart/$_sl-wallpaper.desktop, usr/local/share/$_sl/xfce/session/$_sl-wallpaper.sh)"
}

install_artwork() { # install_artwork <stage> — the OpenBSD spots of the variant
	_st=$1
	_pr=$(artwork_pack "$OUT/.stage/artwork") || exit 1
	_sl=$DISTRO_SLUG
	_ps=$(sed -n 's/^name=//p' "$_pr/PACK")
	need="$SPOT_COLS" awk -F '\t' 'BEGIN { need = ENVIRON["need"] } 
		NR == 1 {
			for (i = 1; i <= NF; i++) col[$i] = i
			n = split(need, w, " ")
			for (i = 1; i <= n; i++) if (!(w[i] in col)) { print "missing column: " w[i] > "/dev/stderr"; bad = 1 }
			if (bad) exit 2
			next
		}
		/^#/ || NF == 0 { next }
		{ print $col["spot"] "\t" $col["openbsd"] "\t" $col["rendered"] }' \
		"$_pr/branding/spots.tsv" > "$OUT/.stage/spots.list" \
		|| die "branding/spots.tsv lacks a column this template reads ($SPOT_COLS)"
	while IFS="$(printf '\t')" read -r _spot _cell _ren; do
		case $_cell in n/a*) continue ;; esac
		case " $SPOTS_HERE " in
			*" $_spot "*) ;;
			*)
				case " $SPOTS_ELSEWHERE " in
					*" $_spot "*) continue ;;
					*) die "branding/spots.tsv has a spot OpenBSD supports that this template does not install: $_spot" ;;
				esac
				;;
		esac
		# every rendered file of a spot installed here is in the pack
		printf '%s\n' "$_ren" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e "s/<slug>/$_ps/g" \
			| while IFS= read -r _f; do
				case $_f in '' | -) continue ;; */../* | ../* | /*) die "branding/spots.tsv: a rendered path outside the pack: $_f" ;; esac
				[ -f "$_pr/out/$_f" ] || die "the artwork pack lacks $_f (spot $_spot)"
			done || exit 1
	done < "$OUT/.stage/spots.list"

	_sh=$_st/usr/local/share/$_sl
	_o=$_pr/out
	# xenodm: the logo for every depth, the login box and the setup of the
	# screen of the pack; brand-xenodm puts them in place of OpenBSD's
	mkdir -p "$_sh/xenodm/pixmaps"
	cp "$_o/dm/pixmaps/$_ps-color.xpm" "$_o/dm/pixmaps/$_ps-8bpp.xpm" "$_o/dm/pixmaps/$_ps-1bpp.xpm" \
		"$_sh/xenodm/pixmaps/" || die 'cannot install the logos of xenodm'
	{
		printf '! %s branding: the login box of the artwork template (%s), in place\n' "$_sl" "$(sed -n 's/^commit=//p' "$_pr/PACK")"
		printf '! of the OpenBSD file (kept as Xresources.openbsd).\n'
		cat "$_o/dm/xenodm/Xresources"
		printf '\n! %s branding: the name of the product as the greeting\n' "$_sl"
		printf 'xlogin*greeting: %s\n' "$DISTRO_NAME"
	} > "$_sh/xenodm/Xresources.pack" || die 'cannot install the login box of xenodm'
	# the greeter shows no xconsole (OpenBSD's Xsetup_0 starts one, and it
	# stays into the session): the console messages are in /var/log/messages
	sed -e "s|/usr/local/share/$_ps/|/usr/local/share/$_sl/|g" -e '/bin\/xconsole /d' \
		"$_o/dm/xenodm/Xsetup_0" > "$_sh/xenodm/Xsetup_0.pack" \
		|| die 'cannot install the setup of xenodm'
	# the backgrounds, stamped with the identity line by the pack's script
	mkdir -p "$_sh/lightdm" "$_sh/wallpapers" "$_sh/backgrounds"
	cp "$_o/wallpapers/"*-1920x1080.png "$_sh/wallpapers/" || die 'cannot install the wallpapers'
	( cd "$_pr" && sh scripts/identity-stamp.sh --variant "$ARTWORK_VARIANT" \
		"$_sh/identity" "$_o/lightdm/greeter-1920x1080.png" "$_sh/lightdm/greeter-1920x1080.png" ) > /dev/null \
		|| die 'scripts/identity-stamp.sh of the artwork pack cannot stamp the greeter (it needs ImageMagick)'
	( cd "$_pr" && sh scripts/identity-stamp.sh --variant "$ARTWORK_VARIANT" \
		--bottom 48 "$_sh/identity" "$_o/wallpapers/wallpaper-1-1920x1080.png" "$_sh/backgrounds/wallpaper.png" ) > /dev/null \
		|| die 'scripts/identity-stamp.sh of the artwork pack cannot stamp the wallpaper (it needs ImageMagick)'
	rm -f "$_sh/backgrounds/wallpaper.svg"
	# the login banner of getty: the im= of the default entry of gettytab(5)
	# (brand-getty puts it in place), with the name of the product
	_im=$(sed -n 's/^[[:space:]]*:im=\(.*\):[[:space:]]*$/\1/p' "$_o/console/gettytab.fragment" | head -n 1)
	[ -n "$_im" ] || die 'the artwork pack has no im= in console/gettytab.fragment'
	_pn=$(sed -n 's/^NAME=//p' "$_pr/palette.env" | tr -d '"' | head -n 1)
	mkdir -p "$_sh/console"
	printf '%s\n' "$_im" | sed "s|${_pn:-ExampleBSD}|$DISTRO_NAME|g" > "$_sh/console/gettytab.im" \
		|| die 'cannot install the login banner'
	# the Xfce theme: the panel, the settings, the colours of the window
	# titles and of GTK; desktop-defaults gives them to the first session
	# of an account (the package owns the files under /etc/xdg)
	mkdir -p "$_sh/xfce"
	cp "$_o/xfce/xfconf/xfce4-panel.xml" "$_o/xfce/xfconf/xsettings.xml" "$_o/xfce/xfwm4-themerc" \
		"$_o/xfce/gtk-colors.css" "$_sh/xfce/" || die 'cannot install the Xfce theme'
	sed -i.bak "s/\"$_ps-menu\"/\"$_sl-menu\"/; s/\"${_pn:-ExampleBSD}\"/\"$DISTRO_NAME\"/" "$_sh/xfce/xfce4-panel.xml" \
		&& rm -f "$_sh/xfce/xfce4-panel.xml.bak" || die 'cannot install the Xfce panel'
	# the icons of the menu, the installer and the distributor
	for _i in logo menu installer; do
		for _d in 48x48 scalable; do
			_e=png
			[ "$_d" = scalable ] && _e=svg
			mkdir -p "$_st/usr/local/share/icons/hicolor/$_d/apps"
			cp "$_o/icons/hicolor/$_d/apps/$_ps-$_i.$_e" "$_st/usr/local/share/icons/hicolor/$_d/apps/$_sl-$_i.$_e" \
				|| die "cannot install the icon $_ps-$_i.$_e"
		done
	done
	rm -f "$OUT/.stage/spots.list"
	# the wallpaper helper of the session is installed from the pack: the
	# pack is kept for the live set (install_wallpaper runs after the
	# mode pass of the stage)
	ARTWORK_PACK_ROOT=$_pr
}

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
		if [ "$_p" = desktop ]; then
			log "    + write $_od/live$SITENUM.tgz (the live set: $(installer_source))"
			log "    + artwork: $(artwork_source)"
		fi
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

	# The identity of the image (one generated file, read by the greeter,
	# the desktop and the installer): KEY=value lines, and the line shown
	# in the lower left corner. BASE is the release of the build (-r); the
	# media helper checks it against the version string of the kernel it
	# puts in the image and refuses a disagreement.
	mkdir -p "$_stage/usr/local/share/@SLUG@"
	{
		printf 'PRODUCT=%s\n' "$DISTRO_NAME"
		printf 'VERSION=%s\n' "$PRODUCT_VERSION"
		printf 'BASE=OpenBSD %s\n' "$RELEASE"
		printf 'VARIANT=%s\n' "$ID_VARIANT"
		printf 'ARCH=%s\n' "$DISTRO_ARCH"
		printf 'BUILD=%s\n' "$ID_BUILD"
	} > "$_stage/usr/local/share/@SLUG@/identity"
	printf '%s\n' "$IDENTITY_LINE" > "$_stage/usr/local/share/@SLUG@/identity-line"
	# the same line with the ASCII separator of the artwork template (" | "),
	# for text that is not drawn in UTF-8 (xmessage on the greeter)
	_md=$(printf '\302\267')
	printf '%s\n' "$IDENTITY_LINE" | sed "s/ $_md / | /g" > "$_stage/usr/local/share/@SLUG@/identity-line.ascii"

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

	# The branding spots of OpenBSD from the pack of the artwork template
	# (after the substitution: a pack holds images sed must not touch).
	if [ "$_p" = desktop ] && [ -n "$ARTWORK_PACK$ARTWORK_DIR$ARTWORK_REF" ]; then
		install_artwork "$_stage"
	fi

	# --- modes -------------------------------------------------------------
	find "$_stage" -type d -exec chmod 0755 {} +
	find "$_stage" -type f -exec chmod 0644 {} +
	chmod 0755 "$_stage/install.site"
	# the rc.d scripts and the programs of the overlay are executable
	find "$_stage" -type f \( -path "$_stage/etc/rc.d/*" -o -path "$_stage/usr/local/libexec/*" \) \
		-exec chmod 0755 {} +
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
	# the wallpaper helper of the artwork pack: the autostart entry and
	# the script it runs (after the mode pass, so the modes of the two
	# files are the ones install_wallpaper sets)
	if [ "$_p" = desktop ] && [ -n "$ARTWORK_PACK_ROOT" ]; then
		install_wallpaper "$_stage" "$ARTWORK_PACK_ROOT"
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
	# The answers of the template are read into a file of their own
	# first: a template that is broken is refused, and the error of the
	# reader is not swallowed by the pipeline of the substitutions.
	_conf="$_od/.install.conf.raw"
	if ! ( umask 077
		conf_for_profile "$ROOT/autoinstall/install.conf.template" "$_p" "$NETMODE" > "$_conf" ); then
		rm -f "$_conf"
		die "the response file template of the profile $_p is not valid (see the message above)"
	fi
	( umask 077
	  sed -e 's/[[:space:]]*#.*$//' \
	    -e 's/^[[:space:]]*//' \
	    -e 's/[[:space:]]*$//' \
	    "$_conf" \
	| grep -v '^$' \
	| sed -f "$SUBFILE" \
	| sed -f "$PWPROG" > "$_od/install.conf" )
	rm -f "$_conf"
	log "    + $_od/install.conf"

	# The redacted copy of the response file: the value of the password
	# of the operator account is replaced by <redacted>. It is the copy
	# the CI archives: a build artefact must not carry a secret.
	( umask 022
	  sed -e 's|^\(Password for user[[:space:]]*=[[:space:]]*\).*$|\1<redacted>|' \
		"$_od/install.conf" > "$_od/install.conf.redacted" )
	log "    + $_od/install.conf.redacted"

	# --- the live set (desktop) ---------------------------------------------
	if [ "$_p" = desktop ]; then
		build_live "$_od"
	fi

	# --- checksums ---------------------------------------------------------
	# The checksums are the ones of the artefacts that leave the build:
	# the site set, the live set and the redacted response file.
	( cd "$_od" && sha256_line "site$SITENUM.tgz" \
		&& { [ ! -f "live$SITENUM.tgz" ] || sha256_line "live$SITENUM.tgz"; } \
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
