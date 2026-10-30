#!/bin/sh
#
# tests/run-tests.sh — the test suite of this template.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Runs on any POSIX host (Linux, the BSDs): no root, no network, no
# hypervisor. The VM tests drive a fake provider (tests/fixtures), so no
# real machine is started.
#
# usage: tests/run-tests.sh
#
# Environment:
#   WTFBSD_REPO   the repository to test (default: the parent of this
#                 directory). Point it at a copy to test a variant.

set -u

repo=${WTFBSD_REPO:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
work=$(mktemp -d "${TMPDIR:-/tmp}/wtfbsd-obsd-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT HUP INT TERM
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

BUILD="$repo/build.sh"
VM="$repo/ci/vm.sh"
BOOTTEST="$repo/tests/boot-test.sh"
CONF="$repo/tests/fixtures/openbsd-product.conf"
JF="$repo/Jenkinsfile"

# The public key of the operator account. The type and the key material are
# written apart, so this file does not hold the shape of a public key: the
# leak check of the repository would find it in the source of the check.
write_key() { # write_key <file> [type]
	printf '%s %s %s\n' "${2:-ssh-ed25519}" \
		'AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialForTheTestOnly' \
		'operator@example.org' > "$1"
}

# The operator account and its public key are required inputs of the build:
# the site set is key-only, so without them nobody could log in.
KEYFILE="$work/operator.pub"
write_key "$KEYFILE"

# The bcrypt hash of the password of the operator account. It is a test
# value: it is the hash of no password, and it is written to a file of its
# own, so the build never sees a hash on its command line.
HASH='$2b$12$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0'
PWFILE="$work/password.hash"
write_hash() { # write_hash <file> [hash]
	printf '%s\n' "${2:-$HASH}" > "$1"
}
write_hash "$PWFILE"

# build <outdir> [args...] — the build, with the operator account and its
# public key, so the suite exercises the path a real build takes.
build() {
	_out=$1
	shift
	sh "$BUILD" -c "$CONF" -u operator -k "$KEYFILE" -o "$_out" "$@"
}

# jenkins_sh_with <pattern> — the shell of the sh block of the Jenkinsfile
# that holds the pattern. The block is extracted, not read: the stage is
# then run the way the pipeline runs it.
jenkins_sh_with() {
	sed "s/'''/@QQ@/g" "$JF" | awk -v pat="$1" '
		/sh @QQ@/ { c++; keep = 0; buf = ""; next }
		/^[[:space:]]*@QQ@[[:space:]]*$/ {
			if (buf ~ pat) { printf "%s", buf; exit }
			next
		}
		{ if (c > 0) buf = buf $0 "\n" }
	'
}

# The leak check looks for the SHAPES of the things that must not reach
# a public repository: an address, a mail address, a host name in an
# internal top level domain, a key and a token.
#
# The name of an organisation is NOT in this file: a list that named it
# would publish it. A private list is named by the environment variable
# $WTFBSD_DENYLIST and the repository ships none.
#
# Every alternative is written with a split word, so this file does not
# hold the strings it looks for. Only the first segment may be double
# quoted: inside double quotes the quotes of a split word would survive
# and the pattern would match this file.

# a dotted quad address
_PAT='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
# an address of the version 6: the full form, the compressed form and
# the unspecified address
_PAT="$_PAT"'|([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}'
_PAT="$_PAT"'|([0-9A-Fa-f]{1,4}:){1,7}:([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}'
_PAT="$_PAT"'|:'':''([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{0,4}'
# a mail address
_PAT="$_PAT"'|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# a host name in an internal top level domain
_PAT="$_PAT"'|[A-Za-z0-9][A-Za-z0-9.-]*\.(lan|corp|internal|local|lab)'
# the header of a private key, and the first field of a public key
_PAT="$_PAT"'|BEGIN .*PRIV''ATE KEY|ssh-(ed25519|rsa) AAAA'
# the prefixes of the tokens of the services that hand them out
_PAT="$_PAT"'|gh''p_|gh''o_|github_''pat_|AKIA[0-9A-Z]{16}|xox[abp]-''|sk-[A-Za-z0-9]{20,}'
# the names of the fields of a credential
_PAT="$_PAT"'|api''Key|api_''key|base''URL|Bear''er'

# The matches that are allowed, whole matches only:
#   127.0.0.1 and ::1              the placeholders of the loopback address
#   0.0.0.0                        the unspecified address, never a host
#   192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24   the documentation ranges
#   2001:db8 and 2001:0db8        the documentation range of the version 6
#   example.org and example.com   the domain of the documentation
#   rc.conf.local                 the name of the daemon configuration file
#   a netmask (255.255.255.0)      the mask of a network, not an address:
#                                  a contiguous mask only, the same masks
#                                  the netmask() of build.sh accepts
# An address that only starts like a placeholder is not allowed: the
# whole match has to be the placeholder itself.
_OK='127\.0\.0\.1|::1|0\.0\.0\.0|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}'
_OK="$_OK"'|2001:(0?db8):[0-9a-f]{0,4}(:[0-9a-f]{0,4}){0,7}'
_OK="$_OK"'|[A-Za-z0-9._%+-]+@example\.(org|com)|rc\.conf\.local'
# The netmasks of the allow-list are the contiguous ones only: a run of
# one bits followed by a run of zero bits, the same masks the netmask()
# of build.sh accepts (255.255.255.0, 255.255.255.128, 255.255.0.0,
# 255.128.0.0 and so on). A mask with a hole is not a mask, and it is
# caught like an address.
_OK="$_OK"'|255\.255\.255\.(0|128|192|224|240|248|252|254|255)'
_OK="$_OK"'|255\.255\.(0|128|192|224|240|248|252|254)\.0'
_OK="$_OK"'|255\.(0|128|192|224|240|248|252|254)\.0\.0'

# mkconf <name> <sed-expression...> — a product.conf derived from the
# fixture, so every fixture is a real product.conf (the format of
# wtfbsd/agents scripts/apply-answers.sh).
mkconf() {
	_name=$1
	shift
	sed "$@" "$CONF" > "$work/$_name.conf"
}

# leak_files <root> — writes the files of the repository into the list
# file, NUL separated: the tracked ones and the untracked ones that are
# not ignored. A file whose name holds a space is scanned as well.
leak_files() {
	( cd "$1" && git ls-files -z --cached --others --exclude-standard 2> /dev/null ) \
		> "$work/.leak-files" 2> /dev/null
	if [ ! -s "$work/.leak-files" ]; then
		( cd "$1" && find . -type f -not -path './.git/*' -print0 ) \
			> "$work/.leak-files" 2> /dev/null
	fi
}

# scan_generic_refs <root> — prints the files that hold a shape that must
# not reach a public repository: an address that is not a placeholder, a
# mail address that is not one of the documentation domains, a host name
# in an internal top level domain, a key or a token. The round reports of
# a working session are not shipped files (they are ignored, and the
# suite fails when one of them is tracked) and are not scanned: they
# quote what other systems reported back.
scan_generic_refs() {
	leak_files "$1"
	[ -s "$work/.leak-files" ] || return 0
	( cd "$1" && xargs -0 grep -H -E -o -i "$_PAT" < "$work/.leak-files" 2> /dev/null ) \
		| grep -E -v "^[^:]*:($_OK)$" \
		| sed 's/^\([^:]*\):.*/\1/' \
		| sort -u
}

# scan_denylist_refs <root> <list> — prints the files that hold a string
# of the private deny-list. The list is optional: when the variable is
# unset, or names a file that cannot be read, the private check does
# nothing. Every line of the list that is not empty and not a comment is
# an extended regular expression, matched case insensitively against
# every file of the repository.
scan_denylist_refs() {
	_dl_list=$2
	[ -n "$_dl_list" ] || return 0
	[ -f "$_dl_list" ] && [ -r "$_dl_list" ] || return 0
	leak_files "$1"
	[ -s "$work/.leak-files" ] || return 0
	while IFS= read -r _dl_re || [ -n "$_dl_re" ]; do
		case $_dl_re in
		'' | '#'*) continue ;;
		esac
		( cd "$1" && xargs -0 grep -E -i -l -e "$_dl_re" < "$work/.leak-files" 2> /dev/null )
	done < "$_dl_list"
}

printf '== build.sh: the site set ==\n'

# (a) a valid product.conf builds the site set
rm -rf "$work/out"
if build "$work/out" -r 7.8 > "$work/build.log" 2>&1; then
	ok 'valid product.conf builds'
else
	no "valid product.conf builds (see $work/build.log)"
fi
[ -f "$work/out/site78.tgz" ] && ok 'site78.tgz is written' || no 'site78.tgz is written'
[ -f "$work/out/install.conf" ] && ok 'install.conf is written' || no 'install.conf is written'
[ -f "$work/out/SHA256" ] && ok 'SHA256 is written' || no 'SHA256 is written'
[ "$(wc -l < "$work/out/SHA256" 2> /dev/null || echo 0)" = 2 ] \
	&& ok 'SHA256 lists both artifacts' || no 'SHA256 lists both artifacts'

rm -rf "$work/x"
mkdir -p "$work/x"
( cd "$work/x" && tar xzf "$work/out/site78.tgz" ) > "$work/untar.log" 2>&1
[ -f "$work/x/install.site" ] && ok 'the site set holds install.site' || no 'the site set holds install.site'
[ -f "$work/x/etc/motd" ] && ok 'the site set holds the motd' || no 'the site set holds the motd'
[ -x "$work/x/install.site" ] && ok 'install.site is executable' || no 'install.site is executable'
grep -q 'ExampleBSD' "$work/x/etc/motd" 2> /dev/null \
	&& ok 'the motd carries the substituted name' || no 'the motd carries the substituted name'
if grep -rq '@DISTRO_NAME@' "$work/x" 2> /dev/null; then
	no 'no literal @DISTRO_NAME@ is left in the site set'
else
	ok 'no literal @DISTRO_NAME@ is left in the site set'
fi
grep -q '^System hostname = examplebsd$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'install.conf sets the hostname' || no 'install.conf sets the hostname'
# the site set is not in the SHA256.sig of the release: the installer has
# to be told to continue without the verification
grep -q '^Continue without verification = yes$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'install.conf continues without the verification' \
	|| no 'install.conf continues without the verification'
grep -q '^Set name(s) = +site\*$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'install.conf selects the site set' || no 'install.conf selects the site set'
if grep -q 'SHA256.sig' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents that the site set is not signed'
else
	no 'the README documents that the site set is not signed'
fi
grep -q '^#' "$work/out/install.conf" 2> /dev/null \
	&& no 'install.conf holds answers only' || ok 'install.conf holds answers only'
[ -f "$work/x/usr/local/share/examplebsd/packages.list" ] \
	&& ok 'the site set holds the merged package list' || no 'the site set holds the merged package list'

# the site set holds a FILE LIST only: a directory entry would hand the
# owner and the mode of the staged directory to /etc, /usr and the rest of
# the new root when the installer unpacks the archive over it
_tarlist="$work/tarlist"
tar tvzf "$work/out/site78.tgz" > "$_tarlist" 2> /dev/null
if grep -q '^d' "$_tarlist" 2> /dev/null; then
	no 'the site set holds no directory entry'
else
	ok 'the site set holds no directory entry'
fi
if grep -v '^-' "$_tarlist" 2> /dev/null | grep -q .; then
	no 'the site set holds regular files only'
else
	ok 'the site set holds regular files only'
fi
if grep -v -E '(^| )(0/0|root/root)( |$)' "$_tarlist" 2> /dev/null | grep -q .; then
	no 'every member of the site set is owned by root'
else
	ok 'every member of the site set is owned by root'
fi
_member_mode() { # _member_mode <listing> <name> — the mode of a member of the archive
	awk -v n="$2" '
		function bits(t,   v, i, c) {
			v = 0
			for (i = 1; i <= 3; i++) {
				c = substr(t, i, 1)
				if (c == "r") v += 4
				else if (c == "w") v += 2
				else if (c == "x" || c == "s" || c == "t") v += 1
			}
			return v
		}
		$NF == n {
			m = substr($1, 2)
			print bits(substr(m, 1, 3)) * 100 + bits(substr(m, 4, 3)) * 10 + bits(substr(m, 7, 3))
		}
	' "$1"
}
[ "$(_member_mode "$_tarlist" install.site)" = 755 ] \
	&& ok 'install.site is 0755 in the site set' || no 'install.site is 0755 in the site set'
[ "$(_member_mode "$_tarlist" etc/motd)" = 644 ] \
	&& ok 'the motd is 0644 in the site set' || no 'the motd is 0644 in the site set'
[ -f "$work/x/etc/ssh/sshd_config" ] \
	&& ok 'the appliance profile hardens sshd' || no 'the appliance profile hardens sshd'
# The installer writes the com0 lines of /etc/boot.conf itself when
# the response file answers the console of the appliance, so the site set
# ships no boot.conf at all. OpenBSD reads /etc/boot.conf, not
# /boot/boot.conf.
[ ! -e "$work/x/etc/boot.conf" ] \
	&& ok 'the appliance profile ships no /etc/boot.conf' || no 'the appliance profile ships no /etc/boot.conf'
[ ! -e "$work/x/boot/boot.conf" ] \
	&& ok 'the site set holds no /boot/boot.conf' || no 'the site set holds no /boot/boot.conf'
if grep -rl 'com0' "$work/x" 2> /dev/null | grep -q .; then
	no 'the site set holds no com0 line'
else
	ok 'the site set holds no com0 line'
fi
grep -q '^Change the default console to com0 = yes$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'the response file answers the console of the appliance' \
	|| no 'the response file answers the console of the appliance'
grep -q '^Which speed should com0 use = 115200$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'the response file answers the speed of the console' \
	|| no 'the response file answers the speed of the console'

# (b) ZFS is refused, with the reason
mkconf zfs "s|^FILESYSTEM_ROOT=.*|FILESYSTEM_ROOT='zfs'|"
if sh "$BUILD" -n -c "$work/zfs.conf" -o "$work/out-zfs" -u operator -k "$KEYFILE" > "$work/zfs.log" 2>&1; then
	no 'FILESYSTEM_ROOT=zfs is refused'
else
	ok 'FILESYSTEM_ROOT=zfs is refused'
fi
grep -q 'No ZFS at all. FFS is the only filesystem choice.' "$work/zfs.log" 2> /dev/null \
	&& ok 'the zfs refusal gives the reason' || no 'the zfs refusal gives the reason'

mkconf pool "s|^ZFS_DATA_POOL=.*|ZFS_DATA_POOL='yes'|"
if sh "$BUILD" -n -c "$work/pool.conf" -o "$work/out-pool" -u operator -k "$KEYFILE" > "$work/pool.log" 2>&1; then
	no 'ZFS_DATA_POOL=yes is refused'
else
	ok 'ZFS_DATA_POOL=yes is refused'
fi
grep -q 'No ZFS at all. FFS is the only filesystem choice.' "$work/pool.log" 2> /dev/null \
	&& ok 'the zfs pool refusal gives the reason' || no 'the zfs pool refusal gives the reason'

# (c) another base system is refused
mkconf otheros "s|^DISTRO_OS=.*|DISTRO_OS='netbsd'|"
if sh "$BUILD" -n -c "$work/otheros.conf" -o "$work/out-os" -u operator -k "$KEYFILE" > "$work/os.log" 2>&1; then
	no 'DISTRO_OS=netbsd is refused'
else
	ok 'DISTRO_OS=netbsd is refused'
fi
grep -q 'DISTRO_OS must be openbsd' "$work/os.log" 2> /dev/null \
	&& ok 'the wrong base system is named' || no 'the wrong base system is named'

# (d) product.conf is data, never code
mkconf inj "s|^MOTD=.*|MOTD='x\$(touch $work/pwned)'|"
if sh "$BUILD" -n -c "$work/inj.conf" -o "$work/out-inj" -u operator -k "$KEYFILE" > "$work/inj.log" 2>&1; then
	no 'a command substitution in MOTD is refused'
else
	ok 'a command substitution in MOTD is refused'
fi
[ ! -e "$work/pwned" ] && ok 'product.conf is not executed' || no 'product.conf is not executed'

# (e) the release must be N.N
for _bad in 7 7.8.1 abc 7.8x ''; do
	if sh "$BUILD" -n -c "$CONF" -r "$_bad" -o "$work/out-r" -u operator -k "$KEYFILE" > "$work/r.log" 2>&1; then
		no "release '$_bad' is refused"
	else
		ok "release '$_bad' is refused"
	fi
done

# (f) the mt76 rule
if grep -rna 'mt76' "$repo/overlay" > "$work/mt76.log" 2>&1; then
	no 'no overlay file mentions mt76'
else
	ok 'no overlay file mentions mt76'
fi

# (g) the site set is named after the release without the dot
rm -rf "$work/out78" "$work/out710"
build "$work/out78" -r 7.8 > "$work/b78.log" 2>&1
[ -f "$work/out78/site78.tgz" ] && ok '7.8 builds site78.tgz' || no '7.8 builds site78.tgz'

# the default release is 8.0: the dry run without -r plans the site set
# of that release
rm -rf "$work/out-default"
if sh "$BUILD" -n -c "$CONF" -o "$work/out-default" -u operator -k "$KEYFILE" > "$work/default.log" 2>&1; then
	ok 'the dry run without -r succeeds'
else
	no "the dry run without -r succeeds (see $work/default.log)"
fi
if grep -q 'site80\.tgz' "$work/default.log" 2> /dev/null; then
	ok 'the default release plans site80.tgz'
else
	no 'the default release plans site80.tgz'
fi
build "$work/out710" -r 7.10 > "$work/b710.log" 2>&1
[ -f "$work/out710/site710.tgz" ] && ok '7.10 builds site710.tgz' || no '7.10 builds site710.tgz'

# the desktop profile is a profile of its own. It needs the password of
# the operator account: the console is the only way in there.
rm -rf "$work/outd"
build "$work/outd" -r 7.8 -p desktop -P "$PWFILE" > "$work/bd.log" 2>&1
[ -f "$work/outd/site78.tgz" ] && ok 'the desktop profile builds a site set' || no 'the desktop profile builds a site set'
rm -rf "$work/xd"
mkdir -p "$work/xd"
( cd "$work/xd" && tar xzf "$work/outd/site78.tgz" ) > /dev/null 2>&1
[ -f "$work/xd/etc/skel/.xsession" ] \
	&& ok 'the desktop profile ships an X session' || no 'the desktop profile ships an X session'
# the desktop starts the X server with xenodm(1) and disables sshd, which
# OpenBSD enables by default
grep -q '^xenodm_flags=$' "$work/xd/etc/rc.conf.local" 2> /dev/null \
	&& ok 'the desktop profile starts xenodm' || no 'the desktop profile starts xenodm'
grep -q '^sshd_flags=NO$' "$work/xd/etc/rc.conf.local" 2> /dev/null \
	&& ok 'the desktop profile disables sshd' || no 'the desktop profile disables sshd'
grep -q '^Do you want the X Window System to be started by xenodm(1) = yes$' "$work/outd/install.conf" 2> /dev/null \
	&& ok 'the desktop response file starts xenodm' || no 'the desktop response file starts xenodm'
grep -q '^Start sshd(8) by default = no$' "$work/outd/install.conf" 2> /dev/null \
	&& ok 'the desktop response file disables sshd' || no 'the desktop response file disables sshd'
# the answer keys carry no question mark: autoinstall(8) names a question
# without it, and every other answer of the template follows that rule
if grep -q 'xenodm(1)? =' "$work/outd/install.conf" 2> /dev/null; then
	no 'the answer key of xenodm carries no question mark'
else
	ok 'the answer key of xenodm carries no question mark'
fi
if grep -q 'sshd(8) by default? =' "$work/outd/install.conf" 2> /dev/null; then
	no 'the answer key of sshd carries no question mark'
else
	ok 'the answer key of sshd carries no question mark'
fi
# the serial console belongs to the appliance: the desktop keeps the
# console of the machine it runs on
grep -q '^Change the default console to com0 = yes$' "$work/out/install.conf" 2> /dev/null \
	&& ok 'the appliance response file sets the serial console' \
	|| no 'the appliance response file sets the serial console'
if grep -q 'Change the default console to com0' "$work/outd/install.conf" 2> /dev/null; then
	no 'the desktop response file holds no console answer'
else
	ok 'the desktop response file holds no console answer'
fi
# the appliance does not answer the questions of the desktop
grep -q 'xenodm' "$work/out/install.conf" 2> /dev/null \
	&& no 'the appliance response file holds no desktop answer' \
	|| ok 'the appliance response file holds no desktop answer'
grep -q 'Start sshd(8) by default' "$work/out/install.conf" 2> /dev/null \
	&& no 'the appliance response file holds no sshd answer' \
	|| ok 'the appliance response file holds no sshd answer'
# the session of a new account is started with startx as well
[ -f "$work/xd/etc/skel/.xinitrc" ] \
	&& ok 'the desktop profile ships an .xinitrc' || no 'the desktop profile ships an .xinitrc'
[ -x "$work/xd/etc/skel/.xsession" ] \
	&& ok 'the .xsession is executable' || no 'the .xsession is executable'
[ -x "$work/xd/etc/skel/.xinitrc" ] \
	&& ok 'the .xinitrc is executable' || no 'the .xinitrc is executable'
# the modes in the archive of the desktop profile
_tarlistd="$work/tarlist-desktop"
tar tvzf "$work/outd/site78.tgz" > "$_tarlistd" 2> /dev/null
[ "$(_member_mode "$_tarlistd" etc/skel/.xinitrc)" = 755 ] \
	&& ok 'the .xinitrc is 0755 in the site set' || no 'the .xinitrc is 0755 in the site set'
[ "$(_member_mode "$_tarlistd" etc/skel/.xsession)" = 755 ] \
	&& ok 'the .xsession is 0755 in the site set' || no 'the .xsession is 0755 in the site set'
grep -q 'startxfce4' "$work/xd/etc/skel/.xinitrc" 2> /dev/null \
	&& ok 'the .xinitrc starts the Xfce session' || no 'the .xinitrc starts the Xfce session'
[ ! -f "$work/xd/etc/ssh/sshd_config" ] \
	&& ok 'the desktop profile does not ship the appliance sshd_config' || no 'the desktop profile does not ship the appliance sshd_config'

# both profiles build two site sets
rm -rf "$work/outb"
build "$work/outb" -r 7.8 -p both -P "$PWFILE" > "$work/bb.log" 2>&1
[ -f "$work/outb/appliance/site78.tgz" ] && [ -f "$work/outb/desktop/site78.tgz" ] \
	&& ok 'both profiles build two site sets' || no 'both profiles build two site sets'

# a dry run writes nothing
rm -rf "$work/outn"
sh "$BUILD" -n -c "$CONF" -r 7.8 -o "$work/outn" -u operator -k "$KEYFILE" > "$work/bn.log" 2>&1
[ ! -e "$work/outn" ] && ok 'a dry run writes nothing' || no 'a dry run writes nothing'

# the base system is only built on OpenBSD
if [ "$(uname -s)" = OpenBSD ]; then
	ok 'the release(8) path is available on OpenBSD'
else
	if WTFBSD_BUILD_BASE=yes sh "$BUILD" -n -c "$CONF" -o "$work/out-base" -u operator -k "$KEYFILE" > "$work/base.log" 2>&1; then
		no 'the release(8) path is refused off OpenBSD'
	else
		ok 'the release(8) path is refused off OpenBSD'
	fi
	grep -q 'release(8) cannot be cross-built' "$work/base.log" 2> /dev/null \
		&& ok 'the refusal says the base system needs OpenBSD' || no 'the refusal says the base system needs OpenBSD'
fi

# the site set has to be owned by root: the tar(1) of OpenBSD has no owner
# override, so the build has to run as root there
if [ "$(id -u)" = 0 ]; then
	printf 'SKIP  a build without root is refused on OpenBSD (running as root)\n'
else
	rm -rf "$work/fakebin" "$work/out-osbsd"
	mkdir -p "$work/fakebin"
	# a tar that is not the GNU one, and a uname that says OpenBSD
	printf '#!/bin/sh\nexit 0\n' > "$work/fakebin/tar"
	printf '#!/bin/sh\nif [ "$1" = -s ]; then echo OpenBSD; exit 0; fi\nexec /usr/bin/uname "$@"\n' > "$work/fakebin/uname"
	chmod +x "$work/fakebin/tar" "$work/fakebin/uname"
	if PATH="$work/fakebin:$PATH" sh "$BUILD" -c "$CONF" -u operator -k "$KEYFILE" -o "$work/out-osbsd" > "$work/osbsd.log" 2>&1; then
		no 'a build without root is refused on OpenBSD'
	else
		ok 'a build without root is refused on OpenBSD'
	fi
	grep -qi 'has to run as root' "$work/osbsd.log" 2> /dev/null \
		&& ok 'the refusal names root' || no 'the refusal names root'
	[ ! -e "$work/out-osbsd" ] && ok 'the refused build wrote nothing' || no 'the refused build wrote nothing'
fi

# the note about a build without root was unreachable: the build refuses
# to run as another user on OpenBSD, so the note could never be printed
if grep -q 'keep your uid' "$repo/build.sh" 2> /dev/null; then
	no 'build.sh holds no unreachable note about a build without root'
else
	ok 'build.sh holds no unreachable note about a build without root'
fi

printf '== the tar of OpenBSD ==\n'

# The tar(1) of OpenBSD reads the list of the files with -I; the GNU tar
# and the bsdtar use -T. A fake tar records its arguments, a fake uname
# says that the host is OpenBSD, and a fake id(1) says that the build
# runs as root (the tar of OpenBSD has no owner override, so the build
# refuses to run as another user).
rm -rf "$work/fakebin-osbd" "$work/out-osbdtar"
mkdir -p "$work/fakebin-osbd"
cat > "$work/fakebin-osbd/tar" <<'FAKETAR'
#!/bin/sh
# the fake tar: it records its arguments and creates the archive
printf '%s\n' "$*" >> "$WTFBSD_FAKE_TAR_LOG"
_archive=''
_prev=''
for _a in "$@"; do
	case $_prev in
	czf | -f | --file) _archive=$_a ;;
	esac
	_prev=$_a
done
[ -n "$_archive" ] && : > "$_archive"
exit 0
FAKETAR
printf '#!/bin/sh\nif [ "$1" = -s ]; then echo OpenBSD; exit 0; fi\nexec /usr/bin/uname "$@"\n' \
	> "$work/fakebin-osbd/uname"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' \
	> "$work/fakebin-osbd/id"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin-osbd/chown"
chmod +x "$work/fakebin-osbd/tar" "$work/fakebin-osbd/uname" \
	"$work/fakebin-osbd/id" "$work/fakebin-osbd/chown"
if WTFBSD_FAKE_TAR_LOG="$work/tar.argv" PATH="$work/fakebin-osbd:$PATH" \
	sh "$BUILD" -c "$CONF" -r 7.8 -o "$work/out-osbdtar" \
	-u operator -k "$KEYFILE" > "$work/osbdtar.log" 2>&1; then
	ok 'the build runs with the tar of OpenBSD'
else
	no "the build runs with the tar of OpenBSD (see $work/osbdtar.log)"
fi
if grep -q -- '-I ' "$work/tar.argv" 2> /dev/null; then
	ok 'the tar of OpenBSD reads the list of the files with -I'
else
	no 'the tar of OpenBSD reads the list of the files with -I'
fi
if grep -q -- '-T ' "$work/tar.argv" 2> /dev/null; then
	no 'the tar of OpenBSD does not read the list of the files with -T'
else
	ok 'the tar of OpenBSD does not read the list of the files with -T'
fi

printf '== the login path: an account and a key are required ==\n'

# (l) the site set is key-only: without an operator account and its public
# key nobody could log in, so both are required inputs of the build.

# without the key the build refuses
rm -rf "$work/out-nokey"
if sh "$BUILD" -c "$CONF" -r 7.8 -o "$work/out-nokey" > "$work/nokey.log" 2>&1; then
	no 'a build without a public key is refused'
else
	ok 'a build without a public key is refused'
fi
grep -q 'PUBKEYFILE' "$work/nokey.log" 2> /dev/null \
	&& ok 'the refusal names the missing key input' || no 'the refusal names the missing key input'
[ ! -e "$work/out-nokey" ] && ok 'the refused build wrote nothing' || no 'the refused build wrote nothing'

# with the key but without the account the build refuses
rm -rf "$work/out-nouser"
if sh "$BUILD" -c "$CONF" -r 7.8 -o "$work/out-nouser" -k "$KEYFILE" > "$work/nouser.log" 2>&1; then
	no 'a build without an operator account is refused'
else
	ok 'a build without an operator account is refused'
fi
grep -q 'USER' "$work/nouser.log" 2> /dev/null \
	&& ok 'the refusal names the missing account input' || no 'the refusal names the missing account input'

# a dry run reports the missing input and writes nothing
rm -rf "$work/out-dry"
if sh "$BUILD" -n -c "$CONF" -r 7.8 -o "$work/out-dry" > "$work/dry.log" 2>&1; then
	ok 'a dry run without a key reports the missing input'
else
	no 'a dry run without a key reports the missing input'
fi
grep -q 'PUBKEYFILE' "$work/dry.log" 2> /dev/null \
	&& ok 'the dry run names the missing key input' || no 'the dry run names the missing key input'
[ ! -e "$work/out-dry" ] && ok 'the dry run wrote nothing' || no 'the dry run wrote nothing'

# with both the build succeeds and the response file holds the two answers
rm -rf "$work/out-key"
if build "$work/out-key" -r 7.8 > "$work/key.log" 2>&1; then
	ok 'a build with an account and a key succeeds'
else
	no 'a build with an account and a key succeeds'
fi
grep -q '^Setup a user = operator$' "$work/out-key/install.conf" 2> /dev/null \
	&& ok 'install.conf sets up the operator account' || no 'install.conf sets up the operator account'
grep -q '^Public ssh key for user = ssh-ed25519 ' "$work/out-key/install.conf" 2> /dev/null \
	&& ok 'install.conf holds the public key of the operator' \
	|| no 'install.conf holds the public key of the operator'

# an account name that is not a user name is refused
if sh "$BUILD" -n -c "$CONF" -u 'Operator 1' -k "$KEYFILE" > "$work/baduser.log" 2>&1; then
	no 'an operator name that is not a user name is refused'
else
	ok 'an operator name that is not a user name is refused'
fi

# a key of a type the installer does not take is refused
write_key "$work/bad.pub" ssh-dss
if sh "$BUILD" -n -c "$CONF" -u operator -k "$work/bad.pub" > "$work/badkey.log" 2>&1; then
	no 'a public key of an unsupported type is refused'
else
	ok 'a public key of an unsupported type is refused'
fi

# a key type that is only the beginning of a supported type is refused:
# the first field of the line is matched exactly, not as a prefix
write_key "$work/prefix.pub" ssh-ed25519x
if sh "$BUILD" -n -c "$CONF" -u operator -k "$work/prefix.pub" > "$work/prefixkey.log" 2>&1; then
	no 'a public key of a type that is only a prefix of a supported type is refused'
else
	ok 'a public key of a type that is only a prefix of a supported type is refused'
fi

# a security key type without its domain is refused: the whole first field
# has to be one of the supported types
write_key "$work/skbare.pub" sk-ssh-ed25519
if sh "$BUILD" -n -c "$CONF" -u operator -k "$work/skbare.pub" > "$work/skbare.log" 2>&1; then
	no 'a security key type without its domain is refused'
else
	ok 'a security key type without its domain is refused'
fi

# the security key types carry the domain of OpenSSH, which has the shape
# of a mail address: the domain is kept in a variable, so that this file
# does not hold the shape of a mail address
SKDOMAIN=openssh.com
write_key "$work/sk.pub" "sk-ssh-ed25519@$SKDOMAIN"
if sh "$BUILD" -n -c "$CONF" -u operator -k "$work/sk.pub" > "$work/skkey.log" 2>&1; then
	ok 'a public key of a supported security key type is accepted'
else
	no 'a public key of a supported security key type is accepted'
fi

# a refused key file is never echoed: the refusal names the check and the
# file, never the contents of the file
write_key "$work/leak.pub" ssh-dss
for _f in leak prefix; do
	sh "$BUILD" -n -c "$CONF" -u operator -k "$work/$_f.pub" \
		> "$work/$_f.out" 2> "$work/$_f.err"
	if grep -q 'ExampleKeyMaterialForTheTestOnly' "$work/$_f.err" "$work/$_f.out" 2> /dev/null; then
		no "a refused key file is not echoed ($_f)"
	else
		ok "a refused key file is not echoed ($_f)"
	fi
done

# the same holds for a key line whose material is not a key: the line is
# not echoed either
printf '%s %s %s\n' ssh-ed25519 'not!base64!' 'operator@example.org' > "$work/badmat.pub"
sh "$BUILD" -n -c "$CONF" -u operator -k "$work/badmat.pub" \
	> "$work/badmat.out" 2> "$work/badmat.err"
if grep -q 'not!base64!' "$work/badmat.err" "$work/badmat.out" 2> /dev/null; then
	no 'a refused key line is not echoed'
else
	ok 'a refused key line is not echoed'
fi

# a key file without a key is refused
: > "$work/empty.pub"
if sh "$BUILD" -n -c "$CONF" -u operator -k "$work/empty.pub" > "$work/emptykey.log" 2>&1; then
	no 'a public key file without a key is refused'
else
	ok 'a public key file without a key is refused'
fi

# the CI hands the account and the key to the build
if grep -q 'OPERATOR_PUBKEY' "$JF" && grep -q 'OPERATOR_USER' "$JF"; then
	ok 'the Jenkinsfile takes the operator account and its key'
else
	no 'the Jenkinsfile takes the operator account and its key'
fi
if grep -q -- '-u "$OPERATOR_USER"' "$JF" && grep -q -- '-k "$OPERATOR_PUBKEY"' "$JF"; then
	ok 'the Jenkinsfile hands the account and the key to build.sh'
else
	no 'the Jenkinsfile hands the account and the key to build.sh'
fi

# the desktop profile needs the password hash, so the CI has to take it
# and hand it to the build
if grep -q 'OPERATOR_PASSWORD_HASH' "$JF"; then
	ok 'the Jenkinsfile takes the password hash of the operator account'
else
	no 'the Jenkinsfile takes the password hash of the operator account'
fi
if grep -q -- '-P "$OPERATOR_PASSWORD_HASH"' "$JF"; then
	ok 'the Jenkinsfile hands the password hash to build.sh'
else
	no 'the Jenkinsfile hands the password hash to build.sh'
fi
if grep -q 'PUBKEYFILE' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents the key input of the build'
else
	no 'the README documents the key input of the build'
fi

printf '== the password of the operator account ==\n'

# The desktop is a console system: sshd is disabled there, so the console
# is the only way in and the password of the operator account is a
# REQUIRED input of the build. The hash is read from a file, never from
# the command line, and it is never printed.

# without the hash the desktop build is refused
rm -rf "$work/out-dnopw"
if sh "$BUILD" -c "$CONF" -r 7.8 -p desktop -o "$work/out-dnopw" \
	-u operator -k "$KEYFILE" > "$work/dnopw.log" 2>&1; then
	no 'a desktop build without a password hash is refused'
else
	ok 'a desktop build without a password hash is refused'
fi
grep -q 'HASHFILE' "$work/dnopw.log" 2> /dev/null \
	&& ok 'the refusal names the missing password input' \
	|| no 'the refusal names the missing password input'
[ ! -e "$work/out-dnopw" ] && ok 'the refused desktop build wrote nothing' \
	|| no 'the refused desktop build wrote nothing'

# a dry run reports the missing input and writes nothing
rm -rf "$work/out-drypw"
if sh "$BUILD" -n -c "$CONF" -r 7.8 -p desktop -o "$work/out-drypw" \
	-u operator -k "$KEYFILE" > "$work/drypw.log" 2>&1; then
	ok 'a dry run of the desktop reports the missing password input'
else
	no 'a dry run of the desktop reports the missing password input'
fi
grep -q 'HASHFILE' "$work/drypw.log" 2> /dev/null \
	&& ok 'the dry run names the missing password input' \
	|| no 'the dry run names the missing password input'

# with the hash the desktop builds, and the response file holds it
rm -rf "$work/out-dpw"
if sh "$BUILD" -c "$CONF" -r 7.8 -p desktop -o "$work/out-dpw" \
	-u operator -k "$KEYFILE" -P "$PWFILE" > "$work/dpw.out" 2> "$work/dpw.err"; then
	ok 'a desktop build with a password hash succeeds'
else
	no 'a desktop build with a password hash succeeds'
fi
grep -q -F -x "Password for user = $HASH" "$work/out-dpw/install.conf" 2> /dev/null \
	&& ok 'the desktop response file holds the password hash' \
	|| no 'the desktop response file holds the password hash'

# the hash never appears in the output of the build
if grep -q -F "$HASH" "$work/dpw.out" "$work/dpw.err" 2> /dev/null; then
	no 'the password hash never appears in the output of the build'
else
	ok 'the password hash never appears in the output of the build'
fi

# the appliance is key-only: without a hash its response file holds the
# 13 asterisks that disable the password logins and keep the installer
# from stopping on the question
rm -rf "$work/out-apw"
build "$work/out-apw" -r 7.8 > "$work/apw.log" 2>&1
_ap=$(sed -n 's/^Password for user = //p' "$work/out-apw/install.conf" 2> /dev/null)
if [ "$_ap" = '*************' ]; then
	ok 'the appliance response file holds the 13 asterisks'
else
	no "the appliance response file holds the 13 asterisks (got: $_ap)"
fi

# the appliance takes the hash too, when there is one
rm -rf "$work/out-apw2"
build "$work/out-apw2" -r 7.8 -P "$PWFILE" > "$work/apw2.log" 2>&1
grep -q -F -x "Password for user = $HASH" "$work/out-apw2/install.conf" 2> /dev/null \
	&& ok 'the appliance response file holds the hash when there is one' \
	|| no 'the appliance response file holds the hash when there is one'

# a file that does not hold a bcrypt hash is refused, and the refusal
# does not print the hash
printf '%s\n' 'not-a-bcrypt-hash' > "$work/bad.hash"
if sh "$BUILD" -n -c "$CONF" -r 7.8 -p desktop -o "$work/out-badhash" \
	-u operator -k "$KEYFILE" -P "$work/bad.hash" > "$work/badhash.log" 2>&1; then
	no 'a password file that holds no bcrypt hash is refused'
else
	ok 'a password file that holds no bcrypt hash is refused'
fi
if grep -q -F 'not-a-bcrypt-hash' "$work/badhash.log" 2> /dev/null; then
	no 'the refusal of a bad hash does not print the hash'
else
	ok 'the refusal of a bad hash does not print the hash'
fi

# a password file that is not there is refused
if sh "$BUILD" -n -c "$CONF" -r 7.8 -p desktop -o "$work/out-nohash" \
	-u operator -k "$KEYFILE" -P "$work/nosuch.hash" > "$work/nohash.log" 2>&1; then
	no 'a missing password file is refused'
else
	ok 'a missing password file is refused'
fi

# the README documents the input
if grep -q 'HASHFILE' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents the password input of the build'
else
	no 'the README documents the password input of the build'
fi

printf '== the response file is a secret that is not archived ==\n'

# The response file holds the hash of the password of the operator
# account: it is a secret. It is written with a umask of 077, so it is
# readable by the builder alone, and the redacted copy of it is the one
# the CI archives.
_mode=$(stat -c '%a' "$work/out-dpw/install.conf" 2> /dev/null \
	|| stat -f '%Lp' "$work/out-dpw/install.conf" 2> /dev/null \
	|| echo '')
if [ "$_mode" = 600 ]; then
	ok 'the response file is 0600'
else
	no "the response file is 0600 (got: ${_mode:-unknown})"
fi

if [ -f "$work/out-dpw/install.conf.redacted" ]; then
	ok 'the redacted response file is written'
else
	no 'the redacted response file is written'
fi
if [ -f "$work/out-dpw/install.conf.redacted" ] \
	&& ! grep -q '\$2' "$work/out-dpw/install.conf.redacted" 2> /dev/null; then
	ok 'the redacted response file holds no bcrypt hash'
else
	no 'the redacted response file holds no bcrypt hash'
fi
if [ -f "$work/out-dpw/install.conf.redacted" ] \
	&& ! grep -q -F "$HASH" "$work/out-dpw/install.conf.redacted" 2> /dev/null; then
	ok 'the redacted response file holds no password hash'
else
	no 'the redacted response file holds no password hash'
fi
grep -q '^Password for user = <redacted>$' "$work/out-dpw/install.conf.redacted" 2> /dev/null \
	&& ok 'the redacted response file names the redacted password' \
	|| no 'the redacted response file names the redacted password'
# the real response file still holds the hash: the redacted copy is a copy
# of it, not the file itself
grep -q -F -x "Password for user = $HASH" "$work/out-dpw/install.conf" 2> /dev/null \
	&& ok 'the response file still holds the password hash' \
	|| no 'the response file still holds the password hash'

# The CI archives the redacted response file and never the response file
# itself: an archived artefact must not carry a secret.
_art=$(grep -o "artifacts: *['\"][^'\"]*['\"]" "$JF" 2> /dev/null | head -1 \
	| sed -e "s/^artifacts: *['\"]//" -e "s/['\"]$//")
if [ -n "$_art" ]; then
	ok 'the archive pattern of the Jenkinsfile was found'
else
	no 'the archive pattern of the Jenkinsfile was found'
fi
_hits_secret=0
_hits_redacted=0
for _p in $(printf '%s' "$_art" | tr ',' ' '); do
	case 'out/appliance/install.conf' in $_p) _hits_secret=1 ;; esac
	case 'out/install.conf' in $_p) _hits_secret=1 ;; esac
	case 'out/appliance/install.conf.redacted' in $_p) _hits_redacted=1 ;; esac
	case 'out/install.conf.redacted' in $_p) _hits_redacted=1 ;; esac
done
if [ "$_hits_secret" -eq 0 ]; then
	ok 'the archive pattern of the Jenkinsfile does not match install.conf'
else
	no 'the archive pattern of the Jenkinsfile does not match install.conf'
fi
if [ "$_hits_redacted" -eq 1 ]; then
	ok 'the archive pattern of the Jenkinsfile matches the redacted response file'
else
	no 'the archive pattern of the Jenkinsfile matches the redacted response file'
fi

printf '== the site set is what it says ==\n'

# The profile fragment is appended to the base file: the daemon settings of
# the profile are in the merged file, and nowhere else.
grep -q '^sshd_flags=$' "$work/x/etc/rc.conf.local" 2> /dev/null \
	&& ok 'the merged rc.conf.local holds the sshd_flags of the appliance' \
	|| no 'the merged rc.conf.local holds the sshd_flags of the appliance'
grep -q '^sshd_flags=NO$' "$work/xd/etc/rc.conf.local" 2> /dev/null \
	&& ok 'the merged rc.conf.local holds the sshd_flags of the desktop' \
	|| no 'the merged rc.conf.local holds the sshd_flags of the desktop'

# the package list that install.site reads has to be in the archive
_pkglist=$(sed -n 's/^PKGLIST="\(.*\)"$/\1/p' "$work/x/install.site" 2> /dev/null)
if [ -n "$_pkglist" ] && [ -f "$work/x$_pkglist" ]; then
	ok 'the package list of install.site is in the site set'
else
	no 'the package list of install.site is in the site set'
fi

# install.site really calls pkg_add(1). It runs against a temporary root:
# the absolute paths of the copy (the package list, ssh-keygen, usermod
# and the two files install.site writes) point at that root, everything
# else is the shipped script. The stub pkg_add(1) on the PATH records the
# call.
_root="$work/root"
mkdir -p "$_root/usr/local/share/examplebsd" "$_root/bin" "$_root/etc"
printf '%s\n' '# a package of the test' 'somepackage' > "$_root/usr/local/share/examplebsd/packages.list"
printf '%s\n' 'the message of the day' > "$_root/etc/motd"
cat > "$_root/bin/pkg_add" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WTFBSD_FAKE_PKGADD_LOG"
exit 0
STUB
cat > "$_root/bin/ssh-keygen" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$_root/bin/usermod" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WTFBSD_FAKE_USERMOD_LOG"
exit 0
STUB
chmod +x "$_root/bin/pkg_add" "$_root/bin/ssh-keygen" "$_root/bin/usermod"
sed -e "s|^PKGLIST=\"/|PKGLIST=\"$_root/|" \
	-e "s|/usr/bin/ssh-keygen|$_root/bin/ssh-keygen|" \
	-e "s|/usr/sbin/usermod|$_root/bin/usermod|" \
	-e "s|FAILFILE='[^']*'|FAILFILE='$_root/etc/pkg-failed'|" \
	-e "s|MOTDFILE='[^']*'|MOTDFILE='$_root/etc/motd'|" \
	"$work/x/install.site" > "$_root/install.site"
chmod +x "$_root/install.site"
if WTFBSD_FAKE_PKGADD_LOG="$work/pkgadd.log" \
	WTFBSD_FAKE_USERMOD_LOG="$work/usermod.log" PATH="$_root/bin:$PATH" \
	sh "$_root/install.site" > "$work/installsite.log" 2>&1; then
	ok 'install.site runs'
else
	no "install.site runs (see $work/installsite.log)"
fi
grep -q 'somepackage' "$work/pkgadd.log" 2> /dev/null \
	&& ok 'install.site calls pkg_add with the packages of the list' \
	|| no 'install.site calls pkg_add with the packages of the list'
# the operator account is a member of wheel: doas.conf(5) grants the
# members of that group the right to become root
grep -q -- '-G wheel operator' "$work/usermod.log" 2> /dev/null \
	&& ok 'install.site adds the operator account to the wheel group' \
	|| no 'install.site adds the operator account to the wheel group'

# a package that cannot be installed is not a silent failure: the file of
# the failed packages is written, the message of the day says so, and the
# script fails
_root2="$work/root2"
mkdir -p "$_root2/usr/local/share/examplebsd" "$_root2/bin" "$_root2/etc"
printf '%s\n' '# a package of the test' 'somepackage' 'otherpackage' \
	> "$_root2/usr/local/share/examplebsd/packages.list"
printf '%s\n' 'the message of the day' > "$_root2/etc/motd"
cat > "$_root2/bin/pkg_add" <<'STUB'
#!/bin/sh
case "$*" in
*somepackage*) exit 1 ;;
esac
exit 0
STUB
cat > "$_root2/bin/ssh-keygen" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$_root2/bin/usermod" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$_root2/bin/pkg_add" "$_root2/bin/ssh-keygen" "$_root2/bin/usermod"
sed -e "s|^PKGLIST=\"/|PKGLIST=\"$_root2/|" \
	-e "s|/usr/bin/ssh-keygen|$_root2/bin/ssh-keygen|" \
	-e "s|/usr/sbin/usermod|$_root2/bin/usermod|" \
	-e "s|FAILFILE='[^']*'|FAILFILE='$_root2/etc/pkg-failed'|" \
	-e "s|MOTDFILE='[^']*'|MOTDFILE='$_root2/etc/motd'|" \
	"$work/x/install.site" > "$_root2/install.site"
chmod +x "$_root2/install.site"
if PATH="$_root2/bin:$PATH" sh "$_root2/install.site" \
	> "$work/installsite2.log" 2>&1; then
	no 'install.site fails when a package cannot be installed'
else
	ok 'install.site fails when a package cannot be installed'
fi
if [ -f "$_root2/etc/pkg-failed" ]; then
	ok 'install.site writes the file of the failed packages'
else
	no 'install.site writes the file of the failed packages'
fi
grep -q '^somepackage$' "$_root2/etc/pkg-failed" 2> /dev/null \
	&& ok 'the file of the failed packages names the package that failed' \
	|| no 'the file of the failed packages names the package that failed'
if grep -q '^otherpackage$' "$_root2/etc/pkg-failed" 2> /dev/null; then
	no 'the file of the failed packages holds only the failed package'
else
	ok 'the file of the failed packages holds only the failed package'
fi
grep -qi 'pkg-failed' "$_root2/etc/motd" 2> /dev/null \
	&& ok 'the message of the day warns about the failed package' \
	|| no 'the message of the day warns about the failed package'

# The warning of the message of the day is put there once: the script is
# idempotent, so a second run does not put the same warning there a
# second time.
_warn_before=$(grep -c 'WARNING: the packages of' "$_root2/etc/motd" 2> /dev/null || true)
[ -n "$_warn_before" ] || _warn_before=0
PATH="$_root2/bin:$PATH" sh "$_root2/install.site" > "$work/installsite2b.log" 2>&1
_warn_after=$(grep -c 'WARNING: the packages of' "$_root2/etc/motd" 2> /dev/null || true)
[ -n "$_warn_after" ] || _warn_after=0
if [ "$_warn_before" = "$_warn_after" ] && [ "$_warn_after" -ge 1 ]; then
	ok 'the warning of the message of the day is appended only once'
else
	no "the warning of the message of the day is appended only once (before: $_warn_before, after: $_warn_after)"
fi

# A usermod that fails is not a silent failure: the failure is recorded
# in a marker, the message of the day says so, the packages are still
# installed, and the script fails at the end.
_root3="$work/root3"
mkdir -p "$_root3/usr/local/share/examplebsd" "$_root3/bin" "$_root3/etc"
printf '%s\n' '# a package of the test' 'somepackage' > "$_root3/usr/local/share/examplebsd/packages.list"
printf '%s\n' 'the message of the day' > "$_root3/etc/motd"
cat > "$_root3/bin/pkg_add" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WTFBSD_FAKE_PKGADD_LOG"
exit 0
STUB
cat > "$_root3/bin/ssh-keygen" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$_root3/bin/usermod" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WTFBSD_FAKE_USERMOD_LOG"
exit 1
STUB
chmod +x "$_root3/bin/pkg_add" "$_root3/bin/ssh-keygen" "$_root3/bin/usermod"
sed -e "s|^PKGLIST=\"/|PKGLIST=\"$_root3/|" \
	-e "s|/usr/bin/ssh-keygen|$_root3/bin/ssh-keygen|" \
	-e "s|/usr/sbin/usermod|$_root3/bin/usermod|" \
	-e "s|FAILFILE='[^']*'|FAILFILE='$_root3/etc/pkg-failed'|" \
	-e "s|WHEELFILE='[^']*'|WHEELFILE='$_root3/etc/wheel-failed'|" \
	-e "s|MOTDFILE='[^']*'|MOTDFILE='$_root3/etc/motd'|" \
	"$work/x/install.site" > "$_root3/install.site"
chmod +x "$_root3/install.site"
if WTFBSD_FAKE_PKGADD_LOG="$work/pkgadd3.log" \
	WTFBSD_FAKE_USERMOD_LOG="$work/usermod3.log" PATH="$_root3/bin:$PATH" \
	sh "$_root3/install.site" > "$work/installsite3.log" 2>&1; then
	no 'install.site fails when the operator account cannot join the wheel group'
else
	ok 'install.site fails when the operator account cannot join the wheel group'
fi
# the script goes on to the packages: a wheel group that is not fixed does
# not stop the installation of the packages
grep -q 'somepackage' "$work/pkgadd3.log" 2> /dev/null \
	&& ok 'install.site installs the packages when usermod failed' \
	|| no 'install.site installs the packages when usermod failed'
if [ -f "$_root3/etc/wheel-failed" ]; then
	ok 'install.site writes the marker of the wheel failure'
else
	no 'install.site writes the marker of the wheel failure'
fi
grep -qi 'wheel' "$_root3/etc/motd" 2> /dev/null \
	&& ok 'the message of the day warns about the wheel group' \
	|| no 'the message of the day warns about the wheel group'

# the sshd of the appliance is key-only
grep -q '^PermitRootLogin no$' "$work/x/etc/ssh/sshd_config" 2> /dev/null \
	&& ok 'the sshd_config refuses the root login' || no 'the sshd_config refuses the root login'
grep -q '^PasswordAuthentication no$' "$work/x/etc/ssh/sshd_config" 2> /dev/null \
	&& ok 'the sshd_config refuses the password logins' \
	|| no 'the sshd_config refuses the password logins'

printf '== doas.conf and the wheel group ==\n'

# The operator account has to be able to become root: doas.conf(5) grants
# the members of the wheel group the right to, and an account that is not
# in the group cannot use it.

# the appliance: the operator becomes root without a password
if [ -f "$work/x/etc/doas.conf" ]; then
	ok 'the appliance profile ships a doas.conf'
else
	no 'the appliance profile ships a doas.conf'
fi
grep -q '^permit nopass :wheel$' "$work/x/etc/doas.conf" 2> /dev/null \
	&& ok 'the appliance grants :wheel a passwordless doas' \
	|| no 'the appliance grants :wheel a passwordless doas'
[ "$(_member_mode "$_tarlist" etc/doas.conf)" = 600 ] \
	&& ok 'the doas.conf of the appliance is 0600 in the site set' \
	|| no 'the doas.conf of the appliance is 0600 in the site set'

# the desktop: the operator becomes root with its own password
if [ -f "$work/xd/etc/doas.conf" ]; then
	ok 'the desktop profile ships a doas.conf'
else
	no 'the desktop profile ships a doas.conf'
fi
grep -q '^permit persist :wheel$' "$work/xd/etc/doas.conf" 2> /dev/null \
	&& ok 'the desktop grants :wheel a persistent doas' \
	|| no 'the desktop grants :wheel a persistent doas'
[ "$(_member_mode "$_tarlistd" etc/doas.conf)" = 600 ] \
	&& ok 'the doas.conf of the desktop is 0600 in the site set' \
	|| no 'the doas.conf of the desktop is 0600 in the site set'

# the file belongs to root:wheel, which is 0:0 on OpenBSD
if grep -E 'etc/doas\.conf$' "$_tarlist" 2> /dev/null \
	| grep -qE '(^| )(0/0|root/wheel)( |$)'; then
	ok 'the doas.conf of the appliance belongs to root:wheel'
else
	no 'the doas.conf of the appliance belongs to root:wheel'
fi
if grep -E 'etc/doas\.conf$' "$_tarlistd" 2> /dev/null \
	| grep -qE '(^| )(0/0|root/wheel)( |$)'; then
	ok 'the doas.conf of the desktop belongs to root:wheel'
else
	no 'the doas.conf of the desktop belongs to root:wheel'
fi

# the README documents how the operator account joins the wheel group
if grep -q 'usermod' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents how the operator account joins the wheel group'
else
	no 'the README documents how the operator account joins the wheel group'
fi

printf '== the small things ==\n'

# the hostname of OpenBSD is in /etc/myname, not in a rc.conf variable
if [ -f "$work/x/etc/myname" ] && grep -q '^examplebsd$' "$work/x/etc/myname" 2> /dev/null; then
	ok 'the site set holds the hostname in etc/myname'
else
	no 'the site set holds the hostname in etc/myname'
fi
if grep -q 'hostname=' "$work/x/etc/rc.conf.local" 2> /dev/null; then
	no 'the rc.conf.local holds no hostname variable'
else
	ok 'the rc.conf.local holds no hostname variable'
fi

# OpenBSD's sshd_config(5) has an Include directive: the file must not
# claim the opposite
if grep -q 'no Include directive' "$repo/overlay/profiles/appliance/rootfs/etc/ssh/sshd_config" 2> /dev/null; then
	no 'the sshd_config does not claim that OpenBSD has no Include directive'
else
	ok 'the sshd_config does not claim that OpenBSD has no Include directive'
fi

# a value with a newline must be refused: a pattern that is matched line
# by line would accept the first line of it
_badrel=$(printf '7.8\nx')
if sh "$BUILD" -n -c "$CONF" -r "$_badrel" -o "$work/out-nl" -u operator -k "$KEYFILE" > "$work/nl.log" 2>&1; then
	no 'a release with a newline is refused'
else
	ok 'a release with a newline is refused'
fi
if sh "$BUILD" -n -c "$CONF" -u "$(printf 'operator\nroot')" -k "$KEYFILE" > "$work/nluser.log" 2>&1; then
	no 'an operator name with a newline is refused'
else
	ok 'an operator name with a newline is refused'
fi

# the opencode configuration follows the schema of opencode
if grep -q '"agent"' "$repo/opencode.json" 2> /dev/null \
	&& ! grep -q '"agents"' "$repo/opencode.json" 2> /dev/null; then
	ok 'the opencode configuration holds the agent map'
else
	no 'the opencode configuration holds the agent map'
fi
if grep -q '"prompt"' "$repo/opencode.json" 2> /dev/null; then
	ok 'the opencode configuration holds the prompt of the agents'
else
	no 'the opencode configuration holds the prompt of the agents'
fi

printf '== ci/vm.sh: the provider front door ==\n'

# (h) an unknown or missing provider fails closed
if WTFBSD_VM_PROVIDER=nosuchprovider sh "$VM" console somevm > "$work/vm.log" 2>&1; then
	no 'an unknown provider fails closed'
else
	ok 'an unknown provider fails closed'
fi
grep -q 'unknown VM provider' "$work/vm.log" 2> /dev/null \
	&& ok 'the unknown provider is named' || no 'the unknown provider is named'
if sh "$VM" console somevm > "$work/vm2.log" 2>&1; then
	no 'a missing provider fails closed'
else
	ok 'a missing provider fails closed'
fi
if WTFBSD_VM_PROVIDER=bhyve WTFBSD_VM_PROVIDER_PATH="$work/nosuchprovider.sh" sh "$VM" console somevm > "$work/vm3.log" 2>&1; then
	no 'a missing provider file fails closed'
else
	ok 'a missing provider file fails closed'
fi
if sh "$VM" frobnicate somevm > "$work/vm4.log" 2>&1; then
	no 'an unknown subcommand fails closed'
else
	ok 'an unknown subcommand fails closed'
fi

printf '== tests/boot-test.sh: the boot test ==\n'

# (i) the boot test against the fake provider
FAKE="$repo/tests/fixtures/fake-provider.sh"
[ -x "$FAKE" ] || chmod +x "$FAKE"

rm -rf "$work/fake"
mkdir -p "$work/fake"
if WTFBSD_FAKE_DIR="$work/fake" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	WTFBSD_BOOT_TIMEOUT=20 WTFBSD_SSH_TIMEOUT=5 \
	sh "$BOOTTEST" "$CONF" desktop > "$work/boot.log" 2>&1; then
	ok 'the boot test passes when the console shows a login prompt'
else
	no "the boot test passes when the console shows a login prompt (see $work/boot.log)"
fi
grep -q '^destroy ' "$work/fake/calls.log" 2> /dev/null \
	&& ok 'the boot test destroys the VM' || no 'the boot test destroys the VM'

rm -rf "$work/fake2"
mkdir -p "$work/fake2"
if WTFBSD_FAKE_DIR="$work/fake2" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_LOG=nologin \
	WTFBSD_BOOT_TIMEOUT=4 WTFBSD_SSH_TIMEOUT=5 \
	sh "$BOOTTEST" "$CONF" desktop > "$work/boot2.log" 2>&1; then
	no 'the boot test fails when there is no login prompt'
else
	ok 'the boot test fails when there is no login prompt'
fi
grep -q '^destroy ' "$work/fake2/calls.log" 2> /dev/null \
	&& ok 'the boot test destroys the VM after a timeout' || no 'the boot test destroys the VM after a timeout'

rm -rf "$work/fake3"
mkdir -p "$work/fake3"
if WTFBSD_FAKE_DIR="$work/fake3" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	WTFBSD_BOOT_TIMEOUT=20 WTFBSD_SSH_TIMEOUT=4 \
	sh "$BOOTTEST" "$CONF" appliance > "$work/boot3.log" 2>&1; then
	no 'the appliance boot test fails when sshd does not answer'
else
	ok 'the appliance boot test fails when sshd does not answer'
fi
grep -q '^destroy ' "$work/fake3/calls.log" 2> /dev/null \
	&& ok 'the boot test destroys the VM after an ssh timeout' || no 'the boot test destroys the VM after an ssh timeout'

# the boot test takes the name of the VM from its third argument
rm -rf "$work/fake4"
mkdir -p "$work/fake4"
if WTFBSD_FAKE_DIR="$work/fake4" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_BOOT_TIMEOUT=20 \
	sh "$BOOTTEST" "$CONF" desktop boot-test-vm-42 > "$work/boot4.log" 2>&1; then
	ok 'the boot test takes the VM name from its third argument'
else
	no "the boot test takes the VM name from its third argument (see $work/boot4.log)"
fi
grep -q '^create boot-test-vm-42$' "$work/fake4/calls.log" 2> /dev/null \
	&& ok 'the VM is created under that name' || no 'the VM is created under that name'

# without that argument the name is derived from the profile
rm -rf "$work/fake5"
mkdir -p "$work/fake5"
if WTFBSD_FAKE_DIR="$work/fake5" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_BOOT_TIMEOUT=20 \
	sh "$BOOTTEST" "$CONF" desktop > "$work/boot5.log" 2>&1; then
	ok 'the boot test runs without a VM name'
else
	no "the boot test runs without a VM name (see $work/boot5.log)"
fi
grep -q '^create boot-desktop-' "$work/fake5/calls.log" 2> /dev/null \
	&& ok 'the VM is named after the profile by default' \
	|| no 'the VM is named after the profile by default'

# the Jenkinsfile hands a deterministic name to the boot test and
# destroys every VM of its list, also when a stage failed
if grep -q 'JOB_BASE_NAME' "$JF" && grep -q 'BUILD_NUMBER' "$JF" \
	&& grep -q "printf 'boot-%s-%s-%s'" "$JF"; then
	ok 'the Jenkinsfile builds a deterministic VM name'
else
	no 'the Jenkinsfile builds a deterministic VM name'
fi
_add=$(grep -n '>> "\$list"' "$JF" | head -1 | cut -d: -f1)
_run=$(grep -n 'tests/boot-test.sh' "$JF" | head -1 | cut -d: -f1)
if [ -n "$_add" ] && [ -n "$_run" ] && [ "$_add" -lt "$_run" ]; then
	ok 'the Jenkinsfile records the VM name before the boot test creates it'
else
	no 'the Jenkinsfile records the VM name before the boot test creates it'
fi
if grep -q ': > "\$list"' "$JF"; then
	ok 'the Jenkinsfile truncates the VM list at the start of the build'
else
	no 'the Jenkinsfile truncates the VM list at the start of the build'
fi
if grep -q 'while IFS= read -r' "$JF" && grep -q 'destroy "\$vm"' "$JF"; then
	ok 'the Jenkinsfile destroys every VM of the list after the build'
else
	no 'the Jenkinsfile destroys every VM of the list after the build'
fi

# the shell of the Jenkinsfile parses
sed "s/'''/@QQ@/g" "$JF" > "$work/jenkins-groovy"
awk '/sh .*@QQ@/ {f=1; next} /^[[:space:]]*@QQ@[[:space:]]*$/ {f=0; next} f {print}' \
	"$work/jenkins-groovy" > "$work/jenkins.sh"
if [ -s "$work/jenkins.sh" ] && sh -n "$work/jenkins.sh" 2> "$work/jenkins-parse.log"; then
	ok 'the shell of the Jenkinsfile parses'
else
	no "the shell of the Jenkinsfile parses (see $work/jenkins-parse.log)"
fi

printf '== ci/providers/bhyve.sh: the reference provider ==\n'

# (k) the serial console is read in raw mode, on the same open file
BHYVE="$repo/ci/providers/bhyve.sh"
if grep -F 'stty raw -echo' "$BHYVE" | grep -qF '< "$HOST_SIDE"'; then
	ok 'the bhyve provider reads the serial console in raw mode'
else
	no 'the bhyve provider reads the serial console in raw mode'
fi

# the command line of the hypervisor: the firmware is loaded as a bootrom,
# the host bridge and the lpc have their slots
rm -rf "$work/fakeprov" "$work/fakebin2" "$work/fakedev"
mkdir -p "$work/fakeprov" "$work/fakebin2" "$work/fakedev"
: > "$work/image.img"
: > "$work/firmware.fd"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$work/fakebin2/id"
cat > "$work/fakebin2/bhyve" <<'FAKEBHYVE'
#!/bin/sh
# the fake hypervisor: it logs its arguments and creates the device of
# the VM, the way bhyve(8) does
printf '%s\n' "$*" >> "$WTFBSD_FAKE_BHYVE_LOG"
last=''
for a in "$@"; do last=$a; done
mkdir -p "$WTFBSD_VM_DEVICE_DIR"
: > "$WTFBSD_VM_DEVICE_DIR/$last"
exit 0
FAKEBHYVE
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin2/bhyvectl"
printf '#!/bin/sh\nfile=""\nfor a in "$@"; do case $a in -*) ;; *) file=$a ;; esac; done\n[ -n "$file" ] && : > "$file"\nexit 0\n' > "$work/fakebin2/truncate"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin2/ifconfig"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin2/kldstat"
chmod +x "$work/fakebin2/id" "$work/fakebin2/bhyve" "$work/fakebin2/bhyvectl" \
	"$work/fakebin2/truncate" "$work/fakebin2/ifconfig" "$work/fakebin2/kldstat"
if WTFBSD_FAKE_BHYVE_LOG="$work/bhyve.argv" \
	WTFBSD_VM_STATE_DIR="$work/fakeprov" \
	WTFBSD_VM_CONSOLE_DIR="$work/fakeprov/console" \
	WTFBSD_VM_DEVICE_DIR="$work/fakedev" \
	WTFBSD_VM_NMD_A="$work/nmdmA" \
	WTFBSD_VM_NMD_B="$work/nmdmB" \
	WTFBSD_VM_FIRMWARE="$work/firmware.fd" \
	PATH="$work/fakebin2:$PATH" \
	sh "$BHYVE" create testvm "$work/image.img" > "$work/prov.log" 2>&1; then
	ok 'the bhyve provider creates a VM'
else
	no "the bhyve provider creates a VM (see $work/prov.log)"
fi
if grep -q 'bootrom,' "$work/bhyve.argv" 2> /dev/null; then
	ok 'the bhyve provider loads the firmware as a bootrom'
else
	no 'the bhyve provider loads the firmware as a bootrom'
fi
if grep -q '0,hostbridge' "$work/bhyve.argv" 2> /dev/null; then
	ok 'the bhyve provider gives the host bridge its slot'
else
	no 'the bhyve provider gives the host bridge its slot'
fi
if grep -q '31,lpc' "$work/bhyve.argv" 2> /dev/null; then
	ok 'the bhyve provider gives the lpc its slot'
else
	no 'the bhyve provider gives the lpc its slot'
fi
# a hypervisor that does not start is a failure, not a VM that boots
rm -rf "$work/fakeprov2" "$work/fakedev2"
mkdir -p "$work/fakeprov2" "$work/fakedev2"
printf '#!/bin/sh\nexit 1\n' > "$work/fakebin2/bhyve"
chmod +x "$work/fakebin2/bhyve"
if WTFBSD_FAKE_BHYVE_LOG="$work/bhyve2.argv" \
	WTFBSD_VM_STATE_DIR="$work/fakeprov2" \
	WTFBSD_VM_CONSOLE_DIR="$work/fakeprov2/console" \
	WTFBSD_VM_DEVICE_DIR="$work/fakedev2" \
	WTFBSD_VM_NMD_A="$work/nmdmA" \
	WTFBSD_VM_NMD_B="$work/nmdmB" \
	WTFBSD_VM_FIRMWARE="$work/firmware.fd" \
	PATH="$work/fakebin2:$PATH" \
	sh "$BHYVE" create deadvm "$work/image.img" > "$work/prov2.log" 2>&1; then
	no 'the bhyve provider fails when the hypervisor does not start'
else
	ok 'the bhyve provider fails when the hypervisor does not start'
fi
# the destroy removes the disk of the VM and its state
rm -rf "$work/dstate" "$work/ddev"
mkdir -p "$work/dstate/gonevm" "$work/ddev"
: > "$work/dstate/gonevm/disk.img"
: > "$work/ddev/gonevm"
if PATH="$work/fakebin2:$PATH" WTFBSD_VM_STATE_DIR="$work/dstate" \
	WTFBSD_VM_CONSOLE_DIR="$work/dstate/console" \
	WTFBSD_VM_DEVICE_DIR="$work/ddev" \
	sh "$BHYVE" destroy gonevm > "$work/destroy4.log" 2>&1; then
	ok 'the destroy of a VM succeeds'
else
	no 'the destroy of a VM succeeds'
fi
[ ! -e "$work/dstate/gonevm/disk.img" ] \
	&& ok 'the destroy removes the disk of the VM' || no 'the destroy removes the disk of the VM'
[ ! -e "$work/dstate/gonevm" ] \
	&& ok 'the destroy removes the state of the VM' || no 'the destroy removes the state of the VM'

# nmdm(4) creates /dev/nmdmNA and /dev/nmdmNB, not /dev/ndNA
if grep -q '/dev/nmdm\${NMD}A' "$BHYVE" && grep -q '/dev/nmdm\${NMD}B' "$BHYVE"; then
	ok 'the bhyve provider uses the nmdm(4) device nodes'
else
	no 'the bhyve provider uses the nmdm(4) device nodes'
fi
if grep -q '/dev/nmd\${NMD}' "$BHYVE"; then
	no 'the bhyve provider does not use a wrong nmdm device node'
else
	ok 'the bhyve provider does not use a wrong nmdm device node'
fi

# the reader of the console reads the host side of the null modem: the
# name the guest side honours (WTFBSD_VM_NMD_B) is the name the reader
# reads, not a name of its own
if grep -q 'exec cat ) < "\$HOST_SIDE"' "$BHYVE"; then
	ok 'the reader of the console reads the host side of the null modem'
else
	no 'the reader of the console reads the host side of the null modem'
fi

# ... and it really reads it: what is written into the host side lands
# in the log of the console. The host side is a named pipe, so the reader
# waits for it instead of reading an empty file and leaving.
rm -rf "$work/fakebin-fifo" "$work/fifoprov" "$work/fifodev" "$work/fifocon"
mkdir -p "$work/fakebin-fifo" "$work/fifoprov" "$work/fifodev" "$work/fifocon"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' \
	> "$work/fakebin-fifo/id"
cat > "$work/fakebin-fifo/bhyve" <<'FAKEBHYVE'
#!/bin/sh
printf '%s\n' "$*" >> "$WTFBSD_FAKE_BHYVE_LOG"
last=''
for a in "$@"; do last=$a; done
mkdir -p "$WTFBSD_VM_DEVICE_DIR"
: > "$WTFBSD_VM_DEVICE_DIR/$last"
exit 0
FAKEBHYVE
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin-fifo/bhyvectl"
printf '#!/bin/sh\nfile=""\nfor a in "$@"; do case $a in -*) ;; *) file=$a ;; esac; done\n[ -n "$file" ] && : > "$file"\nexit 0\n' > "$work/fakebin-fifo/truncate"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin-fifo/ifconfig"
printf '#!/bin/sh\nexit 0\n' > "$work/fakebin-fifo/kldstat"
chmod +x "$work/fakebin-fifo/id" "$work/fakebin-fifo/bhyve" \
	"$work/fakebin-fifo/bhyvectl" "$work/fakebin-fifo/truncate" \
	"$work/fakebin-fifo/ifconfig" "$work/fakebin-fifo/kldstat"
if mkfifo "$work/fifonmdmB" 2> /dev/null; then
	# the name is held open in both directions, so the provider may open
	# it for reading and for writing without waiting for the other side
	exec 9<> "$work/fifonmdmB"
	if WTFBSD_FAKE_BHYVE_LOG="$work/fifo.argv" \
		WTFBSD_VM_STATE_DIR="$work/fifoprov" \
		WTFBSD_VM_CONSOLE_DIR="$work/fifocon" \
		WTFBSD_VM_DEVICE_DIR="$work/fifodev" \
		WTFBSD_VM_NMD_A="$work/fifonmdmA" \
		WTFBSD_VM_NMD_B="$work/fifonmdmB" \
		WTFBSD_VM_FIRMWARE="$work/firmware.fd" \
		PATH="$work/fakebin-fifo:$PATH" \
		sh "$BHYVE" create fifovm "$work/image.img" > "$work/fifo.log" 2>&1; then
		ok 'the bhyve provider creates a VM with a named host side'
	else
		no "the bhyve provider creates a VM with a named host side (see $work/fifo.log)"
	fi
	printf 'HELLO-FROM-THE-HOST-SIDE\n' >&9
	sleep 1
	if grep -q 'HELLO-FROM-THE-HOST-SIDE' "$work/fifocon/fifovm.log" 2> /dev/null; then
		ok 'the reader of the console reads the host side that was named'
	else
		no 'the reader of the console reads the host side that was named'
	fi
	exec 9>&-
else
	no 'the named pipe of the host side could be created'
fi

# A stty that cannot set the raw mode is reported, and the reader of the
# console goes on reading: a dead reader is an empty log of the console
# and a boot test that times out without a word about it.
rm -rf "$work/fakebin-stty" "$work/sttyprov" "$work/sttydev" "$work/sttycon"
mkdir -p "$work/sttyprov" "$work/sttydev" "$work/sttycon"
cp -R "$work/fakebin-fifo" "$work/fakebin-stty"
printf '#!/bin/sh\nexit 1\n' > "$work/fakebin-stty/stty"
chmod +x "$work/fakebin-stty/stty"
if mkfifo "$work/sttyfifo" 2> /dev/null; then
	exec 9<> "$work/sttyfifo"
	WTFBSD_FAKE_BHYVE_LOG="$work/stty.argv" \
		WTFBSD_VM_STATE_DIR="$work/sttyprov" \
		WTFBSD_VM_CONSOLE_DIR="$work/sttycon" \
		WTFBSD_VM_DEVICE_DIR="$work/sttydev" \
		WTFBSD_VM_NMD_A="$work/sttynmdmA" \
		WTFBSD_VM_NMD_B="$work/sttyfifo" \
		WTFBSD_VM_FIRMWARE="$work/firmware.fd" \
		PATH="$work/fakebin-stty:$PATH" \
		sh "$BHYVE" create sttyvm "$work/image.img" \
		> "$work/stty.log" 2> "$work/stty.err"
	sleep 1
	if grep -q 'bhyve: cannot put the console in raw mode' "$work/stty.err" 2> /dev/null; then
		ok 'the provider says it cannot put the console in raw mode'
	else
		no 'the provider says it cannot put the console in raw mode'
	fi
	printf 'HELLO-WITHOUT-THE-RAW-MODE\n' >&9
	sleep 1
	if grep -q 'HELLO-WITHOUT-THE-RAW-MODE' "$work/sttycon/sttyvm.log" 2> /dev/null; then
		ok 'the reader of the console goes on reading without the raw mode'
	else
		no 'the reader of the console goes on reading without the raw mode'
	fi
	exec 9>&-
else
	no 'the named pipe of the stty test could be created'
fi

# the sshd wait is really waited for, and the failure names sshd
rm -rf "$work/fake6"
mkdir -p "$work/fake6"
if WTFBSD_FAKE_DIR="$work/fake6" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	WTFBSD_BOOT_TIMEOUT=3 WTFBSD_SSH_TIMEOUT=3 \
	sh "$BOOTTEST" "$CONF" appliance > "$work/boot6.log" 2>&1; then
	no 'the appliance boot test fails when nothing listens for sshd'
else
	ok 'the appliance boot test fails when nothing listens for sshd'
fi
grep -qi 'sshd' "$work/boot6.log" 2> /dev/null \
	&& ok 'the failure of the sshd wait names sshd' \
	|| no 'the failure of the sshd wait names sshd'

# a signal stops the boot test at once, fails it and destroys the VM
rm -rf "$work/fake7"
mkdir -p "$work/fake7"
_start=$(date +%s)
WTFBSD_FAKE_DIR="$work/fake7" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_LOG=nologin \
	WTFBSD_BOOT_TIMEOUT=20 \
	sh "$BOOTTEST" "$CONF" desktop > "$work/boot7.log" 2>&1 &
_bpid=$!
sleep 1
kill -TERM "$_bpid" 2> /dev/null || true
wait "$_bpid"
_rc=$?
_end=$(date +%s)
if [ "$_rc" -ne 0 ]; then
	ok 'the boot test fails when it is killed'
else
	no 'the boot test fails when it is killed'
fi
if [ "$((_end - _start))" -lt 10 ]; then
	ok 'the boot test stops at once when it is killed'
else
	no 'the boot test stops at once when it is killed'
fi
grep -q '^destroy ' "$work/fake7/calls.log" 2> /dev/null \
	&& ok 'the killed boot test destroys the VM' \
	|| no 'the killed boot test destroys the VM'

# a bad VM name is refused before the provider is called
rm -rf "$work/fake8"
mkdir -p "$work/fake8"
if WTFBSD_FAKE_DIR="$work/fake8" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	sh "$VM" create 'bad name' "$CONF" > "$work/vm5.log" 2>&1; then
	no 'a bad VM name is refused'
else
	ok 'a bad VM name is refused'
fi
if [ -s "$work/fake8/calls.log" ]; then
	no 'the provider is not called for a bad VM name'
else
	ok 'the provider is not called for a bad VM name'
fi

# a name that holds a newline or that is too long is refused everywhere
_nl="ok
x"
_long=$(awk 'BEGIN{ s = ""; while (length(s) < 80) s = s "a"; print s }')
if WTFBSD_FAKE_DIR="$work/fake8" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	sh "$VM" create "$_nl" "$CONF" > "$work/vm6.log" 2>&1; then
	no 'a VM name with a newline is refused'
else
	ok 'a VM name with a newline is refused'
fi
if WTFBSD_FAKE_DIR="$work/fake8" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" \
	sh "$VM" create "$_long" "$CONF" > "$work/vm7.log" 2>&1; then
	no 'a too long VM name is refused'
else
	ok 'a too long VM name is refused'
fi
if WTFBSD_FAKE_DIR="$work/fake8" sh "$FAKE" create "$_nl" "$CONF" > "$work/vm8.log" 2>&1; then
	no 'the fake provider refuses a name with a newline'
else
	ok 'the fake provider refuses a name with a newline'
fi
grep -qi 'name' "$work/vm8.log" 2> /dev/null \
	&& ok 'the fake provider names the bad name' \
	|| no 'the fake provider names the bad name'
if sh "$BHYVE" create "$_nl" "$CONF" > "$work/vm9.log" 2>&1; then
	no 'the bhyve provider refuses a name with a newline'
else
	ok 'the bhyve provider refuses a name with a newline'
fi
grep -qi 'invalid VM name' "$work/vm9.log" 2> /dev/null \
	&& ok 'the bhyve provider names the bad name' \
	|| no 'the bhyve provider names the bad name'

# a VM that is not there any more is already gone, not a failure
rm -rf "$work/vmstate" "$work/vmdev"
mkdir -p "$work/vmstate" "$work/vmdev"
if WTFBSD_VM_STATE_DIR="$work/vmstate" WTFBSD_VM_DEVICE_DIR="$work/vmdev" \
	sh "$BHYVE" destroy gonevm > "$work/destroy.log" 2>&1; then
	ok 'the destroy of a VM that is not there succeeds'
else
	no 'the destroy of a VM that is not there succeeds'
fi
grep -qi 'already gone' "$work/destroy.log" 2> /dev/null \
	&& ok 'the destroy of a VM that is not there says it was already gone' \
	|| no 'the destroy of a VM that is not there says it was already gone'

# a destroy without bhyvectl fails and does not claim a destroyed VM
rm -rf "$work/vmstate2" "$work/vmdev2" "$work/bin"
mkdir -p "$work/vmstate2/gonevm" "$work/vmdev2" "$work/bin"
: > "$work/vmdev2/gonevm"
: > "$work/vmstate2/gonevm/bhyve.pid"
for _t in basename id kill rm cat; do
	_p=$(command -v "$_t" 2> /dev/null) || continue
	[ -x "$_p" ] || continue
	ln -sf "$_p" "$work/bin/$_t"
done
if PATH="$work/bin" WTFBSD_VM_STATE_DIR="$work/vmstate2" WTFBSD_VM_DEVICE_DIR="$work/vmdev2" \
	/bin/sh "$BHYVE" destroy gonevm > "$work/destroy2.log" 2>&1; then
	no 'the destroy fails when bhyvectl is missing'
else
	ok 'the destroy fails when bhyvectl is missing'
fi
grep -qi 'bhyvectl' "$work/destroy2.log" 2> /dev/null \
	&& ok 'the missing bhyvectl is named' || no 'the missing bhyvectl is named'
grep -qi 'destroyed' "$work/destroy2.log" 2> /dev/null \
	&& no 'the destroy does not claim that the VM was destroyed' \
	|| ok 'the destroy does not claim that the VM was destroyed'

# the boot test reports a destroy that failed
rm -rf "$work/fake9"
mkdir -p "$work/fake9"
if WTFBSD_FAKE_DIR="$work/fake9" WTFBSD_VM_PROVIDER=fake \
	WTFBSD_VM_PROVIDER_PATH="$FAKE" WTFBSD_FAKE_FAIL=destroy \
	WTFBSD_BOOT_TIMEOUT=20 \
	sh "$BOOTTEST" "$CONF" desktop > "$work/boot9.log" 2>&1; then
	ok 'the boot test passes when the console shows a login prompt'
else
	no 'the boot test passes when the console shows a login prompt'
fi
grep -qi 'could not destroy' "$work/boot9.log" 2> /dev/null \
	&& ok 'the boot test reports a destroy that failed' \
	|| no 'the boot test reports a destroy that failed'

# the nmdm index and the tap follow the executor, so two jobs on one
# host do not fight over the same device
if grep -q 'WTFBSD_VM_NMD' "$BHYVE" && grep -q 'WTFBSD_VM_TAP' "$BHYVE" \
	&& grep -q 'EXECUTOR_NUMBER' "$BHYVE"; then
	ok 'the nmdm index and the tap follow the executor number'
else
	no 'the nmdm index and the tap follow the executor number'
fi

# the reader of a console is kept in a file of its own, and the destroy
# kills it
if grep -q 'WTFBSD_VM_CONSOLE_DIR' "$BHYVE" && grep -q 'reader.pid' "$BHYVE"; then
	ok 'the bhyve provider keeps the reader of a console in a file of its own'
else
	no 'the bhyve provider keeps the reader of a console in a file of its own'
fi
rm -rf "$work/vmstate3" "$work/vmdev3" "$work/console3"
mkdir -p "$work/vmstate3" "$work/vmdev3" "$work/console3"
sleep 30 &
_rpid=$!
printf '%s\n' "$_rpid" > "$work/console3/stalevm.reader.pid"
if WTFBSD_VM_STATE_DIR="$work/vmstate3" WTFBSD_VM_CONSOLE_DIR="$work/console3" \
	WTFBSD_VM_DEVICE_DIR="$work/vmdev3" \
	sh "$BHYVE" destroy stalevm > "$work/destroy3.log" 2>&1; then
	ok 'the destroy of a VM that is not there succeeds'
else
	no 'the destroy of a VM that is not there succeeds'
fi
sleep 1
if kill -0 "$_rpid" 2> /dev/null; then
	no 'the destroy kills the reader of the console'
	kill "$_rpid" 2> /dev/null || true
else
	ok 'the destroy kills the reader of the console'
fi

# the tap of the guest is attached to the bridge by the provider
if grep -q 'WTFBSD_VM_BRIDGE' "$BHYVE" && grep -q 'addm' "$BHYVE" && grep -q 'deletem' "$BHYVE"; then
	ok 'the bhyve provider attaches the tap to the bridge'
else
	no 'the bhyve provider attaches the tap to the bridge'
fi

# the README tells how to prepare the host, with the right package and
# without a keyword that does not exist
if grep -q 'edk2-bhyve' "$repo/README.md" 2> /dev/null; then
	ok 'the README names the package of the UEFI firmware'
else
	no 'the README names the package of the UEFI firmware'
fi
if grep -q 'ifconfig bridge0 create' "$repo/README.md" 2> /dev/null; then
	ok 'the README tells how to prepare the bridge'
else
	no 'the README tells how to prepare the bridge'
fi
if grep -qi 'master' "$repo/README.md" 2> /dev/null; then
	no 'the README does not use a keyword of ifconfig(8) that does not exist'
else
	ok 'the README does not use a keyword of ifconfig(8) that does not exist'
fi
if grep -qi 'vm-bhyve' "$repo/README.md" 2> /dev/null; then
	no 'the README does not tell to install a package for bhyve(8)'
else
	ok 'the README does not tell to install a package for bhyve(8)'
fi

# the product.conf is a file parameter, and a Pipeline has to unstash it
if grep -q "file(" "$JF" 2> /dev/null; then
	ok 'the Jenkinsfile takes the product.conf as a file parameter'
else
	no 'the Jenkinsfile takes the product.conf as a file parameter'
fi
if grep -q "stashedFile(name: 'PRODUCT_CONF')" "$JF" 2> /dev/null \
	&& grep -q "unstash 'PRODUCT_CONF'" "$JF" 2> /dev/null; then
	ok 'the Jenkinsfile unstashes the file parameter'
else
	no 'the Jenkinsfile unstashes the file parameter'
fi
if grep -qi 'File Parameter' "$repo/README.md" 2> /dev/null; then
	ok 'the README names the plugin the file parameter needs'
else
	no 'the README names the plugin the file parameter needs'
fi

# a provider of the site runs with the privileges of the job
if grep -qi 'root-owned\|owned by root' "$repo/README.md" 2> /dev/null \
	&& grep -qi 'writable' "$repo/README.md" 2> /dev/null; then
	ok 'the README says that a provider of the site has to be owned by root'
else
	no 'the README says that a provider of the site has to be owned by root'
fi
if [ "$(id -u)" = 0 ]; then
	printf 'SKIP  the bhyve provider refuses to work without root (running as root)\n'
else
	if WTFBSD_VM_STATE_DIR="$work/vmstate4" WTFBSD_VM_DEVICE_DIR="$work/vmdev4" \
		sh "$BHYVE" create rootvm "$CONF" > "$work/root.log" 2>&1; then
		no 'the bhyve provider refuses to create a VM without root'
	else
		ok 'the bhyve provider refuses to create a VM without root'
	fi
	grep -qi 'root' "$work/root.log" 2> /dev/null \
		&& ok 'the refusal names root' || no 'the refusal names root'
	grep -qi 'privileges' "$work/root.log" 2> /dev/null \
		&& ok 'the refusal says the provider runs with the privileges of the job' \
		|| no 'the refusal says the provider runs with the privileges of the job'
fi

# the connect of the ssh wait is bounded
if grep -q 'nc -z -w' "$BOOTTEST" 2> /dev/null; then
	ok 'the ssh wait uses a bounded connect'
else
	no 'the ssh wait uses a bounded connect'
fi

# an image path with a comma is refused: bhyve(8) reads a comma as the
# end of an option
: > "$work/weird,name.img"
if sh "$BHYVE" create commavm "$work/weird,name.img" > "$work/comma.log" 2>&1; then
	no 'the bhyve provider refuses an image path with a comma'
else
	ok 'the bhyve provider refuses an image path with a comma'
fi
grep -qi 'comma' "$work/comma.log" 2> /dev/null \
	&& ok 'the refusal names the comma' || no 'the refusal names the comma'

# A VM name is a plain identifier: a name that is a path ('.', '..',
# 'a.b', '../x') would escape the directory of the VM, because the name
# is used as a path under the state directory of the provider. The rule
# is the one of ci/vm.sh: a lower case letter, then lower case letters,
# digits and '-'.
for _bad in . .. a.b ../x; do
	sh "$BHYVE" create "$_bad" "$CONF" > "$work/badname.log" 2>&1 || true
	if grep -qi 'invalid VM name' "$work/badname.log" 2> /dev/null; then
		ok "the bhyve provider refuses the name '$_bad'"
	else
		no "the bhyve provider refuses the name '$_bad'"
	fi
done

# ... and the front door refuses them too, before a provider is called
rm -rf "$work/fake10"
mkdir -p "$work/fake10"
for _bad in . .. a.b ../x; do
	WTFBSD_VM_PROVIDER=fake WTFBSD_VM_PROVIDER_PATH="$FAKE" \
		WTFBSD_FAKE_DIR="$work/fake10" \
		sh "$VM" create "$_bad" "$CONF" > "$work/vmbad.log" 2>&1 || true
	if grep -qi 'invalid VM name' "$work/vmbad.log" 2> /dev/null; then
		ok "ci/vm.sh refuses the name '$_bad'"
	else
		no "ci/vm.sh refuses the name '$_bad'"
	fi
done

# a refused name creates nothing: the name is a path under the state
# directory of the provider, and a name like '.' or '..' would leave it
rm -rf "$work/badstate" "$work/baddev"
mkdir -p "$work/badstate" "$work/baddev"
WTFBSD_VM_STATE_DIR="$work/badstate" \
	WTFBSD_VM_DEVICE_DIR="$work/baddev" \
	WTFBSD_VM_NMD_A="$work/badnmdmA" \
	WTFBSD_VM_NMD_B="$work/badnmdmB" \
	WTFBSD_VM_FIRMWARE="$work/firmware.fd" \
	WTFBSD_FAKE_BHYVE_LOG="$work/badcreate.argv" \
	PATH="$work/fakebin-fifo:$PATH" \
	sh "$BHYVE" create . "$work/image.img" > "$work/badcreate.log" 2>&1 || true
if [ -z "$(ls -A "$work/badstate" 2> /dev/null)" ]; then
	ok 'a refused name creates no state'
else
	no 'a refused name creates no state'
fi

# A destroy that fails is not a leak: the reader of the console is
# killed, the tap leaves the bridge and the state of the VM goes away,
# even when the hypervisor refuses to destroy the VM. The VM may still
# be running, so the destroy says so and fails.
rm -rf "$work/faildestroy" "$work/faildev" "$work/failcon" "$work/failbin"
mkdir -p "$work/faildestroy/failvm" "$work/faildev" "$work/failcon" "$work/failbin"
: > "$work/faildev/failvm"
: > "$work/faildestroy/failvm/disk.img"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' \
	> "$work/failbin/id"
printf '#!/bin/sh\nexit 1\n' > "$work/failbin/bhyvectl"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$WTFBSD_FAKE_IFCONFIG_LOG"\nexit 0\n' \
	> "$work/failbin/ifconfig"
chmod +x "$work/failbin/id" "$work/failbin/bhyvectl" "$work/failbin/ifconfig"
sleep 30 &
_frpid=$!
printf '%s\n' "$_frpid" > "$work/failcon/failvm.reader.pid"
if WTFBSD_FAKE_IFCONFIG_LOG="$work/fail-ifconfig.log" \
	PATH="$work/failbin:$PATH" \
	WTFBSD_VM_STATE_DIR="$work/faildestroy" \
	WTFBSD_VM_CONSOLE_DIR="$work/failcon" \
	WTFBSD_VM_DEVICE_DIR="$work/faildev" \
	WTFBSD_VM_BRIDGE=bridge0 \
	WTFBSD_VM_TAP=tap0 \
	sh "$BHYVE" destroy failvm > "$work/faildestroy.log" 2>&1; then
	no 'the destroy fails when the hypervisor refuses to destroy the VM'
else
	ok 'the destroy fails when the hypervisor refuses to destroy the VM'
fi
grep -qi 'may still be running' "$work/faildestroy.log" 2> /dev/null \
	&& ok 'the failed destroy says the VM may still be running' \
	|| no 'the failed destroy says the VM may still be running'
sleep 1
if kill -0 "$_frpid" 2> /dev/null; then
	no 'the failed destroy kills the reader of the console'
	kill "$_frpid" 2> /dev/null || true
else
	ok 'the failed destroy kills the reader of the console'
fi
grep -q 'deletem' "$work/fail-ifconfig.log" 2> /dev/null \
	&& ok 'the failed destroy takes the tap off the bridge' \
	|| no 'the failed destroy takes the tap off the bridge'
[ ! -e "$work/faildestroy/failvm" ] \
	&& ok 'the failed destroy removes the state of the VM' \
	|| no 'the failed destroy removes the state of the VM'

printf '== build.sh: the network of the install ==\n'

# The fixture has no network: the response file holds no network answer
# and the installer configures the interface with DHCP.
if grep -q '^Network interface to configure' "$work/out/install.conf" 2> /dev/null; then
	no 'the DHCP case holds no network answer'
else
	ok 'the DHCP case holds no network answer'
fi
if grep -q '^IPv4 address for' "$work/out/install.conf" 2> /dev/null; then
	no 'the DHCP case holds no address'
else
	ok 'the DHCP case holds no address'
fi
if grep -q '^DNS domain name = example.org$' "$work/out/install.conf" 2> /dev/null; then
	ok 'the response file answers the domain of the host'
else
	no 'the response file answers the domain of the host'
fi

# a product.conf with a static network
sed -e "s|^DISTRO_OS=.*|DISTRO_OS='openbsd'|" "$CONF" > "$work/net.conf"
cat >> "$work/net.conf" <<'CONF'
NET_IF='em0'
NET_IPV4='192.0.2.10'
NET_NETMASK='255.255.255.0'
NET_GATEWAY='192.0.2.1'
NET_DNS='192.0.2.53'
DOMAIN='example.org'
CONF
if sh "$BUILD" -c "$work/net.conf" -r 8.0 -o "$work/out-net" -u operator -k "$KEYFILE" \
	> "$work/net.log" 2>&1; then
	ok 'a product.conf with a static network builds'
else
	no "a product.conf with a static network builds (see $work/net.log)"
fi
for _answer in \
	'Network interface to configure = em0' \
	'IPv4 address for em0 = 192.0.2.10' \
	'Netmask for em0 = 255.255.255.0' \
	'IPv6 address for em0 = none' \
	'Default IPv4 route = 192.0.2.1' \
	'DNS nameservers = 192.0.2.53' \
	'DNS domain name = example.org'
do
	if grep -qF "$_answer" "$work/out-net/install.conf" 2> /dev/null; then
		ok "the response file answers: $_answer"
	else
		no "the response file answers: $_answer"
	fi
done

# a bad address is refused, with the reason
sed -e "s|^NET_IPV4=.*|NET_IPV4='192.0.2.999'|" "$work/net.conf" > "$work/net-bad.conf"
if sh "$BUILD" -n -c "$work/net-bad.conf" -o "$work/out-netbad" -u operator -k "$KEYFILE" \
	> "$work/netbad.log" 2>&1; then
	no 'a bad address is refused'
else
	ok 'a bad address is refused'
fi
if grep -q 'NET_IPV4' "$work/netbad.log" 2> /dev/null; then
	ok 'the refusal of a bad address names the key'
else
	no 'the refusal of a bad address names the key'
fi

# a missing answer is refused, with the reason
grep -v '^NET_GATEWAY=' "$work/net.conf" > "$work/net-nogw.conf"
if sh "$BUILD" -n -c "$work/net-nogw.conf" -o "$work/out-netnogw" -u operator -k "$KEYFILE" \
	> "$work/netnogw.log" 2>&1; then
	no 'a missing network answer is refused'
else
	ok 'a missing network answer is refused'
fi
if grep -q 'NET_GATEWAY' "$work/netnogw.log" 2> /dev/null; then
	ok 'the refusal of a missing answer names the key'
else
	no 'the refusal of a missing answer names the key'
fi

# an interface that is not one is refused
sed -e "s|^NET_IF=.*|NET_IF='EM0'|" "$work/net.conf" > "$work/net-badif.conf"
if sh "$BUILD" -n -c "$work/net-badif.conf" -o "$work/out-netbadif" -u operator -k "$KEYFILE" \
	> "$work/netbadif.log" 2>&1; then
	no 'a bad interface name is refused'
else
	ok 'a bad interface name is refused'
fi
if grep -q 'NET_IF' "$work/netbadif.log" 2> /dev/null; then
	ok 'the refusal of a bad interface names the key'
else
	no 'the refusal of a bad interface names the key'
fi

# the answers of the network without an address are refused: they would
# be dropped
grep -v '^NET_IPV4=' "$work/net.conf" > "$work/net-noip.conf"
if sh "$BUILD" -n -c "$work/net-noip.conf" -o "$work/out-netnoip" -u operator -k "$KEYFILE" \
	> "$work/netnoip.log" 2>&1; then
	no 'the network answers without an address are refused'
else
	ok 'the network answers without an address are refused'
fi
if grep -q 'NET_IPV4' "$work/netnoip.log" 2> /dev/null; then
	ok 'the refusal of the answers without an address names the key'
else
	no 'the refusal of the answers without an address names the key'
fi

# an octet with a leading zero is not an octet: 010 is not 10
sed -e "s|^NET_IPV4=.*|NET_IPV4='192.0.2.010'|" "$work/net.conf" > "$work/net-leadzero.conf"
if sh "$BUILD" -n -c "$work/net-leadzero.conf" -o "$work/out-netleadzero" -u operator -k "$KEYFILE" \
	> "$work/netleadzero.log" 2>&1; then
	no 'an octet with a leading zero is refused'
else
	ok 'an octet with a leading zero is refused'
fi
if grep -q 'NET_IPV4' "$work/netleadzero.log" 2> /dev/null; then
	ok 'the refusal of an octet with a leading zero names the key'
else
	no 'the refusal of an octet with a leading zero names the key'
fi
# 0 alone is an octet
sed -e "s|^NET_IPV4=.*|NET_IPV4='192.0.2.0'|" "$work/net.conf" > "$work/net-zerooctet.conf"
if sh "$BUILD" -n -c "$work/net-zerooctet.conf" -o "$work/out-netzerooctet" -u operator -k "$KEYFILE" \
	> "$work/netzerooctet.log" 2>&1; then
	ok 'the octet 0 is accepted'
else
	no "the octet 0 is accepted (see $work/netzerooctet.log)"
fi

# the unspecified address is no address of the interface
sed -e "s|^NET_IPV4=.*|NET_IPV4='0.0.0.0'|" "$work/net.conf" > "$work/net-unspec.conf"
if sh "$BUILD" -n -c "$work/net-unspec.conf" -o "$work/out-netunspec" -u operator -k "$KEYFILE" \
	> "$work/netunspec.log" 2>&1; then
	no 'the unspecified address is refused as the address of the interface'
else
	ok 'the unspecified address is refused as the address of the interface'
fi
if grep -q 'NET_IPV4' "$work/netunspec.log" 2> /dev/null; then
	ok 'the refusal of the unspecified address names the key'
else
	no 'the refusal of the unspecified address names the key'
fi
sed -e "s|^NET_GATEWAY=.*|NET_GATEWAY='0.0.0.0'|" "$work/net.conf" > "$work/net-unspecgw.conf"
if sh "$BUILD" -n -c "$work/net-unspecgw.conf" -o "$work/out-netunspecgw" -u operator -k "$KEYFILE" \
	> "$work/netunspecgw.log" 2>&1; then
	no 'the unspecified address is refused as the default route'
else
	ok 'the unspecified address is refused as the default route'
fi
if grep -q 'NET_GATEWAY' "$work/netunspecgw.log" 2> /dev/null; then
	ok 'the refusal of the unspecified address as a route names the key'
else
	no 'the refusal of the unspecified address as a route names the key'
fi

# a netmask is a run of ones followed by a run of zeros. The masks with
# a hole are written in two parts, so this file does not hold the shape
# the leak check of the repository looks for.
sed -e "s|^NET_NETMASK=.*|NET_NETMASK='255.0.255'"".0|" "$work/net.conf" > "$work/net-holes.conf"
if sh "$BUILD" -n -c "$work/net-holes.conf" -o "$work/out-netholes" -u operator -k "$KEYFILE" \
	> "$work/netholes.log" 2>&1; then
	no 'a netmask with a hole is refused'
else
	ok 'a netmask with a hole is refused'
fi
if grep -q 'NET_NETMASK' "$work/netholes.log" 2> /dev/null; then
	ok 'the refusal of a netmask with a hole names the key'
else
	no 'the refusal of a netmask with a hole names the key'
fi
# a mask that is not a run of ones is refused too
sed -e "s|^NET_NETMASK=.*|NET_NETMASK='255.255.0'"".255|" "$work/net.conf" > "$work/net-holes2.conf"
if sh "$BUILD" -n -c "$work/net-holes2.conf" -o "$work/out-netholes2" -u operator -k "$KEYFILE" \
	> "$work/netholes2.log" 2>&1; then
	no 'a netmask that is not a run of ones is refused'
else
	ok 'a netmask that is not a run of ones is refused'
fi
# a mask that is a run of ones is a mask
sed -e "s|^NET_NETMASK=.*|NET_NETMASK='255.255.240.0'|" "$work/net.conf" > "$work/net-contig.conf"
if sh "$BUILD" -n -c "$work/net-contig.conf" -o "$work/out-netcontig" -u operator -k "$KEYFILE" \
	> "$work/netcontig.log" 2>&1; then
	ok 'a contiguous netmask is accepted'
else
	no "a contiguous netmask is accepted (see $work/netcontig.log)"
fi

# a list of nameservers that is blank is no list of nameservers
sed -e "s|^NET_DNS=.*|NET_DNS='   '|" "$work/net.conf" > "$work/net-blankdns.conf"
if sh "$BUILD" -n -c "$work/net-blankdns.conf" -o "$work/out-netblankdns" -u operator -k "$KEYFILE" \
	> "$work/netblankdns.log" 2>&1; then
	no 'a blank list of nameservers is refused'
else
	ok 'a blank list of nameservers is refused'
fi
if grep -q 'NET_DNS' "$work/netblankdns.log" 2> /dev/null; then
	ok 'the refusal of a blank list of nameservers names the key'
else
	no 'the refusal of a blank list of nameservers names the key'
fi
# a glob character in the list of nameservers is a glob character, not
# the names of the files of the directory
sed -e "s|^NET_DNS=.*|NET_DNS='192.0.2.53 *'|" "$work/net.conf" > "$work/net-globdns.conf"
if sh "$BUILD" -n -c "$work/net-globdns.conf" -o "$work/out-netglobdns" -u operator -k "$KEYFILE" \
	> "$work/netglobdns.log" 2>&1; then
	no 'a glob character in the list of nameservers is refused'
else
	ok 'a glob character in the list of nameservers is refused'
fi
# a list of nameservers is a list
sed -e "s|^NET_DNS=.*|NET_DNS='192.0.2.53 192.0.2.54'|" "$work/net.conf" > "$work/net-listdns.conf"
if sh "$BUILD" -n -c "$work/net-listdns.conf" -o "$work/out-netlistdns" -u operator -k "$KEYFILE" \
	> "$work/netlistdns.log" 2>&1; then
	ok 'a list of nameservers is accepted'
else
	no "a list of nameservers is accepted (see $work/netlistdns.log)"
fi

printf '== build.sh: the template of the response file ==\n'

# A copy of the repository: the template of the copy is broken, the
# template of the repository is never touched.
_tplrepo=$work/repo-tpl
mkdir -p "$_tplrepo"
cp -R "$repo/." "$_tplrepo/" 2> /dev/null

# tpl_build <name> <template> — the build of the appliance profile with
# the template of the fixture. The log is in the work directory.
tpl_build() {
	cp "$2" "$_tplrepo/autoinstall/install.conf.template"
	sh "$_tplrepo/build.sh" -c "$_tplrepo/tests/fixtures/openbsd-product.conf" \
		-r 8.0 -o "$work/out-tpl" -u operator -k "$KEYFILE" \
		> "$work/tpl-$1.log" 2>&1
}

# the template of the repository is valid: the build of it works
if tpl_build repo "$repo/autoinstall/install.conf.template"; then
	ok 'the template of the repository builds'
else
	no 'the template of the repository builds'
fi

# an #@if without an #@endif
printf 'What timezone are you in = UTC\n#@if NET_STATIC\nIPv4 address for em0 = @NET_IPV4@\n' \
	> "$work/tpl-unbalanced.conf"
if tpl_build unbalanced "$work/tpl-unbalanced.conf"; then
	no 'a template with an #@if without an #@endif is refused'
else
	ok 'a template with an #@if without an #@endif is refused'
fi
if grep -qF ': line 2:' "$work/tpl-unbalanced.log" 2> /dev/null; then
	ok 'the refusal of an #@if without an #@endif names the line'
else
	no 'the refusal of an #@if without an #@endif names the line'
fi
# the message names the file of the template: the reader of the log has
# to know which file is broken
if grep -qF 'install.conf.template: line 2:' "$work/tpl-unbalanced.log" 2> /dev/null; then
	ok 'the refusal of a template names the template file'
else
	no 'the refusal of a template names the template file'
fi

# an #@endif without an #@if
printf 'What timezone are you in = UTC\n#@endif\n' > "$work/tpl-endif.conf"
if tpl_build endif "$work/tpl-endif.conf"; then
	no 'a template with an #@endif without an #@if is refused'
else
	ok 'a template with an #@endif without an #@if is refused'
fi
if grep -qF ': line 2:' "$work/tpl-endif.log" 2> /dev/null; then
	ok 'the refusal of an #@endif without an #@if names the line'
else
	no 'the refusal of an #@endif without an #@if names the line'
fi

# an #@else outside an #@if
printf 'What timezone are you in = UTC\n#@else\n' > "$work/tpl-else.conf"
if tpl_build else "$work/tpl-else.conf"; then
	no 'a template with an #@else outside an #@if is refused'
else
	ok 'a template with an #@else outside an #@if is refused'
fi
if grep -qF ': line 2:' "$work/tpl-else.log" 2> /dev/null; then
	ok 'the refusal of an #@else outside an #@if names the line'
else
	no 'the refusal of an #@else outside an #@if names the line'
fi

# a nested #@if: the fixture closes with one #@endif, so the nested
# check is the only thing that can refuse it
printf 'What timezone are you in = UTC\n#@if NET_STATIC\n#@if NET_DHCP\n#@endif\n' \
	> "$work/tpl-nested.conf"
if tpl_build nested "$work/tpl-nested.conf"; then
	no 'a template with a nested #@if is refused'
else
	ok 'a template with a nested #@if is refused'
fi
if grep -qF ': line 3:' "$work/tpl-nested.log" 2> /dev/null; then
	ok 'the refusal of a nested #@if names the line'
else
	no 'the refusal of a nested #@if names the line'
fi

# a #@profile without an #@endprofile
printf 'What timezone are you in = UTC\n#@profile desktop\nIPv4 address for em0 = @NET_IPV4@\n' \
	> "$work/tpl-profile.conf"
if tpl_build profile "$work/tpl-profile.conf"; then
	no 'a template with a #@profile without an #@endprofile is refused'
else
	ok 'a template with a #@profile without an #@endprofile is refused'
fi
if grep -qF ': line 2:' "$work/tpl-profile.log" 2> /dev/null; then
	ok 'the refusal of a #@profile without an #@endprofile names the line'
else
	no 'the refusal of a #@profile without an #@endprofile names the line'
fi

# an #@endprofile without a #@profile
printf 'What timezone are you in = UTC\n#@endprofile\n' > "$work/tpl-stray-endprofile.conf"
if tpl_build strayendprofile "$work/tpl-stray-endprofile.conf"; then
	no 'a template with an #@endprofile without a #@profile is refused'
else
	ok 'a template with an #@endprofile without a #@profile is refused'
fi
if grep -qF ': line 2:' "$work/tpl-strayendprofile.log" 2> /dev/null; then
	ok 'the refusal of an #@endprofile without a #@profile names the line'
else
	no 'the refusal of an #@endprofile without a #@profile names the line'
fi

# a second #@else in one #@if
printf 'What timezone are you in = UTC\n#@if NET_STATIC\nIPv4 address for em0 = @NET_IPV4@\n#@else\nIPv4 address for em1 = @NET_IPV4@\n#@else\nIPv4 address for em2 = @NET_IPV4@\n#@endif\n' \
	> "$work/tpl-second-else.conf"
if tpl_build secondelse "$work/tpl-second-else.conf"; then
	no 'a template with a second #@else in one #@if is refused'
else
	ok 'a template with a second #@else in one #@if is refused'
fi
if grep -qF ': line 6:' "$work/tpl-secondelse.log" 2> /dev/null; then
	ok 'the refusal of a second #@else names the line'
else
	no 'the refusal of a second #@else names the line'
fi

# an indented directive: a directive is at the start of the line
printf 'What timezone are you in = UTC\n\t#@if NET_STATIC\nIPv4 address for em0 = @NET_IPV4@\n#@endif\n' \
	> "$work/tpl-indented.conf"
if tpl_build indented "$work/tpl-indented.conf"; then
	no 'a template with an indented directive is refused'
else
	ok 'a template with an indented directive is refused'
fi
if grep -qF ': line 2:' "$work/tpl-indented.log" 2> /dev/null; then
	ok 'the refusal of an indented directive names the line'
else
	no 'the refusal of an indented directive names the line'
fi

# an unknown directive
printf 'What timezone are you in = UTC\n#@bogus something\n' > "$work/tpl-unknown.conf"
if tpl_build unknown "$work/tpl-unknown.conf"; then
	no 'a template with an unknown directive is refused'
else
	ok 'a template with an unknown directive is refused'
fi
if grep -qF ': line 2:' "$work/tpl-unknown.log" 2> /dev/null; then
	ok 'the refusal of an unknown directive names the line'
else
	no 'the refusal of an unknown directive names the line'
fi

# an #@endprofile inside an open #@if
printf 'What timezone are you in = UTC\n#@if NET_STATIC\n#@endprofile\n' \
	> "$work/tpl-endprofile.conf"
if tpl_build endprofile "$work/tpl-endprofile.conf"; then
	no 'a template with an #@endprofile inside an open #@if is refused'
else
	ok 'a template with an #@endprofile inside an open #@if is refused'
fi
if grep -qF ': line 3:' "$work/tpl-endprofile.log" 2> /dev/null; then
	ok 'the refusal of an #@endprofile inside an open #@if names the line'
else
	no 'the refusal of an #@endprofile inside an open #@if names the line'
fi

# a #@profile inside an open #@if
printf 'What timezone are you in = UTC\n#@if NET_STATIC\n#@profile desktop\n' \
	> "$work/tpl-profile-in-if.conf"
if tpl_build profileinif "$work/tpl-profile-in-if.conf"; then
	no 'a template with a #@profile inside an open #@if is refused'
else
	ok 'a template with a #@profile inside an open #@if is refused'
fi
if grep -qF ': line 3:' "$work/tpl-profileinif.log" 2> /dev/null; then
	ok 'the refusal of a #@profile inside an open #@if names the line'
else
	no 'the refusal of a #@profile inside an open #@if names the line'
fi

# a tab after the #@if is a tab: the block is read
printf 'What timezone are you in = UTC\n#@if\tNET_STATIC\nIPv4 address for em0 = @NET_IPV4@\n#@endif\n' \
	> "$work/tpl-tab.conf"
if tpl_build tab "$work/tpl-tab.conf"; then
	ok 'a template with a tab after the #@if builds'
else
	no "a template with a tab after the #@if builds (see $work/tpl-tab.log)"
fi

printf '== ci/media.sh and the boot test stage ==\n'

MEDIA="$repo/ci/media.sh"

# The spool of the media node is a constant of the helper: doas(1)
# resets the environment of the run, so a value of the environment of
# the job would never reach the root run, and the job and the helper
# would not agree on the directory. The helper has no other way to name
# it, and the test suite runs a copy of the helper whose constant is the
# spool of the run.
if grep -q '^SPOOL=/var/spool/wtfbsd-media$' "$MEDIA" 2> /dev/null \
	&& ! grep -q 'WTFBSD_MEDIA_SPOOL' "$MEDIA" 2> /dev/null \
	&& ! grep -q 'WTFBSD_MEDIA_GUARD' "$MEDIA" 2> /dev/null; then
	ok 'the media helper uses the constant spool of the media node'
else
	no 'the media helper uses the constant spool of the media node'
fi

# media_copy <name> <spool> — a copy of the helper whose spool constant
# is the spool of the run.
media_copy() {
	sed "s|^SPOOL=/var/spool/wtfbsd-media\$|SPOOL=$2|" "$MEDIA" > "$work/media-$1.sh"
	printf '%s' "$work/media-$1.sh"
}

MEDIA_RUN=$(media_copy run "$work/spool")
MEDIA_RUN_NOSPOOL=$(media_copy nospool "$work/no-such-spool")
MEDIA_RUN_OPEN=$(media_copy open "$work/spool-open")
MEDIA_RUN_SIGNAL=$(media_copy signal "$work/spool-signal")
MEDIA_RUN_SIGNAL_FAIL=$(media_copy signal-fail "$work/spool-signal-fail")
MEDIA_RUN_UMOUNT=$(media_copy umount "$work/spool-umount")

# The media helper changes the ramdisk of bsd.rd and rebuilds the image
# with mkhybrid(8): the tools of OpenBSD. They are replaced by stubs that
# log their arguments and create the files the real tools would create,
# so the helper runs in the test suite without root and without a real
# image.
_mstub=$work/mediastub
mkdir -p "$_mstub"
_mlog=$work/media-argv.log
: > "$_mlog"

cat > "$_mstub/uname" <<'STUB'
#!/bin/sh
printf 'uname %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
printf 'OpenBSD\n'
STUB

cat > "$_mstub/id" <<'STUB'
#!/bin/sh
printf 'id %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
printf '0\n'
STUB

# vnconfig(8) allocates a free unit and prints the name of it. The
# counter is per run, so the units of two runs of the helper never mix,
# and the nth attach can be made to fail. The list of the devices
# (vnconfig -l) shows the units that are in use and the units that are
# not: the lines of a unit that is in use look like
#   vnd0: covering /path/to/image on sd0a, inode 12345
# and an unused unit prints
#   vnd1: not in use
cat > "$_mstub/vnconfig" <<'STUB'
#!/bin/sh
printf 'vnconfig %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_state=${WTFBSD_TEST_VND_STATE:-/dev/null}
case ${1:-} in
-l)
	_max=0
	if [ -f "$_state" ]; then
		awk '{ p = substr($0, index($0, " ") + 1); printf "%s: covering %s on sd%sa, inode 12345\n", $1, p, substr($1, 4) }' "$_state"
		_max=$(awk '{ n = substr($1, 4) + 0; if (n > m) m = n } END { print m + 0 }' "$_state")
	fi
	_i=0
	while [ "$_i" -le "$_max" ]; do
		if ! awk -v u="vnd$_i" '$1 == u { found = 1 } END { exit found ? 0 : 1 }' "$_state" 2> /dev/null; then
			printf 'vnd%s: not in use\n' "$_i"
		fi
		_i=$((_i + 1))
	done
	exit 0
	;;
-u)
	# the detach of a device: the unit is not in use any more
	if [ -f "$_state" ]; then
		awk -v u="${2:-}" '$1 != u' "$_state" > "$_state.tmp" 2> /dev/null || : > "$_state.tmp"
		mv "$_state.tmp" "$_state" 2> /dev/null || true
	fi
	exit 0
	;;
esac
_n=$(cat "${WTFBSD_TEST_VND_COUNT:-/dev/null}" 2> /dev/null || echo 0)
case $_n in '' | *[!0-9]*) _n=0 ;; esac
_next=$((_n + 1))
if [ "${WTFBSD_TEST_VND_FAIL_ON:-0}" = "$_next" ]; then
	printf 'vnconfig: cannot attach\n' >&2
	exit 1
fi
printf 'vnd%s\n' "$_n"
printf '%s\n' "$_next" > "${WTFBSD_TEST_VND_COUNT:-/dev/null}" 2> /dev/null || true
# the unit is in use: the list of the devices shows the image it covers
if [ -n "${WTFBSD_TEST_VND_STATE:-}" ]; then
	printf '%s %s\n' "vnd$_n" "$1" >> "${WTFBSD_TEST_VND_STATE}"
fi
exit 0
STUB

cat > "$_mstub/mount" <<'STUB'
#!/bin/sh
printf 'mount %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_n=$(cat "${WTFBSD_TEST_MOUNT_COUNT:-/dev/null}" 2> /dev/null || echo 0)
case $_n in '' | *[!0-9]*) _n=0 ;; esac
_n=$((_n + 1))
printf '%s\n' "$_n" > "${WTFBSD_TEST_MOUNT_COUNT:-/dev/null}" 2> /dev/null || true
if [ "${WTFBSD_TEST_MOUNT_FAIL_ON:-0}" = "$_n" ]; then
	printf 'mount: cannot mount\n' >&2
	exit 1
fi
_mnt=''
for _a in "$@"; do _mnt=$_a; done
mkdir -p "$_mnt"
case " $* " in
*" cd9660 "*)
	# the image holds a tree: the stub shows the tree of the prepared
	# image on the mount point
	if [ -n "${WTFBSD_TEST_ISO_TREE:-}" ] && [ -d "$WTFBSD_TEST_ISO_TREE" ]; then
		cp -R "$WTFBSD_TEST_ISO_TREE/." "$_mnt/" 2> /dev/null
	fi
	;;
esac
if [ -n "${WTFBSD_TEST_MOUNT_SLEEP:-}" ]; then sleep "$WTFBSD_TEST_MOUNT_SLEEP"; fi
exit 0
STUB

cat > "$_mstub/umount" <<'STUB'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
# the knob: the unmount of a mount point of that name fails
if [ -n "${WTFBSD_TEST_UMOUNT_FAIL:-}" ]; then
	_b=$(basename -- "${1:-}")
	if [ "$_b" = "$WTFBSD_TEST_UMOUNT_FAIL" ]; then
		printf 'umount: cannot unmount\n' >&2
		exit 1
	fi
fi
# The tree of the mount point is copied aside: the work directory of the
# run is gone when the helper ends, and the test suite reads the tree of
# the mount point after that.
if [ -n "${WTFBSD_TEST_UMOUNT_TREE:-}" ] && [ -d "${1:-}" ]; then
	_b=$(basename -- "$1")
	mkdir -p "$WTFBSD_TEST_UMOUNT_TREE/$_b"
	cp -R "$1/." "$WTFBSD_TEST_UMOUNT_TREE/$_b/" 2> /dev/null
fi
exit 0
STUB

cat > "$_mstub/rdsetroot" <<'STUB'
#!/bin/sh
printf 'rdsetroot %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
if [ "${1:-}" = -x ]; then
	# rdsetroot(8) -x builds the image of the ramdisk
	: > "$2"
fi
exit 0
STUB

cat > "$_mstub/gzip" <<'STUB'
#!/bin/sh
printf 'gzip %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
case ${1:-} in
-dc)
	shift
	cat "$@"
	exit 0
	;;
esac
# gzip(1) writes the compressed file next to the file it read, and
# removes the file it read
for _a in "$@"; do
	case $_a in
	-*) continue ;;
	esac
	cp "$_a" "$_a.gz" 2> /dev/null || : > "$_a.gz"
	rm -f "$_a"
done
exit 0
STUB

cat > "$_mstub/mkhybrid" <<'STUB'
#!/bin/sh
printf 'mkhybrid %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_out=''
_prev=''
for _a in "$@"; do
	if [ "$_prev" = -o ]; then _out=$_a; fi
	_prev=$_a
done
# the tree it is given is the last argument
_tree=''
for _a in "$@"; do _tree=$_a; done
if [ -d "$_tree" ]; then
	find "$_tree" -type f >> "$WTFBSD_TEST_ARGV" 2> /dev/null
	# the tree of the image is copied aside: the test suite reads the
	# files the image was built from
	if [ -n "${WTFBSD_TEST_MKHYBRID_TREE:-}" ]; then
		mkdir -p "${WTFBSD_TEST_MKHYBRID_TREE}"
		cp -R "$_tree/." "${WTFBSD_TEST_MKHYBRID_TREE}/" 2> /dev/null
	fi
fi
if [ -n "$_out" ]; then
	printf 'the image of mkhybrid\n' > "$_out"
fi
exit 0
STUB
chmod +x "$_mstub"/*

# The tree of the image: the directory of the release holds the sets and
# the ramdisk. The names are the raw ones: the boot loader opens
# cd0a:/8.0/amd64/bsd.rd by its name. The media of a release holds the
# EFI boot file of the release (eficdboot) and no index.txt.
_isotree=$work/isotree
mkdir -p "$_isotree/8.0/amd64"
printf 'the ramdisk of the release\n' > "$work/ramdisk.src"
gzip -c "$work/ramdisk.src" > "$_isotree/8.0/amd64/bsd.rd"
printf 'the boot catalog\n' > "$_isotree/8.0/amd64/cdbr"
printf 'the catalog\n' > "$_isotree/8.0/amd64/boot.catalog"
printf 'the efi boot file\n' > "$_isotree/8.0/amd64/eficdboot"

# The spool of the media node: the helper runs as root and touches
# nothing outside it. The image, the site set and the response file are
# the inputs of the run.
mkdir -p "$work/spool"
: > "$work/spool/image.iso"
: > "$work/spool/site80.tgz"
printf 'Location of sets = http\nHTTP Server = sets.example.org\n' > "$work/spool/install.conf"

if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count" \
	WTFBSD_TEST_UMOUNT_TREE="$work/tree" \
	WTFBSD_TEST_MKHYBRID_TREE="$work/mkhybrid-tree" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-1" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media.log" 2>&1; then
	ok 'the media helper prepares the media'
else
	no "the media helper prepares the media (see $work/media.log)"
fi

# the response file goes into the root of the ramdisk of bsd.rd: the
# installer reads it there and never in the root of the CD
if [ -f "$work/tree/mnt-rd/auto_install.conf" ]; then
	ok 'the media helper puts the response file into the ramdisk of bsd.rd'
else
	no 'the media helper puts the response file into the ramdisk of bsd.rd'
fi
if [ ! -e "$work/tree/mnt/auto_install.conf" ]; then
	ok 'the media helper puts no response file in the root of the CD'
else
	no 'the media helper puts no response file in the root of the CD'
fi
if grep -q 'auto_install\.conf' "$_mlog" 2> /dev/null; then
	no 'the media helper puts no response file in the tree of the CD'
else
	ok 'the media helper puts no response file in the tree of the CD'
fi
if grep -q '8\.0/amd64/site80\.tgz' "$_mlog" 2> /dev/null; then
	ok 'the media helper puts the site set with the sets of the release'
else
	no 'the media helper puts the site set with the sets of the release'
fi
if [ ! -e "$work/tree/mnt/8.0/amd64/site80.tgz" ]; then
	ok 'the media helper writes nothing into the image it read'
else
	no 'the media helper writes nothing into the image it read'
fi

# the image is mounted read-only and the ramdisk of bsd.rd is mounted
# with the device of the ramdisk image
if grep -q '^mount -t cd9660 /dev/vnd0c ' "$_mlog" 2> /dev/null; then
	ok 'the media helper mounts the image read-only'
else
	no 'the media helper mounts the image read-only'
fi
if grep -q '^mount /dev/vnd1a ' "$_mlog" 2> /dev/null; then
	ok 'the media helper mounts the ramdisk of bsd.rd'
else
	no 'the media helper mounts the ramdisk of bsd.rd'
fi
if grep -q '^rdsetroot -x ' "$_mlog" 2> /dev/null \
	&& grep -q '^rdsetroot .*/rd\.img$' "$_mlog" 2> /dev/null; then
	ok 'the media helper writes the ramdisk back with rdsetroot'
else
	no 'the media helper writes the ramdisk back with rdsetroot'
fi

# the response file points the installer at the sets of the CD
if grep -q '^Location of sets = cd0$' "$work/tree/mnt-rd/auto_install.conf" 2> /dev/null; then
	ok 'the response file points the installer at the sets of the CD'
else
	no 'the response file points the installer at the sets of the CD'
fi
if grep -q '^Pathname to the sets = 8.0/amd64$' "$work/tree/mnt-rd/auto_install.conf" 2> /dev/null; then
	ok 'the response file names the path of the sets'
else
	no 'the response file names the path of the sets'
fi
if grep -q 'HTTP Server' "$work/tree/mnt-rd/auto_install.conf" 2> /dev/null; then
	no 'the response file names no server of the sets'
else
	ok 'the response file names no server of the sets'
fi

# the image is rebuilt with mkhybrid(8), with the raw paths of the tree
_mkh=$(grep '^mkhybrid ' "$_mlog" 2> /dev/null | head -1)
if [ -n "$_mkh" ]; then
	ok 'the media helper rebuilds the image with mkhybrid'
else
	no 'the media helper rebuilds the image with mkhybrid'
fi
case $_mkh in
*' -b 8.0/amd64/cdbr'*) ok 'mkhybrid gets the raw path of the boot catalog' ;;
*) no 'mkhybrid gets the raw path of the boot catalog' ;;
esac
case $_mkh in
*' -c 8.0/amd64/boot.catalog'*) ok 'mkhybrid gets the raw path of the catalog' ;;
*) no 'mkhybrid gets the raw path of the catalog' ;;
esac
case $_mkh in
*' -e 8.0/amd64/eficdboot'*) ok 'mkhybrid gets the raw path of the EFI boot file' ;;
*) no 'mkhybrid gets the raw path of the EFI boot file' ;;
esac
case $_mkh in
*'eltorito'*) no 'mkhybrid gets no El Torito image that the media does not hold' ;;
*) ok 'mkhybrid gets no El Torito image that the media does not hold' ;;
esac
case $_mkh in
*'8_0'*|*';1'*) no 'mkhybrid gets the raw names of the tree' ;;
*) ok 'mkhybrid gets the raw names of the tree' ;;
esac
if grep -q 'the image of mkhybrid' "$work/spool/image.iso" 2> /dev/null; then
	ok 'the media helper writes the image it rebuilt'
else
	no 'the media helper writes the image it rebuilt'
fi

# The ramdisk of the image is the one of the run: the helper writes the
# ramdisk back into the tree, and the tree it hands to mkhybrid(8) holds
# a bsd.rd that is not the one it read.
if [ -f "$work/mkhybrid-tree/8.0/amd64/bsd.rd" ]; then
	ok 'the tree the image is built from holds a bsd.rd'
else
	no 'the tree the image is built from holds a bsd.rd'
fi
if cmp -s "$work/mkhybrid-tree/8.0/amd64/bsd.rd" "$_isotree/8.0/amd64/bsd.rd" 2> /dev/null; then
	no 'the bsd.rd of the image is not the bsd.rd of the media'
else
	ok 'the bsd.rd of the image is not the bsd.rd of the media'
fi
# gzip -9n writes no name and no timestamp in the header: the image of a
# build is the image of every other build of it.
if grep -q '^gzip -9n ' "$_mlog" 2> /dev/null; then
	ok 'the media helper compresses the ramdisk with gzip -9n'
else
	no 'the media helper compresses the ramdisk with gzip -9n'
fi

# The media of a release holds no index.txt: the install is from the CD
# and the installer reads the sets of the directory of the release. The
# helper never creates one.
if [ -e "$work/mkhybrid-tree/index.txt" ] || [ -e "$work/mkhybrid-tree/8.0/amd64/index.txt" ]; then
	no 'the media helper creates no index.txt'
else
	ok 'the media helper creates no index.txt'
fi
# The tree the image is built from is the thing to look at: the log of
# the run says nothing about a file the helper never mentions.
_idx=$(find "$work/mkhybrid-tree" -name 'index.txt' 2> /dev/null | wc -l)
if [ "$_idx" -eq 0 ]; then
	ok 'the media helper never writes an index.txt of its own'
else
	no "the media helper never writes an index.txt of its own (the tree holds $_idx)"
fi
if grep -q 'index.txt' "$work/media.log" 2> /dev/null; then
	no 'the log of the helper mentions no index.txt'
else
	ok 'the log of the helper mentions no index.txt'
fi
# The assertion above can fail: a copy of the helper that writes an
# index.txt of its own is caught by the tree the image is built from.
sed -e "s|^SPOOL=/var/spool/wtfbsd-media\$|SPOOL=$work/spool|" \
	-e 's|^mkdir -p "\$SETDIR"$|mkdir -p "$SETDIR"; printf "site80.tgz\\n" > "$SETDIR/index.txt"|' \
	"$MEDIA" > "$work/media-index.sh"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-index-own.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-index-own" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-index-own" \
	WTFBSD_TEST_MKHYBRID_TREE="$work/mkhybrid-tree-index-own" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-index-own" \
	sh "$work/media-index.sh" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-index-own.log" 2>&1; then
	ok 'the media helper prepares the media when it writes an index.txt'
else
	no "the media helper prepares the media when it writes an index.txt (see $work/media-index-own.log)"
fi
if [ -n "$(find "$work/mkhybrid-tree-index-own" -name 'index.txt' 2> /dev/null)" ]; then
	ok 'the tree the image is built from holds the index.txt the helper wrote'
else
	no 'the tree the image is built from holds the index.txt the helper wrote'
fi
# The log of the helper says nothing about it: the log is not the thing
# to look at, the tree is.
if grep -q 'index.txt' "$work/media-index-own.log" 2> /dev/null; then
	no 'the log of the helper mentions no index.txt of its own'
else
	ok 'the log of the helper mentions no index.txt of its own'
fi

# The architecture of the media is an argument of the helper, and it is
# never read out of the environment.
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-noarch.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-noarch" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-noarch" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-noarch" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 \
	> "$work/media-noarch.log" 2>&1; then
	no 'the media helper refuses a run without an architecture'
else
	ok 'the media helper refuses a run without an architecture'
fi
if grep -q 'ARCH' "$work/media-noarch.log" 2> /dev/null; then
	ok 'the refusal of a run without an architecture names the architecture'
else
	no 'the refusal of a run without an architecture names the architecture'
fi
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-badarch.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-badarch" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-badarch" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-badarch" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 AMD64 \
	> "$work/media-badarch.log" 2>&1; then
	no 'the media helper refuses an architecture that is not a lowercase name'
else
	ok 'the media helper refuses an architecture that is not a lowercase name'
fi
if grep -qi 'architecture' "$work/media-badarch.log" 2> /dev/null; then
	ok 'the refusal of a bad architecture names the architecture'
else
	no 'the refusal of a bad architecture names the architecture'
fi
# The architecture of the environment is ignored: the argument names an
# architecture the media does not hold, so the helper has to refuse it.
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-envarch.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-envarch" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-envarch" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-envarch" \
	WTFBSD_ARCH=amd64 \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 aarch64 \
	> "$work/media-envarch.log" 2>&1; then
	no 'the media helper ignores the architecture of the environment'
else
	ok 'the media helper ignores the architecture of the environment'
fi
if grep -q '8\.0' "$work/media-envarch.log" 2> /dev/null \
	&& grep -q 'aarch64' "$work/media-envarch.log" 2> /dev/null; then
	ok 'the refusal of a missing architecture names the release and the architecture'
else
	no 'the refusal of a missing architecture names the release and the architecture'
fi

# A media without the EFI boot file of the release has no UEFI entry:
# the helper refuses it instead of building a BIOS only image.
_isotree_noefi=$work/isotree-noefi
cp -R "$_isotree" "$_isotree_noefi"
rm -f "$_isotree_noefi/8.0/amd64/eficdboot"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-noefi.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree_noefi" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-noefi" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-noefi" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-noefi" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-noefi.log" 2>&1; then
	no 'the media helper refuses a media without an EFI boot file'
else
	ok 'the media helper refuses a media without an EFI boot file'
fi
if grep -q 'eficdboot' "$work/media-noefi.log" 2> /dev/null \
	&& grep -q 'UEFI' "$work/media-noefi.log" 2> /dev/null; then
	ok 'the refusal of a media without an EFI boot file names the file and the machine'
else
	no 'the refusal of a media without an EFI boot file names the file and the machine'
fi
if grep -q 'mkhybrid ' "$work/media-argv-noefi.log" 2> /dev/null; then
	no 'the media helper builds no image without an EFI boot file'
else
	ok 'the media helper builds no image without an EFI boot file'
fi

# The log of the run names the files where they are in the image, and
# never the work directory of the run.
if grep -q 'site set: /8\.0/amd64/site80\.tgz' "$work/media.log" 2> /dev/null; then
	ok 'the log of the media helper names the site set in the image'
else
	no 'the log of the media helper names the site set in the image'
fi
if grep -q 'response file: /auto_install\.conf in the ramdisk of bsd\.rd' "$work/media.log" 2> /dev/null; then
	ok 'the log of the media helper names the response file in the ramdisk'
else
	no 'the log of the media helper names the response file in the ramdisk'
fi
if grep -q "$work/spool/work\." "$work/media.log" 2> /dev/null; then
	no 'the log of the media helper prints no path of the work directory'
else
	ok 'the log of the media helper prints no path of the work directory'
fi

# The whole run is exact: the commands run in this order, and no other.
_seen=$(grep -E '^(uname|id|vnconfig|mount|umount|rdsetroot|gzip|mkhybrid) ' "$_mlog" 2> /dev/null \
	| sed -e "s|$work|WORK|g" -e 's|work\.[A-Za-z0-9]\{6\}|work.XXXXXX|g' \
	-e 's|Copyright (c) [0-9]\{4\}|Copyright (c) <year>|')
_want='uname -s
id -u
vnconfig WORK/spool/image.iso
mount -t cd9660 /dev/vnd0c WORK/spool/work.XXXXXX/mnt
umount WORK/spool/work.XXXXXX/mnt
vnconfig -u vnd0
gzip -dc WORK/spool/work.XXXXXX/tree/8.0/amd64/bsd.rd
rdsetroot -x WORK/spool/work.XXXXXX/bsd.rd.raw WORK/spool/work.XXXXXX/rd.img
vnconfig WORK/spool/work.XXXXXX/rd.img
mount /dev/vnd1a WORK/spool/work.XXXXXX/mnt-rd
umount WORK/spool/work.XXXXXX/mnt-rd
vnconfig -u vnd1
rdsetroot WORK/spool/work.XXXXXX/bsd.rd.raw WORK/spool/work.XXXXXX/rd.img
gzip -9n WORK/spool/work.XXXXXX/bsd.rd.raw
mkhybrid -a -R -T -L -l -d -D -N -o WORK/spool/work.XXXXXX/install.iso -v -v -A OpenBSD 8.0 amd64 Install CD -P Copyright (c) <year> The OpenBSD Project -p The OpenBSD Project -V OpenBSD/amd64 8.0 Install CD -b 8.0/amd64/cdbr -c 8.0/amd64/boot.catalog -e 8.0/amd64/eficdboot WORK/spool/work.XXXXXX/tree'
if [ "$_seen" = "$_want" ]; then
	ok 'the media helper runs its commands in the order of the run'
else
	no "the media helper runs its commands in the order of the run (got: $_seen)"
fi

# The cleanup is exact: every mount point that was mounted is unmounted
# once, every device that was attached is detached once, the mount point
# of a device is unmounted before the device is detached, and the
# work directory of the run holds the mount points.
_umounts=$(grep '^umount ' "$_mlog" 2> /dev/null | wc -l)
_detaches=$(grep '^vnconfig -u ' "$_mlog" 2> /dev/null | wc -l)
if [ "$_umounts" -eq 2 ] && [ "$_detaches" -eq 2 ]; then
	ok 'the media helper unmounts every mount once and detaches every device once'
else
	no "the media helper unmounts every mount once and detaches every device once (umount: $_umounts, vnconfig -u: $_detaches)"
fi
# the mount points of the run
_mnt_cd=$(grep '^mount -t cd9660 ' "$_mlog" 2> /dev/null | head -1 | sed -e 's/^mount -t cd9660 [^ ]* //')
_mnt_rd=$(grep '^mount /dev/' "$_mlog" 2> /dev/null | head -1 | sed -e 's/^mount [^ ]* //')
# the devices of the run
_dev_cd=$(grep '^mount -t cd9660 ' "$_mlog" 2> /dev/null | head -1 | awk '{print $4}' | sed -e 's|^/dev/||' -e 's|c$||')
_dev_rd=$(grep '^mount /dev/' "$_mlog" 2> /dev/null | head -1 | awk '{print $2}' | sed -e 's|^/dev/||' -e 's|a$||')
# the unmounts, in the order they ran
_um_cd=$(grep '^umount ' "$_mlog" 2> /dev/null | sed -n '1s/^umount //p')
_um_rd=$(grep '^umount ' "$_mlog" 2> /dev/null | sed -n '2s/^umount //p')
# the detaches, in the order they ran
_de_cd=$(grep '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '1s/^vnconfig -u //p')
_de_rd=$(grep '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '2s/^vnconfig -u //p')
if [ "$_um_cd" = "$_mnt_cd" ] && [ "$_um_rd" = "$_mnt_rd" ]; then
	ok 'the media helper unmounts exactly the mount points it mounted'
else
	no "the media helper unmounts exactly the mount points it mounted (mounted: $_mnt_cd $_mnt_rd; unmounted: $_um_cd $_um_rd)"
fi
if [ "$_de_cd" = "$_dev_cd" ] && [ "$_de_rd" = "$_dev_rd" ]; then
	ok 'the media helper detaches exactly the devices it attached'
else
	no "the media helper detaches exactly the devices it attached (attached: $_dev_cd $_dev_rd; detached: $_de_cd $_de_rd)"
fi
# the mount points live under the work directory of the run, not in the
# root of the file system
_wd_cd=${_mnt_cd%/*}
_wd_rd=${_mnt_rd%/*}
if [ -n "$_wd_cd" ] && [ "$_wd_cd" != / ] && [ "$_wd_cd" = "$_wd_rd" ]; then
	ok 'the mount points of the media helper are under the work directory of the run'
else
	no "the mount points of the media helper are under the work directory of the run (got: $_mnt_cd and $_mnt_rd)"
fi
# the work directory of the run is under the spool of the media node:
# the helper creates nothing outside the spool
case $_wd_cd in
"$work"/spool/work.*) ok 'the work directory of the media helper is under the spool' ;;
*) no "the work directory of the media helper is under the spool (got: $_wd_cd)" ;;
esac
# the unmount of a mount point comes before the detach of its device
_umn_cd=$(grep -n '^umount ' "$_mlog" 2> /dev/null | sed -n '1s/:.*//p')
_denc_cd=$(grep -n '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '1s/:.*//p')
_umn_rd=$(grep -n '^umount ' "$_mlog" 2> /dev/null | sed -n '2s/:.*//p')
_denc_rd=$(grep -n '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '2s/:.*//p')
if [ -n "$_umn_cd" ] && [ -n "$_denc_cd" ] && [ "$_umn_cd" -lt "$_denc_cd" ]; then
	ok 'the media helper unmounts the media before it detaches its device'
else
	no 'the media helper unmounts the media before it detaches its device'
fi
if [ -n "$_umn_rd" ] && [ -n "$_denc_rd" ] && [ "$_umn_rd" -lt "$_denc_rd" ]; then
	ok 'the media helper unmounts the ramdisk before it detaches its device'
else
	no 'the media helper unmounts the ramdisk before it detaches its device'
fi
# the devices are allocated by vnconfig(8): the helper names no unit of
# its own
if [ -n "$_dev_cd" ] && [ -n "$_dev_rd" ] && [ "$_dev_cd" != "$_dev_rd" ]; then
	ok 'the media helper uses a device of its own for the media and for the ramdisk'
else
	no 'the media helper uses a device of its own for the media and for the ramdisk'
fi

# The cleanup undoes only the steps that ran: when the attach of the
# ramdisk fails, the media was already unmounted and detached, and the
# device of the ramdisk is never mentioned.
_mlog3=$work/media-argv-fail.log
: > "$_mlog3"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog3" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-fail" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-fail" \
	WTFBSD_TEST_VND_FAIL_ON=2 \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-2" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-fail.log" 2>&1; then
	no 'the media helper fails when the ramdisk cannot be attached'
else
	ok 'the media helper fails when the ramdisk cannot be attached'
fi
_fu=$(grep '^umount ' "$_mlog3" 2> /dev/null | wc -l)
_fd=$(grep '^vnconfig -u ' "$_mlog3" 2> /dev/null | wc -l)
if [ "$_fu" -eq 1 ] && [ "$_fd" -eq 1 ]; then
	ok 'the cleanup of the media helper unmounts and detaches once what was attached'
else
	no "the cleanup of the media helper unmounts and detaches once what was attached (umount: $_fu, vnconfig -u: $_fd)"
fi
if grep -q 'vnd1' "$_mlog3" 2> /dev/null; then
	no 'the cleanup of the media helper never mentions the device it could not attach'
else
	ok 'the cleanup of the media helper never mentions the device it could not attach'
fi
if [ "$(grep '^mount ' "$_mlog3" 2> /dev/null | wc -l)" -eq 1 ]; then
	ok 'the cleanup of the media helper mounts nothing after the failure'
else
	no 'the cleanup of the media helper mounts nothing after the failure'
fi

# The cleanup undoes the attach when the mount of the media fails: the
# device is detached, and no mount point is unmounted, because none was
# mounted.
_mlog4=$work/media-argv-mountfail.log
: > "$_mlog4"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog4" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-mountfail" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-mountfail" \
	WTFBSD_TEST_MOUNT_FAIL_ON=1 \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-3" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-mountfail.log" 2>&1; then
	no 'the media helper fails when the media cannot be mounted'
else
	ok 'the media helper fails when the media cannot be mounted'
fi
if grep -q 'installNN\.iso' "$work/media-mountfail.log" 2> /dev/null; then
	ok 'the refusal of a mount that fails names the image that is needed'
else
	no 'the refusal of a mount that fails names the image that is needed'
fi
if [ "$(grep '^umount ' "$_mlog4" 2> /dev/null | wc -l)" -eq 0 ]; then
	ok 'the cleanup of the media helper unmounts no mount point that was never mounted'
else
	no 'the cleanup of the media helper unmounts no mount point that was never mounted'
fi
if [ "$(grep '^vnconfig -u ' "$_mlog4" 2> /dev/null | wc -l)" -eq 1 ]; then
	ok 'the cleanup of the media helper detaches the device it attached'
else
	no 'the cleanup of the media helper detaches the device it attached'
fi

# The release of the media is given, and it is never read out of the
# name of the site set: site100.tgz is the site set of the release
# 10.0, and the name of the file says nothing about the release. The
# fourth argument is empty here: the helper has to refuse the run, not
# the number of the arguments.
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-norelease.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-norelease" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-norelease" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-4" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" '' amd64 \
	> "$work/media-norelease.log" 2>&1; then
	no 'the media helper refuses to run without a release'
else
	ok 'the media helper refuses to run without a release'
fi
if grep -qi 'release' "$work/media-norelease.log" 2> /dev/null; then
	ok 'the refusal of a run without a release names the release'
else
	no 'the refusal of a run without a release names the release'
fi
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-badrelease.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-badrelease" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-badrelease" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-5" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0.1 amd64 \
	> "$work/media-badrelease.log" 2>&1; then
	no 'the media helper refuses a release that is not N.N'
else
	ok 'the media helper refuses a release that is not N.N'
fi
if grep -qi 'N.N' "$work/media-badrelease.log" 2> /dev/null; then
	ok 'the refusal of a bad release names the shape of a release'
else
	no 'the refusal of a bad release names the shape of a release'
fi
# the release of the media is the one that was given, whatever the name
# of the site set says
: > "$work/spool/site100.tgz"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-release.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-release" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-release" \
	WTFBSD_TEST_UMOUNT_TREE="$work/tree-release" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-6" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site100.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-release.log" 2>&1; then
	ok 'the media helper takes the release that was given'
else
	no "the media helper takes the release that was given (see $work/media-release.log)"
fi
if [ -f "$work/tree-release/mnt-rd/8.0/amd64/site100.tgz" ] \
	|| grep -q '8\.0/amd64/site100\.tgz' "$work/media-argv-release.log" 2> /dev/null; then
	ok 'the site set lands in the directory of the release that was given'
else
	no 'the site set lands in the directory of the release that was given'
fi
# The release is never read out of the environment: the argument is the
# only source of the release of the media. The fourth argument is empty
# here, so the helper has to refuse the run.
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-envrelease.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-envrelease" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-envrelease" \
	WTFBSD_RELEASE=8.0 \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-7" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" '' amd64 \
	> "$work/media-envrelease.log" 2>&1; then
	no 'the media helper ignores the release of the environment'
else
	ok 'the media helper ignores the release of the environment'
fi
if grep -qi 'release' "$work/media-envrelease.log" 2> /dev/null; then
	ok 'the refusal of a run without a release names the release'
else
	no 'the refusal of a run without a release names the release'
fi

# The helper runs as root: it touches nothing outside the spool of the
# media node, and it follows no link of the account of the job.
ln -sf "$work/spool/site80.tgz" "$work/spool/site80-link.tgz"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-symlink.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-symlink" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-symlink" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-11" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80-link.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-symlink.log" 2>&1; then
	no 'the media helper refuses a site set that is a symbolic link'
else
	ok 'the media helper refuses a site set that is a symbolic link'
fi
if grep -qi 'symbolic link' "$work/media-symlink.log" 2> /dev/null; then
	ok 'the refusal of a symbolic link names the link'
else
	no 'the refusal of a symbolic link names the link'
fi
# a file that is not under the spool is refused
: > "$work/outside.tgz"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-outside.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-outside" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-outside" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-12" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/outside.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-outside.log" 2>&1; then
	no 'the media helper refuses a file that is not under the spool'
else
	ok 'the media helper refuses a file that is not under the spool'
fi
if grep -qi 'spool' "$work/media-outside.log" 2> /dev/null; then
	ok 'the refusal of a file outside the spool names the spool'
else
	no 'the refusal of a file outside the spool names the spool'
fi
# a path with a ".." is refused, even when it points inside the spool
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-dotdot.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-dotdot" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-dotdot" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-13" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/../outside.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-dotdot.log" 2>&1; then
	no 'the media helper refuses a path with a ..'
else
	ok 'the media helper refuses a path with a ..'
fi
# the spool has to exist
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-nospool.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-nospool" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-nospool" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-14" \
	sh "$MEDIA_RUN_NOSPOOL" prepare "$work/no-such-spool/image.iso" "$work/no-such-spool/site80.tgz" "$work/no-such-spool/install.conf" 8.0 amd64 \
	> "$work/media-nospool.log" 2>&1; then
	no 'the media helper refuses a spool directory that does not exist'
else
	ok 'the media helper refuses a spool directory that does not exist'
fi
# the spool may not be writable by others
mkdir -p "$work/spool-open"
: > "$work/spool-open/image.iso"
: > "$work/spool-open/site80.tgz"
printf 'Location of sets = http\n' > "$work/spool-open/install.conf"
chmod 0777 "$work/spool-open"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-openspool.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-openspool" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-openspool" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-15" \
	sh "$MEDIA_RUN_OPEN" prepare "$work/spool-open/image.iso" "$work/spool-open/site80.tgz" "$work/spool-open/install.conf" 8.0 amd64 \
	> "$work/media-openspool.log" 2>&1; then
	no 'the media helper refuses a spool directory that others can write'
else
	ok 'the media helper refuses a spool directory that others can write'
fi
chmod 0755 "$work/spool-open"

# A media that holds an index.txt: the site set is listed in it, and the
# helper creates no index.txt anywhere else.
_isotree2=$work/isotree-index
cp -R "$_isotree" "$_isotree2"
printf 'base.tgz\n' > "$_isotree2/8.0/amd64/index.txt"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-argv-index.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree2" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-index" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-index" \
	WTFBSD_TEST_MKHYBRID_TREE="$work/mkhybrid-tree-index" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-16" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-index.log" 2>&1; then
	ok 'the media helper prepares a media that holds an index.txt'
else
	no "the media helper prepares a media that holds an index.txt (see $work/media-index.log)"
fi
if [ -f "$work/mkhybrid-tree-index/8.0/amd64/index.txt" ] \
	&& grep -qx 'site80.tgz' "$work/mkhybrid-tree-index/8.0/amd64/index.txt" 2> /dev/null; then
	ok 'the media helper lists the site set in the index.txt of the media'
else
	no 'the media helper lists the site set in the index.txt of the media'
fi
if [ "$(grep -c '^site80\.tgz$' "$work/mkhybrid-tree-index/8.0/amd64/index.txt" 2> /dev/null)" -eq 1 ]; then
	ok 'the media helper lists the site set once'
else
	no 'the media helper lists the site set once'
fi
if [ -e "$work/mkhybrid-tree-index/index.txt" ]; then
	no 'the media helper creates no index.txt in the root of the CD'
else
	ok 'the media helper creates no index.txt in the root of the CD'
fi

# the helper refuses to run off OpenBSD
_mstub2=$work/mediastub-linux
mkdir -p "$_mstub2"
cp "$_mstub/id" "$_mstub/vnconfig" "$_mstub/mount" "$_mstub/umount" \
	"$_mstub/rdsetroot" "$_mstub/gzip" "$_mstub/mkhybrid" "$_mstub2/"
cat > "$_mstub2/uname" <<'STUB'
#!/bin/sh
printf 'Linux\n'
STUB
chmod +x "$_mstub2"/*
if env PATH="$_mstub2:$PATH" \
	WTFBSD_TEST_ARGV="$work/media-linux-argv.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-8" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-linux.log" 2>&1; then
	no 'the media helper refuses to run off OpenBSD'
else
	ok 'the media helper refuses to run off OpenBSD'
fi
if grep -q 'OpenBSD' "$work/media-linux.log" 2> /dev/null; then
	ok 'the refusal off OpenBSD names OpenBSD'
else
	no 'the refusal off OpenBSD names OpenBSD'
fi

# the helper refuses to run without the tools of OpenBSD. The
# directories that hold them are left out of the PATH, so rdsetroot(8)
# is not found even on OpenBSD.
_mstub3=$work/mediastub-nordsetroot
mkdir -p "$_mstub3"
cp "$_mstub/uname" "$_mstub/id" "$_mstub/vnconfig" "$_mstub/mount" "$_mstub/umount" \
	"$_mstub/gzip" "$_mstub/mkhybrid" "$_mstub3/"
chmod +x "$_mstub3"/*
_mpath=$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -v '/sbin$' | paste -s -d: -)
if env PATH="$_mstub3:$_mpath" \
	WTFBSD_TEST_ARGV="$work/media-nordsetroot-argv.log" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-9" \
	sh "$MEDIA_RUN" prepare "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" 8.0 amd64 \
	> "$work/media-nordsetroot.log" 2>&1; then
	no 'the media helper refuses to run without rdsetroot'
else
	ok 'the media helper refuses to run without rdsetroot'
fi
if grep -q 'rdsetroot' "$work/media-nordsetroot.log" 2> /dev/null; then
	ok 'the refusal without rdsetroot names the tool'
else
	no 'the refusal without rdsetroot names the tool'
fi

# the helper stops on a signal: the trap runs the cleanup and the script
# exits with the code of the signal, so no step after the signal runs.
# The run has a spool of its own: the work directory of a run that ends
# with a mount up stays under the spool.
mkdir -p "$work/spool-signal"
cp "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" "$work/spool-signal/"
_mlog2=$work/media-signal-argv.log
: > "$_mlog2"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog2" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_MOUNT_SLEEP=2 \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-signal" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-signal" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-10" \
	sh "$MEDIA_RUN_SIGNAL" prepare "$work/spool-signal/image.iso" "$work/spool-signal/site80.tgz" "$work/spool-signal/install.conf" 8.0 amd64 \
	> "$work/media-signal.log" 2>&1 &
then
	_mpid=$!
	sleep 1
	kill -TERM "$_mpid" 2> /dev/null
	_mrc=0
	wait "$_mpid" || _mrc=$?
	if [ "$_mrc" -eq 143 ]; then
		ok 'the media helper exits with the code of the signal'
	else
		no "the media helper exits with the code of the signal (status $_mrc)"
	fi
	if [ -s "$_mlog2" ]; then
		ok 'the media helper cleans up when it is signalled'
	else
		no 'the media helper cleans up when it is signalled'
	fi
	# the cleanup undoes what the helper had done: it detaches the
	# device it attached, and it unmounts nothing outside the work
	# directory of the run
	if [ "$(grep '^vnconfig -u ' "$_mlog2" 2> /dev/null | wc -l)" -eq 1 ]; then
		ok 'the cleanup of the media helper detaches the device it attached'
	else
		no 'the cleanup of the media helper detaches the device it attached'
	fi
	_su_out=$(grep '^umount ' "$_mlog2" 2> /dev/null | grep -v '/work\.' | wc -l)
	if [ "$_su_out" -eq 0 ]; then
		ok 'the cleanup of the media helper unmounts nothing outside its work directory'
	else
		no 'the cleanup of the media helper unmounts nothing outside its work directory'
	fi
	# the mount point that was up when the signal came is unmounted
	_su_mnt=$(grep '^umount ' "$_mlog2" 2> /dev/null | head -1 | sed -e 's/^umount //')
	case $_su_mnt in
	"$work"/spool-signal/work.*/mnt) ok 'the cleanup of the media helper unmounts the mount point it mounted' ;;
	*) no "the cleanup of the media helper unmounts the mount point it mounted (got: $_su_mnt)" ;;
	esac
	if [ "$(grep '^umount ' "$_mlog2" 2> /dev/null | wc -l)" -eq 1 ]; then
		ok 'the cleanup of the media helper unmounts the mount point once'
	else
		no 'the cleanup of the media helper unmounts the mount point once'
	fi
	# the image is never rebuilt after the signal
	if grep -q '^mkhybrid ' "$_mlog2" 2> /dev/null; then
		no 'the media helper runs no step after a signal'
	else
		ok 'the media helper runs no step after a signal'
	fi
fi

# The same signal, with an unmount that fails: the cleanup of the
# signal and the cleanup of the exit run once, the mount that is still
# up is reported, and the work directory of the run stays where it is.
# The run has a spool of its own: the work directory of the run stays
# under the spool of the run.
mkdir -p "$work/spool-signal-fail"
cp "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" "$work/spool-signal-fail/"
_mlog6=$work/media-signal-argv-fail.log
: > "$_mlog6"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog6" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_MOUNT_SLEEP=2 \
	WTFBSD_TEST_UMOUNT_FAIL=mnt \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-signal-fail" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-signal-fail" \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-18" \
	sh "$MEDIA_RUN_SIGNAL_FAIL" prepare "$work/spool-signal-fail/image.iso" "$work/spool-signal-fail/site80.tgz" "$work/spool-signal-fail/install.conf" 8.0 amd64 \
	> "$work/media-signal-fail.log" 2>&1 &
then
	_mpid=$!
	sleep 1
	kill -TERM "$_mpid" 2> /dev/null
	_mrc=0
	wait "$_mpid" || _mrc=$?
	if [ "$_mrc" -eq 143 ]; then
		ok 'the media helper exits with the code of the signal when the unmount fails'
	else
		no "the media helper exits with the code of the signal when the unmount fails (status $_mrc)"
	fi
	if [ "$(grep '^umount ' "$_mlog6" 2> /dev/null | wc -l)" -eq 1 ]; then
		ok 'the cleanup of the media helper runs once when it is signalled'
	else
		no 'the cleanup of the media helper runs once when it is signalled'
	fi
	if grep -q 'still mounted' "$work/media-signal-fail.log" 2> /dev/null; then
		ok 'the cleanup of the media helper names the mount that is still up when it is signalled'
	else
		no 'the cleanup of the media helper names the mount that is still up when it is signalled'
	fi
	if ls -d "$work"/spool-signal-fail/work.* > /dev/null 2>&1; then
		ok 'the work directory of the run stays where it is when the signal found a mount up'
	else
		no 'the work directory of the run stays where it is when the signal found a mount up'
	fi
fi

# The unmount of the ramdisk fails: the helper fails, the cleanup tries
# to unmount it again, the device is detached after the unmount, nothing
# runs twice, and the work directory of the run stays where it is: the
# tree of a mount that is still up lives under it. The run has a spool of
# its own: the work directory stays under the spool of the run.
mkdir -p "$work/spool-umount"
cp "$work/spool/image.iso" "$work/spool/site80.tgz" "$work/spool/install.conf" "$work/spool-umount/"
_mlog5=$work/media-argv-umountfail.log
: > "$_mlog5"
if env PATH="$_mstub:$PATH" \
	WTFBSD_TEST_ARGV="$_mlog5" \
	WTFBSD_TEST_ISO_TREE="$_isotree" \
	WTFBSD_TEST_VND_COUNT="$work/vnd-count-umountfail" \
	WTFBSD_TEST_MOUNT_COUNT="$work/mount-count-umountfail" \
	WTFBSD_TEST_UMOUNT_FAIL=mnt-rd \
	WTFBSD_TEST_VND_STATE="$work/vnd-state-17" \
	sh "$MEDIA_RUN_UMOUNT" prepare "$work/spool-umount/image.iso" "$work/spool-umount/site80.tgz" "$work/spool-umount/install.conf" 8.0 amd64 \
	> "$work/media-umountfail.log" 2>&1; then
	no 'the media helper fails when the ramdisk cannot be unmounted'
else
	ok 'the media helper fails when the ramdisk cannot be unmounted'
fi
if grep -q 'still mounted' "$work/media-umountfail.log" 2> /dev/null; then
	ok 'the cleanup of the media helper names the mount that is still up'
else
	no 'the cleanup of the media helper names the mount that is still up'
fi
_umn=$(grep -n '^umount .*/mnt-rd$' "$_mlog5" 2> /dev/null | tail -1 | cut -d: -f1)
_den=$(grep -n '^vnconfig -u vnd1$' "$_mlog5" 2> /dev/null | tail -1 | cut -d: -f1)
if [ -n "$_umn" ] && [ -n "$_den" ] && [ "$_umn" -lt "$_den" ]; then
	ok 'the cleanup of the media helper unmounts the ramdisk before it detaches its device'
else
	no 'the cleanup of the media helper unmounts the ramdisk before it detaches its device'
fi
if [ "$(grep -c '^vnconfig -u vnd1$' "$_mlog5" 2> /dev/null)" -eq 1 ]; then
	ok 'the cleanup of the media helper detaches the device of the ramdisk once'
else
	no 'the cleanup of the media helper detaches the device of the ramdisk once'
fi
if ls -d "$work"/spool-umount/work.* > /dev/null 2>&1; then
	ok 'the work directory of the run stays where it is when a mount is still up'
else
	no 'the work directory of the run stays where it is when a mount is still up'
fi

# The architecture of the media is the architecture of the product: the
# validate stage reads the DISTRO_ARCH of the product.conf and refuses a
# media of another architecture.
_valstage=$(jenkins_sh_with 'DISTRO_ARCH')
if [ -n "$_valstage" ]; then
	ok 'the validate stage of the Jenkinsfile was found'
else
	no 'the validate stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" RELEASE=8.0 PROFILE=appliance \
	VM_PROVIDER=fake BOOT_TIMEOUT=600 OPERATOR_USER=operator ARCH=amd64 \
	PRODUCT_CONF="$CONF" OPERATOR_PUBKEY="$KEYFILE" OPERATOR_PASSWORD_HASH= \
	sh -c "$_valstage" > "$work/valstage.log" 2>&1; then
	ok 'the validate stage accepts the architecture of the product'
else
	no "the validate stage accepts the architecture of the product (see $work/valstage.log)"
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" RELEASE=8.0 PROFILE=appliance \
	VM_PROVIDER=fake BOOT_TIMEOUT=600 OPERATOR_USER=operator ARCH=aarch64 \
	PRODUCT_CONF="$CONF" OPERATOR_PUBKEY="$KEYFILE" OPERATOR_PASSWORD_HASH= \
	sh -c "$_valstage" > "$work/valstage2.log" 2>&1; then
	no 'the validate stage refuses an architecture that is not the one of the product'
else
	ok 'the validate stage refuses an architecture that is not the one of the product'
fi
if grep -q 'DISTRO_ARCH' "$work/valstage2.log" 2> /dev/null; then
	ok 'the refusal of an architecture names DISTRO_ARCH'
else
	no 'the refusal of an architecture names DISTRO_ARCH'
fi

# the media stage fails when there is no media, unless the build says
# that it accepts a build without a boot test
_stage=$(jenkins_sh_with 'STOCK_MEDIA')
if [ -n "$_stage" ]; then
	ok 'the media stage of the Jenkinsfile was found'
else
	no 'the media stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST= \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	ARCH=amd64 MEDIA_SPOOL=/var/spool/wtfbsd-media \
	sh -c "$_stage" > "$work/stage.log" 2>&1; then
	no 'the media stage fails when STOCK_MEDIA is empty'
else
	ok 'the media stage fails when STOCK_MEDIA is empty'
fi
grep -q 'STOCK_MEDIA' "$work/stage.log" 2> /dev/null \
	&& ok 'the failure names STOCK_MEDIA' || no 'the failure names STOCK_MEDIA'
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST=yes \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	ARCH=amd64 MEDIA_SPOOL=/var/spool/wtfbsd-media \
	sh -c "$_stage" > "$work/stage2.log" 2>&1; then
	ok 'the media stage skips when ALLOW_NO_BOOT_TEST says so'
else
	no 'the media stage skips when ALLOW_NO_BOOT_TEST says so'
fi
# the copy of the media is removed by a trap
if printf '%s\n' "$_stage" | grep -q 'trap'; then
	ok 'the media stage removes the copy of the media with a trap'
else
	no 'the media stage removes the copy of the media with a trap'
fi
# a trap on a signal alone does not exit: the stage would run on after
# the signal, and the copies of the spool would stay
if printf '%s\n' "$_stage" | grep -q "trap 'cleanup' EXIT"; then
	ok 'the media stage removes the copies of the spool when it ends'
else
	no 'the media stage removes the copies of the spool when it ends'
fi
if printf '%s\n' "$_stage" | grep -q "trap 'exit 129' HUP" \
	&& printf '%s\n' "$_stage" | grep -q "trap 'exit 130' INT" \
	&& printf '%s\n' "$_stage" | grep -q "trap 'exit 143' TERM"; then
	ok 'the media stage exits with the code of the signal'
else
	no 'the media stage exits with the code of the signal'
fi
# the helper is installed on the media node: the stage says what to
# install when it is not there
if printf '%s\n' "$_stage" | grep -q 'the media helper is missing on the media node'; then
	ok 'the media stage names the helper it needs'
else
	no 'the media stage names the helper it needs'
fi
if printf '%s\n' "$_stage" | grep -q 'no spool directory'; then
	ok 'the media stage names the spool it needs'
else
	no 'the media stage names the spool it needs'
fi
# the spool is the constant of the helper: doas(1) resets the
# environment of the run, so the two must agree on the directory
if printf '%s\n' "$_stage" | grep -q '/var/spool/wtfbsd-media'; then
	ok 'the media stage uses the spool of the helper'
else
	no 'the media stage uses the spool of the helper'
fi
if grep -q "name: 'MEDIA_SPOOL'" "$JF" 2> /dev/null \
	&& grep -q "name: 'ARCH'" "$JF" 2> /dev/null \
	&& grep -q "defaultValue: '/var/spool/wtfbsd-media'" "$JF" 2> /dev/null; then
	ok 'the Jenkinsfile names the spool and the architecture of the media'
else
	no 'the Jenkinsfile names the spool and the architecture of the media'
fi
# the helper needs root, and the media node grants it with doas.conf(5).
# The rule names the installed copy of the helper: the account of the
# job can rewrite the file of its own workspace.
if printf '%s\n' "$_stage" | grep -q 'doas "\$MEDIA_HELPER"'; then
	ok 'the media stage runs the helper through doas'
else
	no 'the media stage runs the helper through doas'
fi
if printf '%s\n' "$_stage" | grep -q 'doas .*ci/media\.sh'; then
	no 'the media stage runs no helper of the workspace'
else
	ok 'the media stage runs no helper of the workspace'
fi
if grep -q "name: 'MEDIA_HELPER'" "$JF" 2> /dev/null \
	&& grep -q "defaultValue: '/usr/local/libexec/wtfbsd-media'" "$JF" 2> /dev/null; then
	ok 'the Jenkinsfile names the installed helper of the media node'
else
	no 'the Jenkinsfile names the installed helper of the media node'
fi
# the release is given to the helper
if printf '%s\n' "$_stage" | grep -q '"\$RELEASE"'; then
	ok 'the media stage gives the release to the helper'
else
	no 'the media stage gives the release to the helper'
fi
# the architecture is given to the helper
if printf '%s\n' "$_stage" | grep -q '"\$ARCH"'; then
	ok 'the media stage gives the architecture to the helper'
else
	no 'the media stage gives the architecture to the helper'
fi
# the site set and the response file are named by the exact path of the
# profile: a glob would take the file of another build
if printf '%s\n' "$_stage" | grep -q 'ls .*out/'; then
	no 'the media stage names the site set by its path and takes no file of a glob'
else
	ok 'the media stage names the site set by its path and takes no file of a glob'
fi
if printf '%s\n' "$_stage" | grep -q 'outdir=\./out'; then
	ok 'the media stage knows the directory of the profile'
else
	no 'the media stage knows the directory of the profile'
fi
# the workspace of the node holds the files of the last build that ran
# there: they go before the stash of this build
_med_rm=$(grep -n 'rm -rf -- \./out media\.iso' "$JF" 2> /dev/null | head -1 | cut -d: -f1)
_med_un=$(grep -n "unstash 'SITE_SET'" "$JF" 2> /dev/null | head -1 | cut -d: -f1)
if [ -n "$_med_rm" ] && [ -n "$_med_un" ] && [ "$_med_rm" -lt "$_med_un" ]; then
	ok 'the media stage removes the files of another build before the stash of this build'
else
	no 'the media stage removes the files of another build before the stash of this build'
fi
# the boot test never boots the image of another build
_boot_rm=$(grep -n 'rm -f -- media\.iso' "$JF" 2> /dev/null | head -1 | cut -d: -f1)
_boot_un=$(grep -n "unstash 'MEDIA_ISO'" "$JF" 2> /dev/null | head -1 | cut -d: -f1)
if [ -n "$_boot_rm" ] && [ -n "$_boot_un" ] && [ "$_boot_rm" -lt "$_boot_un" ]; then
	ok 'the boot test stage removes the image of another build before the stash of this build'
else
	no 'the boot test stage removes the image of another build before the stash of this build'
fi
# the media stage runs on the node of the media label
if grep -q 'MEDIA_AGENT_LABEL' "$JF"; then
	ok 'the Jenkinsfile takes the label of the media node'
else
	no 'the Jenkinsfile takes the label of the media node'
fi
if grep -q 'agent { label "${params.MEDIA_AGENT_LABEL}" }' "$JF"; then
	ok 'the media stage runs on the node of the media label'
else
	no 'the media stage runs on the node of the media label'
fi
# the image travels from the media stage to the boot test stage
if grep -q "stash name: 'MEDIA_ISO'" "$JF"; then
	ok 'the media stage stashes the image it prepared'
else
	no 'the media stage stashes the image it prepared'
fi
if grep -q "unstash 'MEDIA_ISO'" "$JF"; then
	ok 'the boot test stage unstashes the image'
else
	no 'the boot test stage unstashes the image'
fi

# the boot test stage fails when the media stage prepared no image,
# unless the build says that it accepts a build without a boot test
_bootstage=$(jenkins_sh_with 'boot-test.sh')
if [ -n "$_bootstage" ]; then
	ok 'the boot test stage of the Jenkinsfile was found'
else
	no 'the boot test stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST= \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	sh -c "$_bootstage" > "$work/bootstage.log" 2>&1; then
	no 'the boot test stage fails when no image was prepared'
else
	ok 'the boot test stage fails when no image was prepared'
fi
grep -q 'media.iso' "$work/bootstage.log" 2> /dev/null \
	&& ok 'the failure of the boot test stage names the image' \
	|| no 'the failure of the boot test stage names the image'
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST=yes \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	sh -c "$_bootstage" > "$work/bootstage2.log" 2>&1; then
	ok 'the boot test stage skips when ALLOW_NO_BOOT_TEST says so'
else
	no 'the boot test stage skips when ALLOW_NO_BOOT_TEST says so'
fi
# a build without an image has no boot test, and the stage says so
if grep -qi 'no boot test' "$work/bootstage2.log" 2> /dev/null; then
	ok 'the boot test stage names the boot test it does not run'
else
	no 'the boot test stage names the boot test it does not run'
fi
if grep -q 'boot-test\.sh' "$work/bootstage2.log" 2> /dev/null; then
	no 'the boot test stage boots nothing when there is no image'
else
	ok 'the boot test stage boots nothing when there is no image'
fi
# the boot test stage does not prepare the media any more: the media
# stage does it, on the node of the media label
if printf '%s\n' "$_bootstage" | grep -q 'ci/media\.sh'; then
	no 'the boot test stage prepares no media'
else
	ok 'the boot test stage prepares no media'
fi
# the README tells the operator which line the media node needs
if grep -q 'permit nopass' "$repo/README.md" 2> /dev/null \
	&& grep -q 'as root cmd' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents the doas.conf line of the media node'
else
	no 'the README documents the doas.conf line of the media node'
fi
# the boot test stage is work in progress, and nobody may read the
# template as a thing that was ever boot-tested
if grep -qi 'work in progress' "$repo/README.md" 2> /dev/null \
	&& grep -qi 'work in progress' "$JF" 2> /dev/null; then
	ok 'the README and the Jenkinsfile call the boot test stage work in progress'
else
	no 'the README and the Jenkinsfile call the boot test stage work in progress'
fi
if grep -qi 'ALLOW_NO_BOOT_TEST' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents ALLOW_NO_BOOT_TEST'
else
	no 'the README documents ALLOW_NO_BOOT_TEST'
fi

# the README says plainly what the stage needs, and what it has not
# proven yet
if grep -qi 'OpenBSD media host' "$repo/README.md" 2> /dev/null; then
	ok 'the README names the OpenBSD media host the boot test needs'
else
	no 'the README names the OpenBSD media host the boot test needs'
fi
if grep -qi 'FreeBSD bhyve host' "$repo/README.md" 2> /dev/null; then
	ok 'the README names the FreeBSD bhyve host the boot test needs'
else
	no 'the README names the FreeBSD bhyve host the boot test needs'
fi
if grep -qi 'not yet booted under test' "$repo/README.md" 2> /dev/null; then
	ok 'the README says that the installed system is not yet booted under test'
else
	no 'the README says that the installed system is not yet booted under test'
fi
if grep -q 'ALLOW_NO_BOOT_TEST=yes' "$repo/README.md" 2> /dev/null; then
	ok 'the README documents ALLOW_NO_BOOT_TEST=yes as the opt-out'
else
	no 'the README documents ALLOW_NO_BOOT_TEST=yes as the opt-out'
fi

printf '== the rules of the template ==\n'

# every ssh and scp of a remote build step is hardened
if grep -q 'BatchMode=yes' "$repo/README.md" \
	&& grep -q 'StrictHostKeyChecking=accept-new' "$repo/README.md" \
	&& grep -q 'UserKnownHostsFile' "$repo/README.md"; then
	ok 'the README documents the hardening of every ssh and scp'
else
	no 'the README documents the hardening of every ssh and scp'
fi

printf '== no_internal_refs: the repository itself ==\n'

# (j) no shape that must not reach a public repository
_hits=$( { scan_generic_refs "$repo"; scan_denylist_refs "$repo" "${WTFBSD_DENYLIST:-}"; } | sort -u )
if [ -z "$_hits" ]; then
	ok 'leak check: the repository holds no address, no key and no token'
else
	no "leak check: $_hits"
fi

# the private deny-list is never shipped: no file of the repository is a
# list of names, and the variable that names it is documented
if ( cd "$repo" && git ls-files --cached --others --exclude-standard 2> /dev/null ) \
	| grep -E -i '(deny.?list|forbidden|blacklist)' > /dev/null 2>&1; then
	no 'leak check: the repository ships no deny-list'
else
	ok 'leak check: the repository ships no deny-list'
fi
if grep -q 'WTFBSD_DENYLIST' "$repo/README.md" 2> /dev/null; then
	ok 'leak check: the README documents the deny-list variable'
else
	no 'leak check: the README documents the deny-list variable'
fi

# the detector must be able to fail: a probe file has to be caught
_probe="$repo/.no-internal-refs-probe"

# _join <text...> — the arguments are joined without a space, so the text
# of a probe can be written in pieces and this file does not hold the
# string it looks for. The result is in $_joined.
_join() {
	_joined=$1
	shift
	for _piece in "$@"; do
		_joined="$_joined$_piece"
	done
}

# probe_shape <text...> — the scan has to report the probe file. The file
# is written into the repository, so it is one of the files the scan
# reads, and it is removed again.
probe_shape() {
	_join "$@"
	printf '%s\n' "$_joined" > "$_probe"
	_n=$(scan_generic_refs "$repo" | grep -c 'no-internal-refs-probe')
	rm -f "$_probe"
	[ "$_n" -ge 1 ]
}

# probe_allowed <text...> — the scan must not report the probe file: the
# text holds a shape that is allowed.
probe_allowed() {
	_join "$@"
	printf '%s\n' "$_joined" > "$_probe"
	_n=$(scan_generic_refs "$repo" | grep -c 'no-internal-refs-probe')
	rm -f "$_probe"
	[ "$_n" -eq 0 ]
}

# check_shape <name> <text...> — the detector has to catch the shape
check_shape() {
	_name=$1
	shift
	if probe_shape "$@"; then
		ok "leak check: the detector catches $_name"
	else
		no "leak check: the detector catches $_name"
	fi
}

# check_allowed <name> <text...> — the detector has to let the shape pass
check_allowed() {
	_name=$1
	shift
	if probe_allowed "$@"; then
		ok "leak check: the detector allows $_name"
	else
		no "leak check: the detector allows $_name"
	fi
}

check_shape 'an address of the version 4' '10.0.0' '.1'
check_allowed 'a netmask of a network' '255.255.255.0'
check_allowed 'a contiguous netmask of a network' '255.255.255.128'
check_allowed 'a contiguous netmask of a network of two bytes' '255.255.0.0'
check_allowed 'a contiguous netmask of a network of one byte' '255.0.0.0'
check_shape 'a netmask with a hole' '255.255.0' '.255'
check_shape 'an address that only starts like the placeholder' '127.0.0.1' '50'
check_shape 'an address of the version 6 in the full form' \
	'fe80:0000:0000:' '0000:0000:0000:' '0000:' '0001'
check_shape 'an address of the version 6 in the compressed form' '2001:db9' ':' ':1'
check_shape 'a mail address' 'someone@cor' 'p.example'
check_shape 'a host name in an internal top level domain' 'host.example.la' 'n'
check_shape 'the header of a private key' '-----BEGIN RSA PRIVATE ' 'KEY-----'
check_shape 'the first field of a public key' 'ssh-ed25519 ' 'AAAAC3NzaC1lZDI1NTE5'
check_shape 'a token of the forge' 'gh' 'p_0123456789abcdefghijklmnopqrstuvwxyz'
check_shape 'a token of the forge of an organisation' \
	'gh' 'o_0123456789abcdefghijklmnopqrstuvwxyz'
check_shape 'a token of the forge of a fine access' \
	'github_' 'pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz'
check_shape 'a token of the cloud' 'AKIA' '0123456789ABCDEF'
check_shape 'a token of the chat' 'xox' 'a-1234567890-abcdefghijklmnopqrstuv'
check_shape 'a token of the model' 'sk-' 'abcdefghijklmnopqrstuvwx'
check_shape 'the name of a field of a credential' 'api' 'Key'
check_shape 'the name of a field of a credential with an underscore' 'api_' 'key'
check_shape 'the name of the field of the address of a service' 'base' 'URL'
check_shape 'the name of the header of an authorization' 'Bear' 'er'

check_allowed 'the placeholder of the loopback address' '127.0.0.1'
check_allowed 'the placeholder of the loopback address of the version 6' ':' ':1'
check_allowed 'a documentation range of the version 4' '192.0.2.7'
check_allowed 'the second documentation range of the version 4' '198.51.100.7'
check_allowed 'the third documentation range of the version 4' '203.0.113.7'
check_allowed 'the documentation range of the version 6' '2001:db8' ':' ':1'
check_allowed 'a mail address of the documentation domain' 'operator@example.org'
check_allowed 'the name of the daemon configuration file' 'rc.conf.local'

# the private deny-list: the environment variable names a file, and every
# line of the file that is not empty and not a comment is an extended
# regular expression
_dl="$work/denylist.txt"
printf '%s\n' '# a comment' 'zor''blaxian' > "$_dl"
printf '%s\n' 'zor''blaxian' > "$_probe"
_n=$(scan_denylist_refs "$repo" "$_dl" | wc -l | tr -d ' ')
rm -f "$_probe"
if [ "$_n" = 1 ]; then
	ok 'leak check: the detector catches a name of the private deny-list'
else
	no 'leak check: the detector catches a name of the private deny-list'
fi

# without the variable there is no private check
printf '%s\n' 'zor''blaxian' > "$_probe"
_n=$(scan_denylist_refs "$repo" '' | wc -l | tr -d ' ')
rm -f "$_probe"
if [ "$_n" = 0 ]; then
	ok 'leak check: the private deny-list is optional'
else
	no 'leak check: the private deny-list is optional'
fi

# a deny-list that cannot be read does nothing
_n=$(scan_denylist_refs "$repo" "$work/nosuch-denylist.txt" | wc -l | tr -d ' ')
if [ "$_n" = 0 ]; then
	ok 'leak check: a deny-list that cannot be read does nothing'
else
	no 'leak check: a deny-list that cannot be read does nothing'
fi

# a round report is a working document: it is never tracked
if grep -q 'ROUND-REPORT' "$repo/.gitignore" 2> /dev/null; then
	ok 'a round report is ignored'
else
	no 'a round report is ignored'
fi
if ( cd "$repo" && git ls-files 2> /dev/null ) | grep -q 'ROUND-REPORT'; then
	no 'no round report is tracked'
else
	ok 'no round report is tracked'
fi

# every shell script parses
_bad=''
for _f in $(find "$repo" -name '*.sh' -not -path '*/.git/*'); do
	sh -n "$_f" 2> /dev/null || _bad="$_bad $_f"
done
sh -n "$repo/overlay/base/rootfs/install.site" 2> /dev/null || _bad="$_bad install.site"
[ -z "$_bad" ] && ok 'sh -n is clean on every shell script' || no "sh -n fails on:$_bad"

# nothing is interpreted
_bad=''
for _f in $(find "$repo" -name '*.sh' -not -path '*/.git/*'); do
	grep -v '^[[:space:]]*#' "$_f" | grep -Eq '(^|[^_[:alnum:]])ev''al([^_[:alnum:]]|$)' \
		&& _bad="$_bad $_f"
done
[ -z "$_bad" ] && ok 'no script evaluates its configuration' || no "a script evaluates its configuration:$_bad"

# the opencode configuration is valid JSON
if command -v python3 > /dev/null 2>&1; then
	if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/opencode.json" > /dev/null 2>&1; then
		ok 'opencode.json is valid JSON'
	else
		no 'opencode.json is valid JSON'
	fi
else
	printf 'SKIP  opencode.json is valid JSON (no python3)\n'
fi

# the agents are registered
[ -f "$repo/.opencode/agent/builder.md" ] && [ -f "$repo/.opencode/agent/tester.md" ] \
	&& ok 'the opencode agents are shipped' || no 'the opencode agents are shipped'
[ -f "$repo/AGENTS.md" ] && ok 'AGENTS.md is shipped' || no 'AGENTS.md is shipped'

# the builder agent never reports the contents of the password hash file
# or of the key file: it reports only whether they were given
BUILDER="$repo/.opencode/agent/builder.md"
if grep -qi 'never' "$BUILDER" 2> /dev/null \
	&& grep -qi 'contents' "$BUILDER" 2> /dev/null \
	&& grep -qi 'hash' "$BUILDER" 2> /dev/null \
	&& grep -qi 'public key' "$BUILDER" 2> /dev/null; then
	ok 'the builder agent does not report the contents of the key or of the hash file'
else
	no 'the builder agent does not report the contents of the key or of the hash file'
fi

# the rule about rm -rf is about build.sh, and the one exception is named
if grep -n 'rm -rf' "$repo/AGENTS.md" 2> /dev/null | grep -q 'build\.sh'; then
	ok 'the rm -rf rule of AGENTS.md is about build.sh'
else
	no 'the rm -rf rule of AGENTS.md is about build.sh'
fi
if grep -n 'rm -rf' "$repo/AGENTS.md" 2> /dev/null | grep -qi 'jenkinsfile'; then
	ok 'the rm -rf rule of AGENTS.md names the exception of the Jenkinsfile'
else
	no 'the rm -rf rule of AGENTS.md names the exception of the Jenkinsfile'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
