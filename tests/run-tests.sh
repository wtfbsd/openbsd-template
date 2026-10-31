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
	grep -q "build the site set on a FreeBSD or Linux node (the Build stage's AGENT_LABEL); only the Media stage needs the OpenBSD node" "$work/osbsd.log" 2> /dev/null \
		&& ok 'the refusal says to build on a FreeBSD or Linux node, and that only the Media stage needs OpenBSD' \
		|| no 'the refusal says to build on a FreeBSD or Linux node, and that only the Media stage needs OpenBSD'
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

# The helper runs as root on the media node, through doas(1), which
# resets the environment: the directory of the stock images and the caps
# are constants of the helper. The suite runs copies of the helper whose
# constants point at the fixtures of the suite.
if grep -q '^STOCK_DIR=/usr/local/share/wtfbsd-media$' "$MEDIA" 2> /dev/null \
	&& ! grep -q 'WTFBSD_MEDIA_STOCK\|WTFBSD_MEDIA_SPOOL\|STOCK_MEDIA' "$MEDIA" 2> /dev/null; then
	ok 'the media helper uses the constant stock directory of the media node'
else
	no 'the media helper uses the constant stock directory of the media node'
fi
if grep -q 'mkdtemp' "$MEDIA" 2> /dev/null; then
	no 'the media helper makes its work directory with mktemp -d only'
else
	ok 'the media helper makes its work directory with mktemp -d only'
fi
# OpenBSD tar (pax) lists a hard link with a leading '-' and ' == target',
# GNU tar with an 'h': a listing proves nothing, so the helper reads the
# header bytes and never lists the input.
if grep -Eq 'tar +-[A-Za-z]*t' "$MEDIA" 2> /dev/null; then
	no 'the media helper never reads the listing of tar -t'
else
	ok 'the media helper never reads the listing of tar -t'
fi

# media_copy <name> <stock dir> [<in max> <site max> <conf max>] — a copy
# of the helper whose constants are the fixtures of the suite
media_copy() {
	sed -e "s|^STOCK_DIR=/usr/local/share/wtfbsd-media\$|STOCK_DIR=$2|" \
		-e "s|^IN_MAX=629145600\$|IN_MAX=${3:-629145600}|" \
		-e "s|^SITE_MAX=536870912\$|SITE_MAX=${4:-536870912}|" \
		-e "s|^CONF_MAX=65536\$|CONF_MAX=${5:-65536}|" \
		"$MEDIA" > "$work/media-$1.sh"
	printf '%s' "$work/media-$1.sh"
}

# sha_of <file> — the sha256 of a file, in hex (sha256sum or sha256 -q)
sha_of() {
	if command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		sha256 -q "$1"
	fi
}

# rm_workdir <path> — remove a work directory the helper left behind (a
# run that ended with a mount up); only a path of the shape of the helper
rm_workdir() {
	case ${1:-} in
	/tmp/wtfbsd-media.??????) [ -d "$1" ] && rm -rf -- "$1" ;;
	*) printf 'rm_workdir: refusing %s\n' "${1:-<empty>}" >&2 ;;
	esac
	return 0
}

# The tools of OpenBSD are stubbed: each stub logs its argv to
# $WTFBSD_TEST_ARGV and does what the real tool does to the files. tar(1),
# dd(1), od(1), find(1) and cp(1) are the real ones.
_mstub=$work/mediastub
mkdir -p "$_mstub"
_uid=$(id -u)

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

# mktemp(1): the real one, under /tmp, as the helper asks; the knobs make
# it hand back a directory of another shape or another mode
cat > "$_mstub/mktemp" <<'STUB'
#!/bin/sh
printf 'mktemp %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
if [ -n "${WTFBSD_TEST_MKTEMP_FAKE:-}" ]; then
	mkdir -p "$WTFBSD_TEST_MKTEMP_FAKE"
	printf '%s\n' "$WTFBSD_TEST_MKTEMP_FAKE"
	exit 0
fi
_d=$(command -p mktemp "$@") || exit 1
printf '%s\n' "$_d" >> "${WTFBSD_TEST_MKDLOG:-/dev/null}"
[ -z "${WTFBSD_TEST_MKTEMP_MODE:-}" ] || chmod "$WTFBSD_TEST_MKTEMP_MODE" "$_d"
printf '%s\n' "$_d"
STUB

# stat(1) of OpenBSD: stat -f %u|%Lp|%l|%z FILE. The files of the suite
# belong to the account that runs it, which stands in for root; a path
# that matches $WTFBSD_TEST_STAT_FOREIGN belongs to another account.
cat > "$_mstub/stat" <<'STUB'
#!/bin/sh
[ "${1:-}" = -f ] || exit 2
_fmt=$2
_f=$3
if command -p stat -c %u / > /dev/null 2>&1; then
	case $_fmt in
	%u) _g=%u ;;
	%Lp) _g=%a ;;
	%l) _g=%h ;;
	%z) _g=%s ;;
	*) exit 2 ;;
	esac
	_v=$(command -p stat -c "$_g" -- "$_f") || exit 1
else
	_v=$(command -p stat -f "$_fmt" -- "$_f") || exit 1
fi
if [ "$_fmt" = %u ] && [ "$_v" = "$WTFBSD_TEST_UID" ]; then
	_v=0
	case $_f in
	${WTFBSD_TEST_STAT_FOREIGN:-/nonexistent/none}) _v=4242 ;;
	esac
fi
printf '%s\n' "$_v"
STUB

# sha256(1) of OpenBSD: sha256 -q FILE prints the hex digest only
cat > "$_mstub/sha256" <<'STUB'
#!/bin/sh
printf 'sha256 %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
[ "${1:-}" = -q ] || exit 2
if command -p sha256sum "$2" > /dev/null 2>&1; then
	command -p sha256sum "$2" | awk '{ print $1 }'
else
	command -p sha256 -q "$2"
fi
STUB

# vnconfig(8): the list (vnconfig -l) prints the lines of the real tool,
#   vnd0: covering /path/to/image on sd0d, inode 3
#   vnd1: not in use
# and an attach prints the unit it allocated (vnd0, then vnd1). The knobs
# make an attach sleep (to signal the run in the middle of it) or fail.
cat > "$_mstub/vnconfig" <<'STUB'
#!/bin/sh
printf 'vnconfig %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_state=${WTFBSD_TEST_VND_STATE:-/dev/null}
case ${1:-} in
-l)
	_i=0
	while [ "$_i" -le 3 ]; do
		_p=$(awk -v u="vnd$_i" '$1 == u { print substr($0, index($0, " ") + 1); exit }' "$_state" 2> /dev/null)
		if [ -n "$_p" ]; then
			printf 'vnd%s: covering %s on sd0d, inode 3\n' "$_i" "$_p"
		else
			printf 'vnd%s: not in use\n' "$_i"
		fi
		_i=$((_i + 1))
	done
	exit 0
	;;
-u)
	if [ -f "$_state" ]; then
		awk -v u="${2:-}" '$1 != u' "$_state" > "$_state.tmp" 2> /dev/null || : > "$_state.tmp"
		mv "$_state.tmp" "$_state" 2> /dev/null || true
	fi
	exit 0
	;;
esac
if [ -n "${WTFBSD_TEST_VND_SLEEP:-}" ]; then sleep "$WTFBSD_TEST_VND_SLEEP"; fi
_n=$(cat "${WTFBSD_TEST_VND_COUNT:-/dev/null}" 2> /dev/null || echo 0)
case $_n in '' | *[!0-9]*) _n=0 ;; esac
_next=$((_n + 1))
if [ "${WTFBSD_TEST_VND_FAIL_ON:-0}" = "$_next" ]; then
	printf 'vnconfig: cannot attach\n' >&2
	exit 1
fi
printf '%s\n' "$_next" > "${WTFBSD_TEST_VND_COUNT:-/dev/null}" 2> /dev/null || true
if [ -n "${WTFBSD_TEST_VND_STATE:-}" ]; then
	printf '%s %s\n' "vnd$_n" "$1" >> "$WTFBSD_TEST_VND_STATE"
fi
printf 'vnd%s\n' "$_n"
exit 0
STUB

# mount(8): the mount point shows the tree of the fixture image for a
# cd9660 mount; the knobs make a mount fail or sleep
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
	if [ -n "${WTFBSD_TEST_ISO_TREE:-}" ] && [ -d "$WTFBSD_TEST_ISO_TREE" ]; then
		cp -R "$WTFBSD_TEST_ISO_TREE/." "$_mnt/" 2> /dev/null
	fi
	;;
esac
if [ -n "${WTFBSD_TEST_MOUNT_SLEEP:-}" ]; then sleep "$WTFBSD_TEST_MOUNT_SLEEP"; fi
exit 0
STUB

# umount(8): the tree of the mount point is copied aside, because the work
# directory is gone when the helper ends; the knob makes the unmount of a
# mount point of that name fail
cat > "$_mstub/umount" <<'STUB'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
if [ -n "${WTFBSD_TEST_UMOUNT_FAIL:-}" ]; then
	_b=$(basename -- "${1:-}")
	if [ "$_b" = "$WTFBSD_TEST_UMOUNT_FAIL" ]; then
		printf 'umount: cannot unmount\n' >&2
		exit 1
	fi
fi
if [ -n "${WTFBSD_TEST_UMOUNT_TREE:-}" ] && [ -d "${1:-}" ]; then
	_b=$(basename -- "$1")
	mkdir -p "$WTFBSD_TEST_UMOUNT_TREE/$_b"
	cp -R "$1/." "$WTFBSD_TEST_UMOUNT_TREE/$_b/" 2> /dev/null
fi
exit 0
STUB

# rdsetroot(8): -x writes the ramdisk image; without -x the ramdisk image
# is written back into the kernel, which then differs from the stock one
cat > "$_mstub/rdsetroot" <<'STUB'
#!/bin/sh
printf 'rdsetroot %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
if [ "${1:-}" = -x ]; then
	: > "$3"
else
	printf 'the ramdisk written back\n' >> "$1"
fi
exit 0
STUB

# gzip(1): logged, then the real gzip
cat > "$_mstub/gzip" <<'STUB'
#!/bin/sh
printf 'gzip %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
exec env PATH="$(command -p getconf PATH 2> /dev/null || printf /usr/bin:/bin)" gzip "$@"
STUB

# mkhybrid(8): the tree it is given (the last argument) is copied aside,
# and the image is a file that names it
cat > "$_mstub/mkhybrid" <<'STUB'
#!/bin/sh
printf 'mkhybrid %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_out=''
_prev=''
_tree=''
for _a in "$@"; do
	if [ "$_prev" = -o ]; then _out=$_a; fi
	_prev=$_a
	_tree=$_a
done
if [ -d "$_tree" ] && [ -n "${WTFBSD_TEST_MKHYBRID_TREE:-}" ]; then
	mkdir -p "$WTFBSD_TEST_MKHYBRID_TREE"
	cp -R "$_tree/." "$WTFBSD_TEST_MKHYBRID_TREE/" 2> /dev/null
fi
[ -z "$_out" ] || printf 'the image of mkhybrid\n' > "$_out"
exit 0
STUB
chmod +x "$_mstub"/*

# --- the input tar, built byte by byte -----------------------------------
#
# The ustar header of POSIX pax(1) (and tar(5)): 512 bytes, name at 0
# (100), mode 100 (8), uid 108 (8), gid 116 (8), size 124 (12: 11 octal
# digits and a NUL), mtime 136 (12), chksum 148 (8: 6 octal digits, a NUL
# and a space, summed over the header with the field as 8 spaces),
# typeflag 156, linkname 157 (100), magic "ustar\0" 257, version "00"
# 263, prefix 345 (155). The data follows, padded to 512, and the archive
# ends with two zero blocks. The headers are built here, so a test of a
# type flag never depends on the tar of the host.

# tar_put <file> <offset> <printf format> [args] — write bytes in place
tar_put() {
	_tpf=$1
	_tpo=$2
	shift 2
	# shellcheck disable=SC2059
	printf "$@" | dd of="$_tpf" bs=1 seek="$_tpo" conv=notrunc 2> /dev/null
}

# tar_hdr <out> <name format> <typeflag|''> <size> [<linkname>] [<prefix>]
#         [ustar|gnu|none] [badsum] — append one header to <out>
tar_hdr() {
	_th=$work/tar-hdr
	dd if=/dev/zero of="$_th" bs=512 count=1 2> /dev/null
	tar_put "$_th" 0 "$2"
	tar_put "$_th" 100 '%s' 0000644
	tar_put "$_th" 108 '%s' 0001750
	tar_put "$_th" 116 '%s' 0001750
	tar_put "$_th" 124 '%011o' "$4"
	tar_put "$_th" 136 '%011o' 1700000000
	[ -z "$3" ] || tar_put "$_th" 156 '%s' "$3"
	[ -z "${5:-}" ] || tar_put "$_th" 157 '%s' "$5"
	case ${7:-ustar} in
	ustar)
		tar_put "$_th" 257 'ustar\000'
		tar_put "$_th" 263 '%s' 00
		;;
	gnu) tar_put "$_th" 257 'ustar  \000' ;;
	esac
	[ -z "${6:-}" ] || tar_put "$_th" 345 '%s' "$6"
	tar_put "$_th" 148 '%s' '        '
	_ts=$(od -An -v -tu1 "$_th" | awk '{ for (i = 1; i <= NF; i++) s += $i } END { print s }')
	[ -z "${8:-}" ] || _ts=$((_ts + 1))
	tar_put "$_th" 148 '%06o\000 ' "$_ts"
	cat "$_th" >> "$1"
}
# tar_data <out> <file> — append the data of a member, padded to 512
tar_data() {
	cat "$2" >> "$1"
	_tds=$(wc -c < "$2" | tr -d ' ')
	_tdp=$(((512 - _tds % 512) % 512))
	[ "$_tdp" -eq 0 ] || dd if=/dev/zero bs=1 count="$_tdp" 2> /dev/null >> "$1"
}
# tar_file <out> <name> <file> — append a regular member
tar_file() {
	tar_hdr "$1" "$2" 0 "$(wc -c < "$3" | tr -d ' ')"
	tar_data "$1" "$3"
}
# tar_end <out> — the two zero blocks of the end of the archive
tar_end() {
	dd if=/dev/zero bs=512 count=2 2> /dev/null >> "$1"
}

# The two inputs: a site set (a gzip file) and a response file.
_staging=$work/staging
mkdir -p "$_staging"
printf 'the site set\n' | gzip -c > "$_staging/site.tgz"
printf 'Location of sets = http\nHTTP Server = sets.example.org\nPathname to the sets = pub/OpenBSD\n' > "$_staging/install.conf"

IN_OK=$work/in-ok.tar
: > "$IN_OK"
tar_file "$IN_OK" site.tgz "$_staging/site.tgz"
tar_file "$IN_OK" install.conf "$_staging/install.conf"
tar_end "$IN_OK"

# The archive the suite builds is one tar(1) reads: the format is real.
_lst=$(tar -tf "$IN_OK" 2> /dev/null | tr '\n' ' ')
mkdir -p "$work/in-ok-x"
if [ "$_lst" = 'site.tgz install.conf ' ] \
	&& tar -xf "$IN_OK" -C "$work/in-ok-x" 2> /dev/null \
	&& cmp -s "$work/in-ok-x/site.tgz" "$_staging/site.tgz" \
	&& cmp -s "$work/in-ok-x/install.conf" "$_staging/install.conf"; then
	ok 'the tar the suite builds byte by byte is read by tar(1)'
else
	no "the tar the suite builds byte by byte is read by tar(1) (lists: $_lst)"
fi

# --- the stock image of the media node -------------------------------------
#
# The tree of the image: the directory of the release holds the sets and
# the ramdisk, with the raw names (8.0/amd64/bsd.rd). It holds the EFI
# boot file (eficdboot) and no index.txt, as install80.iso does.
_isotree=$work/isotree
mkdir -p "$_isotree/8.0/amd64"
printf 'the ramdisk of the release\n' | gzip -c > "$_isotree/8.0/amd64/bsd.rd"
printf 'the boot file\n' > "$_isotree/8.0/amd64/cdbr"
printf 'the catalog\n' > "$_isotree/8.0/amd64/boot.catalog"
printf 'the efi boot file\n' > "$_isotree/8.0/amd64/eficdboot"
printf 'the base set\n' > "$_isotree/8.0/amd64/base80.tgz"

# stock_dir <name> — a stock directory: install80.iso and SHA256.8.0, in
# the format of the release's SHA256.sig (signify(1) -C checks it): an
# untrusted comment line, the base64 signature, then "SHA256 (file) = hex"
stock_dir() {
	_sd=$work/stock-$1
	mkdir -p "$_sd"
	printf 'the stock install image of the release 8.0\n' > "$_sd/install80.iso"
	{
		printf 'untrusted comment: verify with openbsd-80-base.pub\n'
		printf 'RWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
		printf 'SHA256 (base80.tgz) = %s\n' "$(sha_of "$_isotree/8.0/amd64/base80.tgz")"
		printf 'SHA256 (install80.iso) = %s\n' "$(sha_of "$_sd/install80.iso")"
		printf 'SHA256 (bsd.rd) = %s\n' "$(sha_of "$_isotree/8.0/amd64/bsd.rd")"
	} > "$_sd/SHA256.8.0"
	chmod 0444 "$_sd/install80.iso" "$_sd/SHA256.8.0"
	chmod 0755 "$_sd"
	printf '%s' "$_sd"
}

STOCK=$(stock_dir run)
STOCK_ISO=$STOCK/install80.iso
cp "$STOCK_ISO" "$work/stock-iso.before"
MEDIA_RUN=$(media_copy run "$STOCK")
if grep -q "^STOCK_DIR=$STOCK\$" "$MEDIA_RUN" 2> /dev/null; then
	ok 'the copy of the helper the suite runs uses the stock directory of the suite'
else
	no 'the copy of the helper the suite runs uses the stock directory of the suite'
fi

# runmedia <helper> <tar> <release> <arch> [NAME=VALUE ...] — run the
# helper with the stubs, the tar on stdin; RUNBASE holds out, err,
# argv.log, mkd.log (the work directory), mtree (the mount points at
# their unmount) and htree (the tree mkhybrid was given)
_mrun=0
runmedia() {
	_rh=$1
	_rt=$2
	_rr=$3
	_ra=$4
	shift 4
	_mrun=$((_mrun + 1))
	RUNBASE=$work/run-$_mrun
	mkdir -p "$RUNBASE"
	: > "$RUNBASE/argv.log"
	env PATH="$_mstub:$PATH" \
		WTFBSD_TEST_UID="$_uid" \
		WTFBSD_TEST_ARGV="$RUNBASE/argv.log" \
		WTFBSD_TEST_ISO_TREE="$_isotree" \
		WTFBSD_TEST_MKDLOG="$RUNBASE/mkd.log" \
		WTFBSD_TEST_VND_COUNT="$RUNBASE/vc" \
		WTFBSD_TEST_MOUNT_COUNT="$RUNBASE/mc" \
		WTFBSD_TEST_VND_STATE="$RUNBASE/vs" \
		WTFBSD_TEST_UMOUNT_TREE="$RUNBASE/mtree" \
		WTFBSD_TEST_MKHYBRID_TREE="$RUNBASE/htree" \
		"$@" \
		sh "$_rh" prepare "$_rr" "$_ra" < "$_rt" > "$RUNBASE/out" 2> "$RUNBASE/err"
}
# runmedia_bg — the same, in the background; the pid is in _bgpid
runmedia_bg() {
	_rh=$1
	_rt=$2
	shift 2
	_mrun=$((_mrun + 1))
	RUNBASE=$work/run-$_mrun
	mkdir -p "$RUNBASE"
	: > "$RUNBASE/argv.log"
	env PATH="$_mstub:$PATH" \
		WTFBSD_TEST_UID="$_uid" \
		WTFBSD_TEST_ARGV="$RUNBASE/argv.log" \
		WTFBSD_TEST_ISO_TREE="$_isotree" \
		WTFBSD_TEST_MKDLOG="$RUNBASE/mkd.log" \
		WTFBSD_TEST_VND_COUNT="$RUNBASE/vc" \
		WTFBSD_TEST_MOUNT_COUNT="$RUNBASE/mc" \
		WTFBSD_TEST_VND_STATE="$RUNBASE/vs" \
		"$@" \
		sh "$_rh" prepare 8.0 amd64 < "$_rt" > "$RUNBASE/out" 2> "$RUNBASE/err" &
	_bgpid=$!
}
# wait_log <file> <pattern> — wait (10 s at most) for a line of the log
wait_log() {
	_wi=0
	while [ "$_wi" -lt 100 ]; do
		grep -q "$2" "$1" 2> /dev/null && return 0
		sleep 0.1
		_wi=$((_wi + 1))
	done
	return 1
}
# the work directory of the run of RUNBASE
run_wd() { head -n 1 "$RUNBASE/mkd.log" 2> /dev/null; }
# refused <what> — the run failed and wrote nothing to stdout
refused() {
	if [ "$1" -ne 0 ] && [ ! -s "$RUNBASE/out" ]; then
		ok "$2"
	else
		no "$2 (status $1, see $RUNBASE/err)"
	fi
}
# err_has <pattern> <what>
err_has() {
	if grep -q -- "$1" "$RUNBASE/err" 2> /dev/null; then
		ok "$2"
	else
		no "$2 (stderr: $(tr '\n' ' ' < "$RUNBASE/err" 2> /dev/null))"
	fi
}
# attached_nothing <what> — the run refused before it attached the image
attached_nothing() {
	if grep -q '^vnconfig\|^mount' "$RUNBASE/argv.log" 2> /dev/null; then
		no "$1"
	else
		ok "$1"
	fi
}

# --- the helper builds the image ------------------------------------------

printf '== the media helper builds the image ==\n'

runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64
_rc=$?
_ok=$RUNBASE
_wd=$(run_wd)
_mlog=$_ok/argv.log
if [ "$_rc" -eq 0 ]; then
	ok 'the media helper prepares the media'
else
	no "the media helper prepares the media (see $_ok/err)"
fi
if [ "$(cat "$_ok/out" 2> /dev/null)" = 'the image of mkhybrid' ]; then
	ok 'the media helper writes the image it rebuilt to stdout'
else
	no 'the media helper writes the image it rebuilt to stdout'
fi

# the work directory: mktemp -d with the template, a directory that is
# gone when the run ends
if grep -qx 'mktemp -d /tmp/wtfbsd-media.XXXXXX' "$_mlog" 2> /dev/null; then
	ok 'the media helper makes its work directory with mktemp -d /tmp/wtfbsd-media.XXXXXX'
else
	no 'the media helper makes its work directory with mktemp -d /tmp/wtfbsd-media.XXXXXX'
fi
case $_wd in
/tmp/wtfbsd-media.??????) ok 'the work directory has the shape of the template' ;;
*) no "the work directory has the shape of the template (got: $_wd)" ;;
esac
if [ -n "$_wd" ] && [ ! -e "$_wd" ]; then
	ok 'the media helper removes its work directory when the run ends'
else
	no 'the media helper removes its work directory when the run ends'
fi

# the response file goes into the root of the ramdisk of bsd.rd, where
# install.sub reads it, and never into the tree of the CD
if [ -f "$_ok/mtree/mnt-rd/auto_install.conf" ]; then
	ok 'the media helper puts the response file into the ramdisk of bsd.rd'
else
	no 'the media helper puts the response file into the ramdisk of bsd.rd'
fi
if [ ! -e "$_ok/htree/auto_install.conf" ]; then
	ok 'the media helper puts no response file in the root of the CD'
else
	no 'the media helper puts no response file in the root of the CD'
fi
if [ -z "$(find "$_ok/htree" -name auto_install.conf 2> /dev/null)" ]; then
	ok 'the media helper puts no response file in the tree of the CD'
else
	no 'the media helper puts no response file in the tree of the CD'
fi
if cmp -s "$_ok/htree/8.0/amd64/site80.tgz" "$_staging/site.tgz"; then
	ok 'the media helper puts the site set with the sets of the release'
else
	no 'the media helper puts the site set with the sets of the release'
fi
if [ ! -e "$_ok/mtree/mnt/8.0/amd64/site80.tgz" ] && cmp -s "$STOCK_ISO" "$work/stock-iso.before"; then
	ok 'the media helper writes nothing into the stock image'
else
	no 'the media helper writes nothing into the stock image'
fi

# the stock image is mounted read-only, without devices and setuid; the
# ramdisk is mounted from the device vnconfig(8) allocated for it
if grep -q '^mount -t cd9660 -o rdonly,nodev,nosuid /dev/vnd0c ' "$_mlog" 2> /dev/null; then
	ok 'the media helper mounts the stock image read-only, nodev, nosuid'
else
	no 'the media helper mounts the stock image read-only, nodev, nosuid'
fi
if grep -q '^mount /dev/vnd1a ' "$_mlog" 2> /dev/null; then
	ok 'the media helper mounts the ramdisk of bsd.rd'
else
	no 'the media helper mounts the ramdisk of bsd.rd'
fi
if grep -q '^rdsetroot -x ' "$_mlog" 2> /dev/null \
	&& grep -q '^rdsetroot [^-].*/rd\.img$' "$_mlog" 2> /dev/null; then
	ok 'the media helper writes the ramdisk back with rdsetroot'
else
	no 'the media helper writes the ramdisk back with rdsetroot'
fi

# the response file: the sets are on cd0, in <release>/<arch>
_resp=$_ok/mtree/mnt-rd/auto_install.conf
if grep -qx 'Location of sets = cd0' "$_resp" 2> /dev/null; then
	ok 'the response file points the installer at the sets of the CD'
else
	no 'the response file points the installer at the sets of the CD'
fi
if grep -qx 'Pathname to the sets = 8.0/amd64' "$_resp" 2> /dev/null \
	&& [ "$(grep -c '^Pathname to the sets' "$_resp" 2> /dev/null)" -eq 1 ]; then
	ok 'the response file names the path of the sets'
else
	no 'the response file names the path of the sets'
fi
if grep -q 'HTTP Server' "$_resp" 2> /dev/null; then
	no 'the response file names no server of the sets'
else
	ok 'the response file names no server of the sets'
fi

# mkhybrid(8) with the raw paths of the tree (src/distrib/amd64/cdfs)
_mkh=$(grep '^mkhybrid ' "$_mlog" 2> /dev/null | head -n 1)
if [ -n "$_mkh" ]; then
	ok 'the media helper rebuilds the image with mkhybrid'
else
	no 'the media helper rebuilds the image with mkhybrid'
fi
case $_mkh in
*' -b 8.0/amd64/cdbr '*) ok 'mkhybrid gets the raw path of the boot image' ;;
*) no 'mkhybrid gets the raw path of the boot image' ;;
esac
case $_mkh in
*' -c 8.0/amd64/boot.catalog '*) ok 'mkhybrid gets the raw path of the catalog' ;;
*) no 'mkhybrid gets the raw path of the catalog' ;;
esac
case $_mkh in
*' -e 8.0/amd64/eficdboot '*) ok 'mkhybrid gets the raw path of the EFI boot file' ;;
*) no 'mkhybrid gets the raw path of the EFI boot file' ;;
esac
case $_mkh in
*'eltorito'*) no 'mkhybrid gets no El Torito image that the media does not hold' ;;
*) ok 'mkhybrid gets no El Torito image that the media does not hold' ;;
esac
case $_mkh in
*'8_0'* | *';1'*) no 'mkhybrid gets the raw names of the tree' ;;
*'mkhybrid -a '*' -N '*) ok 'mkhybrid gets the raw names of the tree' ;;
*) no 'mkhybrid gets the raw names of the tree (-a and -N, as the cdfs Makefile)' ;;
esac

# the output is $WORK/out.iso, never the name of an input
_outp=$(printf '%s\n' "$_mkh" | sed -n 's/.* -o \([^ ]*\) .*/\1/p')
if [ -n "$_wd" ] && [ "$_outp" = "$_wd/out.iso" ]; then
	ok 'the media helper writes the image to $WORK/out.iso'
else
	no "the media helper writes the image to \$WORK/out.iso (got: $_outp)"
fi
case $_outp in
"$STOCK_ISO" | */site.tgz | */install.conf | */input.tar | */install.iso | '')
	no "the media helper never writes the image to an input path (got: $_outp)" ;;
*) ok 'the media helper never writes the image to an input path' ;;
esac
if [ ! -e "$repo/media.iso" ] && [ ! -e "$work/media.iso" ]; then
	ok 'the media helper writes no image outside its work directory'
else
	no 'the media helper writes no image outside its work directory'
fi

# the ramdisk of the image is the one of the run
if [ -f "$_ok/htree/8.0/amd64/bsd.rd" ]; then
	ok 'the tree the image is built from holds a bsd.rd'
else
	no 'the tree the image is built from holds a bsd.rd'
fi
if cmp -s "$_ok/htree/8.0/amd64/bsd.rd" "$_isotree/8.0/amd64/bsd.rd" 2> /dev/null; then
	no 'the bsd.rd of the image is not the bsd.rd of the media'
else
	ok 'the bsd.rd of the image is not the bsd.rd of the media'
fi
if grep -q '^gzip -9n ' "$_mlog" 2> /dev/null; then
	ok 'the media helper compresses the ramdisk with gzip -9n'
else
	no 'the media helper compresses the ramdisk with gzip -9n'
fi

# install80.iso holds no index.txt, and the helper creates none
if [ -z "$(find "$_ok/htree" -name index.txt 2> /dev/null)" ]; then
	ok 'the media helper creates no index.txt'
else
	no 'the media helper creates no index.txt'
fi
if grep -q 'index.txt' "$_ok/err" 2> /dev/null; then
	no 'the log of the helper mentions no index.txt'
else
	ok 'the log of the helper mentions no index.txt'
fi
# that check can fail: a copy of the helper that writes an index.txt of
# its own is caught by the tree the image is built from
sed -e 's|^log "site set: /\$RELEASE/\$ARCH/\$SITENAME"$|&; printf "x\\n" > "$SETDIR/index.txt"|' \
	"$MEDIA_RUN" > "$work/media-index-own.sh"
if grep -q 'printf "x\\n" > "\$SETDIR/index.txt"' "$work/media-index-own.sh" 2> /dev/null; then
	runmedia "$work/media-index-own.sh" "$IN_OK" 8.0 amd64
	if [ -n "$(find "$RUNBASE/htree" -name index.txt 2> /dev/null)" ]; then
		ok 'the tree the image is built from holds an index.txt a helper wrote'
	else
		no 'the tree the image is built from holds an index.txt a helper wrote'
	fi
else
	no 'the copy of the helper that writes an index.txt was made'
fi

# the log names the files where they are in the image, and never a path
# of the work directory
if grep -q 'site set: /8\.0/amd64/site80\.tgz' "$_ok/err" 2> /dev/null; then
	ok 'the log of the media helper names the site set in the image'
else
	no 'the log of the media helper names the site set in the image'
fi
if grep -q 'response file: /auto_install\.conf in the ramdisk of bsd\.rd' "$_ok/err" 2> /dev/null; then
	ok 'the log of the media helper names the response file in the ramdisk'
else
	no 'the log of the media helper names the response file in the ramdisk'
fi
if grep -q '/tmp/wtfbsd-media\.' "$_ok/err" 2> /dev/null; then
	no 'the log of the media helper prints no path of the work directory'
else
	ok 'the log of the media helper prints no path of the work directory'
fi

# The whole run is exact: these commands, in this order, and no other.
_seen=$(grep -E '^(uname|id|sha256|mktemp|vnconfig|mount|umount|rdsetroot|gzip|mkhybrid) ' "$_mlog" 2> /dev/null \
	| sed -e "s|${_wd:-/nonexistent}|W|g" -e "s|$work|T|g" \
		-e 's|Copyright (c) [0-9]\{4\}|Copyright (c) <year>|')
_want='uname -s
id -u
sha256 -q T/stock-run/install80.iso
mktemp -d /tmp/wtfbsd-media.XXXXXX
vnconfig T/stock-run/install80.iso
mount -t cd9660 -o rdonly,nodev,nosuid /dev/vnd0c W/mnt
umount W/mnt
vnconfig -u vnd0
gzip -dc W/tree/8.0/amd64/bsd.rd
rdsetroot -x W/bsd.rd.raw W/rd.img
vnconfig W/rd.img
mount /dev/vnd1a W/mnt-rd
umount W/mnt-rd
vnconfig -u vnd1
rdsetroot W/bsd.rd.raw W/rd.img
gzip -9n W/bsd.rd.raw
mkhybrid -a -R -T -L -l -d -D -N -o W/out.iso -v -v -A OpenBSD 8.0 amd64 Install CD -P Copyright (c) <year> The OpenBSD Project -p The OpenBSD Project -V OpenBSD/amd64 8.0 Install CD -b 8.0/amd64/cdbr -c 8.0/amd64/boot.catalog -e 8.0/amd64/eficdboot W/tree'
if [ "$_seen" = "$_want" ]; then
	ok 'the media helper runs its commands in the order of the run'
else
	no "the media helper runs its commands in the order of the run (got: $_seen)"
fi

# nothing outside the work directory: every absolute path the tools were
# given is under the work directory, a device, or the stock image
_outside=''
for _p in $(grep -E '^(vnconfig|mount|umount|rdsetroot|gzip|mkhybrid) ' "$_mlog" 2> /dev/null \
	| tr ' ' '\n' | grep '^/' | sort -u); do
	case $_p in
	"$_wd"/* | /dev/vnd[0-9][ac] | "$STOCK_ISO") ;;
	*) _outside="$_outside $_p" ;;
	esac
done
if [ -n "$_wd" ] && [ -z "$_outside" ]; then
	ok 'the media helper touches nothing outside its work directory'
else
	no "the media helper touches nothing outside its work directory (got:$_outside)"
fi

# The cleanup is exact: every mount once, every device once, each mount
# point before its device, the mount points under the work directory.
_umounts=$(grep -c '^umount ' "$_mlog" 2> /dev/null)
_detaches=$(grep -c '^vnconfig -u ' "$_mlog" 2> /dev/null)
if [ "$_umounts" -eq 2 ] && [ "$_detaches" -eq 2 ]; then
	ok 'the media helper unmounts every mount once and detaches every device once'
else
	no "the media helper unmounts every mount once and detaches every device once (umount: $_umounts, vnconfig -u: $_detaches)"
fi
_mnt_cd=$(grep '^mount -t cd9660 ' "$_mlog" 2> /dev/null | head -n 1 | awk '{ print $NF }')
_mnt_rd=$(grep '^mount /dev/' "$_mlog" 2> /dev/null | head -n 1 | awk '{ print $NF }')
_dev_cd=$(grep '^mount -t cd9660 ' "$_mlog" 2> /dev/null | head -n 1 | awk '{ print $(NF - 1) }' | sed -e 's|^/dev/||' -e 's|c$||')
_dev_rd=$(grep '^mount /dev/' "$_mlog" 2> /dev/null | head -n 1 | awk '{ print $2 }' | sed -e 's|^/dev/||' -e 's|a$||')
_um_cd=$(grep '^umount ' "$_mlog" 2> /dev/null | sed -n '1s/^umount //p')
_um_rd=$(grep '^umount ' "$_mlog" 2> /dev/null | sed -n '2s/^umount //p')
_de_cd=$(grep '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '1s/^vnconfig -u //p')
_de_rd=$(grep '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '2s/^vnconfig -u //p')
if [ -n "$_mnt_cd" ] && [ "$_um_cd" = "$_mnt_cd" ] && [ "$_um_rd" = "$_mnt_rd" ]; then
	ok 'the media helper unmounts exactly the mount points it mounted'
else
	no "the media helper unmounts exactly the mount points it mounted (mounted: $_mnt_cd $_mnt_rd; unmounted: $_um_cd $_um_rd)"
fi
if [ -n "$_dev_cd" ] && [ "$_de_cd" = "$_dev_cd" ] && [ "$_de_rd" = "$_dev_rd" ]; then
	ok 'the media helper detaches exactly the devices it attached'
else
	no "the media helper detaches exactly the devices it attached (attached: $_dev_cd $_dev_rd; detached: $_de_cd $_de_rd)"
fi
case $_mnt_cd:$_mnt_rd in
"$_wd/mnt:$_wd/mnt-rd") ok 'the mount points of the media helper are under the work directory of the run' ;;
*) no "the mount points of the media helper are under the work directory of the run (got: $_mnt_cd and $_mnt_rd)" ;;
esac
_umn_cd=$(grep -n '^umount ' "$_mlog" 2> /dev/null | sed -n '1s/:.*//p')
_den_cd=$(grep -n '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '1s/:.*//p')
_umn_rd=$(grep -n '^umount ' "$_mlog" 2> /dev/null | sed -n '2s/:.*//p')
_den_rd=$(grep -n '^vnconfig -u ' "$_mlog" 2> /dev/null | sed -n '2s/:.*//p')
if [ -n "$_umn_cd" ] && [ -n "$_den_cd" ] && [ "$_umn_cd" -lt "$_den_cd" ]; then
	ok 'the media helper unmounts the media before it detaches its device'
else
	no 'the media helper unmounts the media before it detaches its device'
fi
if [ -n "$_umn_rd" ] && [ -n "$_den_rd" ] && [ "$_umn_rd" -lt "$_den_rd" ]; then
	ok 'the media helper unmounts the ramdisk before it detaches its device'
else
	no 'the media helper unmounts the ramdisk before it detaches its device'
fi
if [ -n "$_dev_cd" ] && [ -n "$_dev_rd" ] && [ "$_dev_cd" != "$_dev_rd" ]; then
	ok 'the media helper uses a device of its own for the media and for the ramdisk'
else
	no 'the media helper uses a device of its own for the media and for the ramdisk'
fi

# A media that holds an index.txt: the site set is listed in it once, and
# no index.txt is created anywhere else.
_isotree_idx=$work/isotree-index
cp -R "$_isotree" "$_isotree_idx"
printf 'base80.tgz\n' > "$_isotree_idx/8.0/amd64/index.txt"
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_isotree_idx"
if [ "$?" -eq 0 ]; then
	ok 'the media helper prepares a media that holds an index.txt'
else
	no "the media helper prepares a media that holds an index.txt (see $RUNBASE/err)"
fi
if grep -qx 'site80.tgz' "$RUNBASE/htree/8.0/amd64/index.txt" 2> /dev/null \
	&& grep -qx 'base80.tgz' "$RUNBASE/htree/8.0/amd64/index.txt" 2> /dev/null; then
	ok 'the media helper lists the site set in the index.txt of the media'
else
	no 'the media helper lists the site set in the index.txt of the media'
fi
if [ "$(grep -c '^site80\.tgz$' "$RUNBASE/htree/8.0/amd64/index.txt" 2> /dev/null)" = 1 ]; then
	ok 'the media helper lists the site set once'
else
	no 'the media helper lists the site set once'
fi
if [ -e "$RUNBASE/htree/index.txt" ]; then
	no 'the media helper creates no index.txt in the root of the CD'
else
	ok 'the media helper creates no index.txt in the root of the CD'
fi
# an index.txt that already lists the site set is left as it is
printf 'base80.tgz\nsite80.tgz\n' > "$_isotree_idx/8.0/amd64/index.txt"
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_isotree_idx"
if [ "$(grep -c '^site80\.tgz$' "$RUNBASE/htree/8.0/amd64/index.txt" 2> /dev/null)" = 1 ]; then
	ok 'the media helper lists the site set once when the index.txt already lists it'
else
	no 'the media helper lists the site set once when the index.txt already lists it'
fi

# --- the input on stdin: two plain members, checked by their header bytes

printf '== the media helper reads the tar headers itself ==\n'

# in_tar <name> <hdr args...> — a tar: one crafted header, then the data
# of install.conf for a member of that name, then the regular members
# that are not that name, then the end of the archive
_conf=$_staging/install.conf
_site=$_staging/site.tgz
_conf_n=$(wc -c < "$_conf" | tr -d ' ')

# a hard link (type flag 1) named install.conf, linking site.tgz
_t=$work/in-hard.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_hdr "$_t" install.conf 1 0 site.tgz
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a hard link member (type flag 1) is refused, nothing on stdout'
err_has 'type flag 0x31' 'the refusal of a hard link names its type flag'
attached_nothing 'a hard link member is refused before the stock image is attached'
# OpenBSD tar lists a hard link as '-rw-r--r-- ... install.conf == site.tgz':
# a tar whose listing says '-' for every member changes nothing
_mstub_tv=$work/mediastub-tv
mkdir -p "$_mstub_tv"
cat > "$_mstub_tv/tar" <<'STUB'
#!/bin/sh
case ${1:-} in
-t*)
	printf '%s\n' '-rw-r--r--  1 build    build          28 Jan  1 00:00 site.tgz' \
		'-rw-r--r--  1 build    build           0 Jan  1 00:00 install.conf == site.tgz'
	exit 0
	;;
esac
exec env PATH="$WTFBSD_TEST_REALPATH" tar "$@"
STUB
chmod +x "$_mstub_tv/tar"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64 PATH="$_mstub_tv:$_mstub:$PATH" WTFBSD_TEST_REALPATH="$PATH"
refused "$?" 'a hard link member is refused even when tar -tv lists it with a leading -'

# a symbolic link (type flag 2) named install.conf
_t=$work/in-sym.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_hdr "$_t" install.conf 2 0 /etc/master.passwd
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a symlink member (type flag 2) is refused, nothing on stdout'
err_has 'type flag 0x32' 'the refusal of a symlink names its type flag'

# a directory (type flag 5) named install.conf
_t=$work/in-dir.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_hdr "$_t" install.conf 5 0
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a directory member (type flag 5) is refused, nothing on stdout'
err_has 'type flag 0x35' 'the refusal of a directory names its type flag'

# extended headers: pax (x, g) and GNU (L, K), each named like a member
# the run accepts, followed by the member itself
for _x in x g L K; do
	_t=$work/in-ext-$_x.tar
	printf '30 path=site.tgz\n' > "$work/ext-rec"
	: > "$_t"
	tar_hdr "$_t" site.tgz "$_x" "$(wc -c < "$work/ext-rec" | tr -d ' ')"
	tar_data "$_t" "$work/ext-rec"
	tar_file "$_t" site.tgz "$_site"
	tar_file "$_t" install.conf "$_conf"
	tar_end "$_t"
	runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
	refused "$?" "an extended header (type flag $_x) is refused, nothing on stdout"
	err_has 'extended tar header' "the refusal of a type flag $_x header names the extended header"
done

# a regular member with type flag NUL (the old regular file) is accepted
_t=$work/in-nul.tar
: > "$_t"
tar_hdr "$_t" site.tgz '' "$(wc -c < "$_site" | tr -d ' ')"
tar_data "$_t" "$_site"
tar_file "$_t" install.conf "$_conf"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
if [ "$?" -eq 0 ]; then
	ok 'a regular member with type flag NUL is accepted'
else
	no "a regular member with type flag NUL is accepted (see $RUNBASE/err)"
fi

# names: a slash, a .., a name with bytes after its NUL, a prefix, a name
# the run does not know (install.iso: the image is not an input)
for _case in 'sub/site.tgz:slash' '../install.conf:dotdot' 'install.iso:iso' 'site.tgz\000junk:nuljunk'; do
	_nm=${_case%:*}
	_tag=${_case##*:}
	_t=$work/in-name-$_tag.tar
	: > "$_t"
	tar_file "$_t" install.conf "$_conf"
	tar_hdr "$_t" "$_nm" 0 "$(wc -c < "$_site" | tr -d ' ')"
	tar_data "$_t" "$_site"
	tar_end "$_t"
	runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
	refused "$?" "a member named $_tag is refused, nothing on stdout"
	err_has 'does not name' "the refusal of a member named $_tag names the member it refused"
done
_t=$work/in-prefix.tar
: > "$_t"
tar_file "$_t" install.conf "$_conf"
tar_hdr "$_t" site.tgz 0 "$(wc -c < "$_site" | tr -d ' ')" '' etc
tar_data "$_t" "$_site"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a member with a ustar prefix is refused, nothing on stdout'
err_has 'path prefix' 'the refusal of a ustar prefix names the prefix'

# a third member, a missing member, a member twice
_t=$work/in-extra.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_file "$_t" install.conf "$_conf"
tar_file "$_t" extra.tgz "$_site"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a third member is refused, nothing on stdout'
_t=$work/in-missing.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a missing member is refused, nothing on stdout'
_t=$work/in-twice.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_file "$_t" site.tgz "$_site"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a member given twice is refused, nothing on stdout'
err_has 'more than once' 'the refusal of a member given twice says so'

# the format: a bad checksum, no ustar magic, the GNU magic, no end
_t=$work/in-sum.tar
: > "$_t"
tar_hdr "$_t" site.tgz 0 "$(wc -c < "$_site" | tr -d ' ')" '' '' ustar badsum
tar_data "$_t" "$_site"
tar_file "$_t" install.conf "$_conf"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a header with a bad checksum is refused, nothing on stdout'
for _mg in none gnu; do
	_t=$work/in-magic-$_mg.tar
	: > "$_t"
	tar_hdr "$_t" site.tgz 0 "$(wc -c < "$_site" | tr -d ' ')" '' '' "$_mg"
	tar_data "$_t" "$_site"
	tar_file "$_t" install.conf "$_conf"
	tar_end "$_t"
	runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
	refused "$?" "a header with the magic $_mg is refused, nothing on stdout"
done
_t=$work/in-noend.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_file "$_t" install.conf "$_conf"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'a tar without its end blocks is refused, nothing on stdout'

# the caps: a copy of the helper with small caps (stdin 8192 bytes, the
# site set 1024, the response file 256)
MEDIA_CAPS=$(media_copy caps "$STOCK" 8192 1024 256)
dd if=/dev/zero bs=1 count=2000 2> /dev/null | tr '\000' 'a' > "$work/big-site.tgz"
_t=$work/in-bigsite.tar
: > "$_t"
tar_file "$_t" site.tgz "$work/big-site.tgz"
tar_file "$_t" install.conf "$_conf"
tar_end "$_t"
runmedia "$MEDIA_CAPS" "$_t" 8.0 amd64
refused "$?" 'a site set over its cap is refused, nothing on stdout'
err_has 'site.tgz of 2000 bytes' 'the refusal of a site set over its cap names its size'
dd if=/dev/zero bs=1 count=300 2> /dev/null | tr '\000' '#' > "$work/big.conf"
_t=$work/in-bigconf.tar
: > "$_t"
tar_file "$_t" site.tgz "$_site"
tar_file "$_t" install.conf "$work/big.conf"
tar_end "$_t"
runmedia "$MEDIA_CAPS" "$_t" 8.0 amd64
refused "$?" 'a response file over its cap is refused, nothing on stdout'
dd if=/dev/zero bs=1024 count=20 2> /dev/null > "$work/in-huge.tar"
runmedia "$MEDIA_CAPS" "$work/in-huge.tar" 8.0 amd64
refused "$?" 'stdin over its cap is refused, nothing on stdout'
err_has 'larger than 8192' 'the refusal of stdin over its cap names the cap'
attached_nothing 'stdin over its cap is refused before the stock image is attached'
runmedia "$MEDIA_CAPS" "$IN_OK" 8.0 amd64
if [ "$?" -eq 0 ]; then
	ok 'an input under the caps is accepted by the copy with small caps'
else
	no "an input under the caps is accepted by the copy with small caps (see $RUNBASE/err)"
fi

# --- the stock image: root-owned, signed, never an input ---------------

printf '== the media helper takes the stock image of the media node ==\n'

# a wrong sha256: the image is refused before it is attached
_s=$(stock_dir badsum)
chmod 0644 "$_s/install80.iso"
printf 'the image was changed\n' >> "$_s/install80.iso"
chmod 0444 "$_s/install80.iso"
runmedia "$(media_copy badsum "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a stock image with a wrong sha256 is refused, nothing on stdout'
err_has 'does not match' 'the refusal of a wrong sha256 says it does not match'
attached_nothing 'a stock image with a wrong sha256 is never attached'

_s=$(stock_dir nosums)
chmod 0755 "$_s"
rm -f "$_s/SHA256.8.0"
runmedia "$(media_copy nosums "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a stock image without the SHA256 file of its release is refused'
err_has 'SHA256.8.0' 'the refusal names the SHA256 file'

_s=$(stock_dir noiso)
rm -f "$_s/install80.iso"
runmedia "$(media_copy noiso "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a missing stock image is refused'
err_has "$_s/install80.iso" 'the refusal of a missing stock image names its path'

_s=$(stock_dir twice)
chmod 0644 "$_s/SHA256.8.0"
grep 'install80' "$_s/SHA256.8.0" > "$work/sums-twice-line"
cat "$work/sums-twice-line" >> "$_s/SHA256.8.0"
chmod 0444 "$_s/SHA256.8.0"
runmedia "$(media_copy twice "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a SHA256 file that names the image twice is refused'

_s=$(stock_dir symlink)
mv "$_s/install80.iso" "$work/stock-symlink-target.iso"
ln -s "$work/stock-symlink-target.iso" "$_s/install80.iso"
runmedia "$(media_copy symlink "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a stock image that is a symbolic link is refused'
err_has 'symbolic link' 'the refusal of a symlinked stock image says symbolic link'

_s=$(stock_dir sumslink)
mv "$_s/SHA256.8.0" "$work/stock-sums-target"
ln -s "$work/stock-sums-target" "$_s/SHA256.8.0"
runmedia "$(media_copy sumslink "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a SHA256 file that is a symbolic link is refused'

_s=$(stock_dir foreign)
runmedia "$(media_copy foreign "$_s")" "$IN_OK" 8.0 amd64 WTFBSD_TEST_STAT_FOREIGN="$_s/install80.iso"
refused "$?" 'a stock image not owned by root is refused'
err_has 'not owned by root' 'the refusal of a stock image not owned by root says so'

_s=$(stock_dir gwrite)
chmod 0464 "$_s/install80.iso"
runmedia "$(media_copy gwrite "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a group-writable stock image is refused'
_s=$(stock_dir owrite)
chmod 0446 "$_s/SHA256.8.0"
runmedia "$(media_copy owrite "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'an other-writable SHA256 file is refused'
err_has 'writable by the group or by others' 'the refusal of a writable file says so'
_s=$(stock_dir dwrite)
chmod 0777 "$_s"
runmedia "$(media_copy dwrite "$_s")" "$IN_OK" 8.0 amd64
refused "$?" 'a stock directory others can write is refused'
chmod 0755 "$_s"

# an input tar that carries the image is refused: the image is not input
_t=$work/in-iso.tar
: > "$_t"
tar_file "$_t" install.iso "$STOCK_ISO"
tar_file "$_t" site.tgz "$_site"
tar_file "$_t" install.conf "$_conf"
tar_end "$_t"
runmedia "$MEDIA_RUN" "$_t" 8.0 amd64
refused "$?" 'an input that carries an install.iso is refused'

# --- the work directory --------------------------------------------------

printf '== the work directory of the media helper ==\n'

runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_MKTEMP_FAKE="$work/not-the-template"
refused "$?" 'a work directory of another shape is refused'
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_MKTEMP_MODE=0755
refused "$?" 'a work directory that is not mode 0700 is refused'
rm_workdir "$(run_wd)"
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 'WTFBSD_TEST_STAT_FOREIGN=/tmp/wtfbsd-media.*'
refused "$?" 'a work directory not owned by root is refused'
rm_workdir "$(run_wd)"

# --- the tree of the stock image ------------------------------------------

printf '== the media helper follows no link of the stock image ==\n'

# 8.0/amd64 is a symbolic link to a directory outside the tree
_iso_sym=$work/isotree-symlink
_elsewhere=$work/elsewhere
mkdir -p "$_iso_sym/8.0" "$_elsewhere"
cp -R "$_isotree/8.0/amd64" "$_elsewhere/amd64"
ln -s "$_elsewhere/amd64" "$_iso_sym/8.0/amd64"
_before=$(cd "$_elsewhere" && find . -type f -exec cksum {} + | sort)
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_iso_sym"
refused "$?" 'a stock image whose 8.0/amd64 is a symbolic link is refused'
err_has 'not a regular file or a directory: 8.0/amd64' 'the refusal names the entry that is not a regular file or a directory'
if grep -q '^gzip \|^rdsetroot \|^mkhybrid ' "$RUNBASE/argv.log" 2> /dev/null; then
	no 'a stock image with a symbolic link is refused before any write'
else
	ok 'a stock image with a symbolic link is refused before any write'
fi
_after=$(cd "$_elsewhere" && find . -type f -exec cksum {} + | sort)
if [ "$_before" = "$_after" ] && [ ! -e "$_elsewhere/amd64/site80.tgz" ]; then
	ok 'the target of the symbolic link is left as it was'
else
	no 'the target of the symbolic link is left as it was'
fi
_sym_wd=$(run_wd)
if [ -n "$_sym_wd" ] && [ ! -e "$_sym_wd" ] && [ "$(grep -c '^vnconfig -u ' "$RUNBASE/argv.log")" -eq 1 ]; then
	ok 'the refusal of a symbolic link cleans up the mount and the device'
else
	no 'the refusal of a symbolic link cleans up the mount and the device'
fi

# a fifo in the tree is refused too
_iso_fifo=$work/isotree-fifo
cp -R "$_isotree" "$_iso_fifo"
if mkfifo "$_iso_fifo/8.0/amd64/fifo" 2> /dev/null; then
	runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_iso_fifo"
	refused "$?" 'a stock image that holds a fifo is refused'
fi

# The write guard stands alone: a copy of the helper without the check
# of the tree still refuses every path that is a link or resolves outside
# the tree, before it reads or writes it.
sed -e '/^refuse_odd_entries "\$MNT"$/d' "$MEDIA_RUN" > "$work/media-noodd.sh"
if [ "$(grep -c '^refuse_odd_entries "\$MNT"$' "$MEDIA_RUN")" -eq 1 ] \
	&& [ "$(grep -c '^refuse_odd_entries "\$MNT"$' "$work/media-noodd.sh")" -eq 0 ]; then
	runmedia "$work/media-noodd.sh" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_iso_sym"
	refused "$?" 'without the check of the tree, the write guard refuses a symlinked 8.0/amd64'
	err_has 'symbolic link in the tree' 'the write guard names the symbolic link'
	_after=$(cd "$_elsewhere" && find . -type f -exec cksum {} + | sort)
	if [ "$_before" = "$_after" ] && [ ! -e "$_elsewhere/amd64/site80.tgz" ]; then
		ok 'the write guard leaves the target of the symbolic link as it was'
	else
		no 'the write guard leaves the target of the symbolic link as it was'
	fi
	# bsd.rd is a link to a file outside the tree: never read
	_iso_rdl=$work/isotree-rdlink
	cp -R "$_isotree" "$_iso_rdl"
	printf 'a secret of the media node\n' > "$work/secret"
	rm -f "$_iso_rdl/8.0/amd64/bsd.rd"
	ln -s "$work/secret" "$_iso_rdl/8.0/amd64/bsd.rd"
	runmedia "$work/media-noodd.sh" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_iso_rdl"
	refused "$?" 'without the check of the tree, the write guard refuses a symlinked bsd.rd'
	if grep -q '^gzip ' "$RUNBASE/argv.log" 2> /dev/null; then
		no 'the write guard never reads through a symlinked bsd.rd'
	else
		ok 'the write guard never reads through a symlinked bsd.rd'
	fi
else
	no 'the copy of the helper without the check of the tree was made'
fi

# --- the EFI boot file ----------------------------------------------------

printf '== the media helper needs the EFI boot file ==\n'

_iso_noefi=$work/isotree-noefi
cp -R "$_isotree" "$_iso_noefi"
rm -f "$_iso_noefi/8.0/amd64/eficdboot"
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_ISO_TREE="$_iso_noefi"
refused "$?" 'the media helper refuses a media without an EFI boot file'
if grep -q 'eficdboot' "$RUNBASE/err" 2> /dev/null && grep -q 'UEFI' "$RUNBASE/err" 2> /dev/null; then
	ok 'the refusal of a media without an EFI boot file names the file and the machine'
else
	no 'the refusal of a media without an EFI boot file names the file and the machine'
fi
if grep -q '^mkhybrid ' "$RUNBASE/argv.log" 2> /dev/null; then
	no 'the media helper builds no image without an EFI boot file'
else
	ok 'the media helper builds no image without an EFI boot file'
fi

# --- the release and the architecture are arguments -----------------------

printf '== the release and the architecture are arguments of the helper ==\n'

runmedia "$MEDIA_RUN" "$IN_OK" '' amd64
refused "$?" 'the media helper refuses to run without a release'
err_has 'release' 'the refusal of a run without a release names the release'
runmedia "$MEDIA_RUN" "$IN_OK" 8.0.1 amd64
refused "$?" 'the media helper refuses a release that is not N.N'
err_has 'N.N' 'the refusal of a bad release names the shape of a release'
runmedia "$MEDIA_RUN" "$IN_OK" '' amd64 WTFBSD_RELEASE=8.0 RELEASE=8.0
refused "$?" 'the media helper ignores the release of the environment'
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 ''
refused "$?" 'the media helper refuses a run without an architecture'
err_has 'ARCH' 'the refusal of a run without an architecture names the architecture'
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 AMD64
refused "$?" 'the media helper refuses an architecture that is not a lowercase name'
err_has 'architecture' 'the refusal of a bad architecture names the architecture'
# the architecture of the environment is ignored: the argument names an
# architecture the media does not hold
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 aarch64 WTFBSD_ARCH=amd64 ARCH=amd64
refused "$?" 'the media helper ignores the architecture of the environment'
if grep -q '8\.0/aarch64' "$RUNBASE/err" 2> /dev/null; then
	ok 'the refusal of a missing architecture names the release and the architecture'
else
	no 'the refusal of a missing architecture names the release and the architecture'
fi

# --- the tools of OpenBSD -------------------------------------------------

printf '== the media helper needs OpenBSD and its tools ==\n'

_mstub_linux=$work/mediastub-linux
mkdir -p "$_mstub_linux"
cp "$_mstub"/* "$_mstub_linux/"
printf '#!/bin/sh\nprintf "Linux\\n"\n' > "$_mstub_linux/uname"
chmod +x "$_mstub_linux"/*
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 PATH="$_mstub_linux:$PATH"
refused "$?" 'the media helper refuses to run off OpenBSD'
err_has 'OpenBSD' 'the refusal off OpenBSD names OpenBSD'

_mstub_nord=$work/mediastub-nordsetroot
mkdir -p "$_mstub_nord"
cp "$_mstub"/* "$_mstub_nord/"
rm -f "$_mstub_nord/rdsetroot"
_mpath=$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -v 'sbin$' | paste -s -d: -)
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 PATH="$_mstub_nord:$_mpath"
refused "$?" 'the media helper refuses to run without rdsetroot'
err_has 'rdsetroot' 'the refusal without rdsetroot names the tool'

# --- the cleanup undoes only the steps that ran ---------------------------

printf '== the cleanup of the media helper ==\n'

# the attach of the ramdisk fails: the media was already unmounted and
# detached, and the device that could not be attached is never named
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_VND_FAIL_ON=2
refused "$?" 'the media helper fails when the ramdisk cannot be attached'
_fu=$(grep -c '^umount ' "$RUNBASE/argv.log")
_fd=$(grep -c '^vnconfig -u ' "$RUNBASE/argv.log")
if [ "$_fu" -eq 1 ] && [ "$_fd" -eq 1 ]; then
	ok 'the cleanup of the media helper unmounts and detaches once what was attached'
else
	no "the cleanup of the media helper unmounts and detaches once what was attached (umount: $_fu, vnconfig -u: $_fd)"
fi
if grep -q 'vnd1' "$RUNBASE/argv.log" 2> /dev/null; then
	no 'the cleanup of the media helper never mentions the device it could not attach'
else
	ok 'the cleanup of the media helper never mentions the device it could not attach'
fi
if [ "$(grep -c '^mount ' "$RUNBASE/argv.log")" -eq 1 ]; then
	ok 'the cleanup of the media helper mounts nothing after the failure'
else
	no 'the cleanup of the media helper mounts nothing after the failure'
fi

# the mount of the media fails: the device is detached, and nothing is
# unmounted, because nothing was mounted
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_MOUNT_FAIL_ON=1
refused "$?" 'the media helper fails when the media cannot be mounted'
err_has 'installNN\.iso' 'the refusal of a mount that fails names the image that is needed'
if [ "$(grep -c '^umount ' "$RUNBASE/argv.log")" -eq 0 ]; then
	ok 'the cleanup of the media helper unmounts no mount point that was never mounted'
else
	no 'the cleanup of the media helper unmounts no mount point that was never mounted'
fi
if [ "$(grep -c '^vnconfig -u ' "$RUNBASE/argv.log")" -eq 1 ]; then
	ok 'the cleanup of the media helper detaches the device it attached'
else
	no 'the cleanup of the media helper detaches the device it attached'
fi

# the unmount of the ramdisk fails: the helper fails, the cleanup tries
# again, detaches the device after the unmount, once, and the work
# directory stays where it is (a mount under it is still up)
runmedia "$MEDIA_RUN" "$IN_OK" 8.0 amd64 WTFBSD_TEST_UMOUNT_FAIL=mnt-rd
refused "$?" 'the media helper fails when the ramdisk cannot be unmounted'
err_has 'still mounted' 'the cleanup of the media helper names the mount that is still up'
_umn=$(grep -n '^umount .*/mnt-rd$' "$RUNBASE/argv.log" | tail -n 1 | cut -d: -f1)
_den=$(grep -n '^vnconfig -u vnd1$' "$RUNBASE/argv.log" | tail -n 1 | cut -d: -f1)
if [ -n "$_umn" ] && [ -n "$_den" ] && [ "$_umn" -lt "$_den" ]; then
	ok 'the cleanup of the media helper unmounts the ramdisk before it detaches its device'
else
	no 'the cleanup of the media helper unmounts the ramdisk before it detaches its device'
fi
if [ "$(grep -c '^vnconfig -u vnd1$' "$RUNBASE/argv.log")" -eq 1 ]; then
	ok 'the cleanup of the media helper detaches the device of the ramdisk once'
else
	no 'the cleanup of the media helper detaches the device of the ramdisk once'
fi
_kept=$(run_wd)
if [ -n "$_kept" ] && [ -d "$_kept" ]; then
	ok 'the work directory of the run stays where it is when a mount is still up'
else
	no 'the work directory of the run stays where it is when a mount is still up'
fi
rm_workdir "$_kept"

# --- the signals ----------------------------------------------------------

printf '== the media helper stops on a signal ==\n'

# signalled while the stock image is mounted: the trap cleans up and the
# helper exits with the code of the signal, so no step after it runs
runmedia_bg "$MEDIA_RUN" "$IN_OK" WTFBSD_TEST_MOUNT_SLEEP=2
_sl=$RUNBASE/argv.log
wait_log "$_sl" '^mount -t cd9660 '
kill -TERM "$_bgpid" 2> /dev/null
_mrc=0
wait "$_bgpid" || _mrc=$?
if [ "$_mrc" -eq 143 ]; then
	ok 'the media helper exits with the code of the signal'
else
	no "the media helper exits with the code of the signal (status $_mrc)"
fi
if [ ! -s "$RUNBASE/out" ]; then
	ok 'the media helper writes nothing to stdout when it is signalled'
else
	no 'the media helper writes nothing to stdout when it is signalled'
fi
_swd=$(run_wd)
if [ "$(grep -c '^umount ' "$_sl")" -eq 1 ] && [ "$(grep -c '^vnconfig -u ' "$_sl")" -eq 1 ]; then
	ok 'the media helper cleans up when it is signalled'
else
	no 'the media helper cleans up when it is signalled'
fi
case $(grep '^umount ' "$_sl" | head -n 1) in
"umount $_swd/mnt") ok 'the cleanup of the media helper unmounts the mount point it mounted, nothing outside its work directory' ;;
*) no "the cleanup of the media helper unmounts the mount point it mounted, nothing outside its work directory (got: $(grep '^umount ' "$_sl" | head -n 1))" ;;
esac
_su=$(grep -n '^umount ' "$_sl" | head -n 1 | cut -d: -f1)
_sd=$(grep -n '^vnconfig -u ' "$_sl" | head -n 1 | cut -d: -f1)
if [ -n "$_su" ] && [ -n "$_sd" ] && [ "$_su" -lt "$_sd" ]; then
	ok 'the cleanup of a signal unmounts the media before it detaches its device'
else
	no 'the cleanup of a signal unmounts the media before it detaches its device'
fi
if grep -q '^gzip \|^rdsetroot \|^mkhybrid ' "$_sl" 2> /dev/null; then
	no 'the media helper runs no step after a signal'
else
	ok 'the media helper runs no step after a signal'
fi
if [ -n "$_swd" ] && [ ! -e "$_swd" ]; then
	ok 'the cleanup of a signal removes the work directory'
else
	no 'the cleanup of a signal removes the work directory'
fi

# the same signal, with an unmount that fails: the cleanup runs once, the
# mount that is still up is named, the work directory stays
runmedia_bg "$MEDIA_RUN" "$IN_OK" WTFBSD_TEST_MOUNT_SLEEP=2 WTFBSD_TEST_UMOUNT_FAIL=mnt
_sl=$RUNBASE/argv.log
wait_log "$_sl" '^mount -t cd9660 '
kill -TERM "$_bgpid" 2> /dev/null
_mrc=0
wait "$_bgpid" || _mrc=$?
if [ "$_mrc" -eq 143 ]; then
	ok 'the media helper exits with the code of the signal when the unmount fails'
else
	no "the media helper exits with the code of the signal when the unmount fails (status $_mrc)"
fi
if [ "$(grep -c '^umount ' "$_sl")" -eq 1 ]; then
	ok 'the cleanup of the media helper runs once when it is signalled'
else
	no 'the cleanup of the media helper runs once when it is signalled'
fi
err_has 'still mounted' 'the cleanup of the media helper names the mount that is still up when it is signalled'
_kept=$(run_wd)
if [ -n "$_kept" ] && [ -d "$_kept" ]; then
	ok 'the work directory of the run stays where it is when the signal found a mount up'
else
	no 'the work directory of the run stays where it is when the signal found a mount up'
fi
rm_workdir "$_kept"

# signalled in the middle of the attach, before the unit was read: the
# cleanup finds the unit that covers the image with vnconfig -l
runmedia_bg "$MEDIA_RUN" "$IN_OK" WTFBSD_TEST_VND_SLEEP=2
_sl=$RUNBASE/argv.log
wait_log "$_sl" "^vnconfig $STOCK_ISO\$"
kill -TERM "$_bgpid" 2> /dev/null
_mrc=0
wait "$_bgpid" || _mrc=$?
if [ "$_mrc" -eq 143 ]; then
	ok 'the media helper exits with the code of the signal in the middle of the attach'
else
	no "the media helper exits with the code of the signal in the middle of the attach (status $_mrc)"
fi
if [ "$(grep -c '^vnconfig -u vnd0$' "$_sl")" -eq 1 ] && [ "$(grep -c '^vnconfig -l' "$_sl")" -ge 1 ]; then
	ok 'the cleanup detaches the one unit the run attached, found by vnconfig -l'
else
	no 'the cleanup detaches the one unit the run attached, found by vnconfig -l'
fi
# that check can fail: with the match of vnconfig -l broken, the cleanup
# detaches nothing
sed 's/if (path == img)/if (0)/' "$MEDIA_RUN" > "$work/media-broken-unit.sh"
if grep -q 'if (0)' "$work/media-broken-unit.sh"; then
	runmedia_bg "$work/media-broken-unit.sh" "$IN_OK" WTFBSD_TEST_VND_SLEEP=2
	_sl=$RUNBASE/argv.log
	wait_log "$_sl" "^vnconfig $STOCK_ISO\$"
	kill -TERM "$_bgpid" 2> /dev/null
	wait "$_bgpid" 2> /dev/null
	if [ "$(grep -c '^vnconfig -u ' "$_sl")" -eq 0 ]; then
		ok 'a broken vnconfig -l match is caught: the cleanup detaches no unit'
	else
		no 'a broken vnconfig -l match is caught: the cleanup detaches no unit'
	fi
else
	no 'the copy of the helper with a broken vnconfig -l match was made'
fi

# no work directory of the suite is left behind
for _d in $(cat "$work"/run-*/mkd.log 2> /dev/null); do
	rm_workdir "$_d"
done

# --- the Jenkinsfile: the media stage builds inputs.tar on stdin -------

printf '== the Jenkinsfile: the media stage (inputs.tar on stdin) ==\n'

_jfstage=$(jenkins_sh_with 'MEDIA_HELPER')

# the media stage fails when the media node holds no stock image, unless
# the build accepts a build without a boot test
if [ -n "$_jfstage" ]; then
	ok 'the media stage of the Jenkinsfile was found'
else
	no 'the media stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" ALLOW_NO_BOOT_TEST= \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	sh -c "$_jfstage" > "$work/medstage.log" 2>&1; then
	no 'the media stage fails when the media node holds no stock image'
else
	ok 'the media stage fails when the media node holds no stock image'
fi
grep -q '/usr/local/share/wtfbsd-media/install80\.iso' "$work/medstage.log" 2>/dev/null \
	&& ok 'the failure names the stock image of the media node' \
	|| no 'the failure names the stock image of the media node'
if env -i PATH="$PATH" VM_LIST="$work/vmlist" ALLOW_NO_BOOT_TEST=yes \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	sh -c "$_jfstage" > "$work/medstage2.log" 2>&1; then
	ok 'the media stage skips when ALLOW_NO_BOOT_TEST says so'
else
	no 'the media stage skips when ALLOW_NO_BOOT_TEST says so'
fi
# the stock image is not an input of the job: no parameter names it and
# the tar the stage feeds the helper does not carry it
if grep -q 'STOCK_MEDIA' "$JF" 2>/dev/null; then
	no 'the Jenkinsfile has no parameter for the stock image'
else
	ok 'the Jenkinsfile has no parameter for the stock image'
fi
if printf '%s\n' "$_jfstage" | grep -q 'install\.iso'; then
	no 'the media stage puts no install image into the input of the helper'
else
	ok 'the media stage puts no install image into the input of the helper'
fi

# the helper needs root, and the media node grants it with doas.conf(5).
# The rule names the installed copy of the helper, not the copy of the
# workspace.
if printf '%s\n' "$_jfstage" | grep -q 'doas "\$MEDIA_HELPER"'; then
	ok 'the media stage runs the helper through doas'
else
	no 'the media stage runs the helper through doas'
fi
if printf '%s\n' "$_jfstage" | grep -q 'doas .*ci/media\.sh'; then
	no 'the media stage runs no helper of the workspace'
else
	ok 'the media stage runs no helper of the workspace'
fi
if grep -q "name: 'MEDIA_HELPER'" "$JF" 2>/dev/null \
	&& grep -q "defaultValue: '/usr/local/libexec/wtfbsd-media'" "$JF" 2>/dev/null; then
	ok 'the Jenkinsfile names the installed helper of the media node'
else
	no 'the Jenkinsfile names the installed helper of the media node'
fi

# the stage is stopped by a trap on the signals: a trap on EXIT alone is
# not run when the stage is killed, and a trap on a signal alone does not
# exit, so the stage would run on after the signal.
if printf '%s\n' "$_jfstage" | grep -q "trap 'cleanup' EXIT"; then
	ok 'the media stage cleans up when it ends'
else
	no 'the media stage cleans up when it ends'
fi
if printf '%s\n' "$_jfstage" | grep -q "trap 'exit 129' HUP" \
	&& printf '%s\n' "$_jfstage" | grep -q "trap 'exit 130' INT" \
	&& printf '%s\n' "$_jfstage" | grep -q "trap 'exit 143' TERM"; then
	ok 'the media stage exits with the code of the signal'
else
	no 'the media stage exits with the code of the signal'
fi

# the stage builds the inputs.tar and feeds it to the helper on stdin,
# and the result comes out of the helper on stdout: no path argument at
# all, so the job never names a path that root would follow.
if printf '%s\n' "$_jfstage" | grep -q 'tar -c -F ustar -f inputs\.tar -C "\$inputs" site\.tgz install\.conf'; then
	ok 'the media stage builds the inputs.tar'
else
	no 'the media stage builds the inputs.tar'
fi
if printf '%s\n' "$_jfstage" | grep -q '< inputs\.tar'; then
	ok 'the media stage feeds the inputs.tar to the helper on stdin'
else
	no 'the media stage feeds the inputs.tar to the helper on stdin'
fi
if printf '%s\n' "$_jfstage" | grep -q 'prepare .*"\$RELEASE".*"\$ARCH"'; then
	ok 'the media stage passes the release and the architecture only'
else
	no 'the media stage passes the release and the architecture only'
fi
if printf '%s\n' "$_jfstage" | grep -q '> media\.iso\.tmp' \
	&& printf '%s\n' "$_jfstage" | grep -q 'mv media\.iso\.tmp media\.iso'; then
	ok 'the media stage writes the image to stdout only after the run succeeded'
else
	no 'the media stage writes the image to stdout only after the run succeeded'
fi

# the release and the architecture are given to the helper
if printf '%s\n' "$_jfstage" | grep -q '"\$RELEASE"'; then
	ok 'the media stage gives the release to the helper'
else
	no 'the media stage gives the release to the helper'
fi
if printf '%s\n' "$_jfstage" | grep -q '"\$ARCH"'; then
	ok 'the media stage gives the architecture to the helper'
else
	no 'the media stage gives the architecture to the helper'
fi

# the site set is named by its path, not a glob, so a file of another
# build is never taken
if printf '%s\n' "$_jfstage" | grep -q 'outdir=\./out'; then
	ok 'the media stage knows the directory of the profile'
else
	no 'the media stage knows the directory of the profile'
fi

# the workspace of the node holds the files of the last build that ran
# there: they go before the stash of this build
_med_rm=$(grep -n 'rm -rf -- \./out media\.iso' "$JF" 2>/dev/null | head -1 | cut -d: -f1)
_med_un=$(grep -n "unstash 'SITE_SET'" "$JF" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$_med_rm" ] && [ -n "$_med_un" ] && [ "$_med_rm" -lt "$_med_un" ]; then
	ok 'the media stage removes the files of another build before the stash of this build'
else
	no 'the media stage removes the files of another build before the stash of this build'
fi

# the media stage runs on the node of the media label
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

# --- the media stage and the helper, end to end ----------------------------

printf '== the media stage feeds the helper a tar it accepts ==\n'

# The tar(1) of OpenBSD writes pax by default ("the default format being
# pax", tar(1)): a pax archive carries an extended header (type flag x)
# that the helper refuses. The stage names the format.
if printf '%s\n' "$_jfstage" | grep -q 'tar -c -F ustar -f inputs\.tar -C "\$inputs" site\.tgz install\.conf'; then
	ok 'the media stage builds inputs.tar with -F ustar'
else
	no 'the media stage builds inputs.tar with -F ustar'
fi
if grep -q 'tar -c -F ustar -f inputs\.tar -C "\$inputs" site\.tgz install\.conf' "$repo/README.md" 2> /dev/null \
	&& ! grep -q 'tar -cf inputs\.tar' "$repo/README.md" "$JF" 2> /dev/null; then
	ok 'the README builds inputs.tar with -F ustar, and nothing builds it with the default format'
else
	no 'the README builds inputs.tar with -F ustar, and nothing builds it with the default format'
fi

# The stage shell runs against the helper copy of the suite: doas(1) runs
# its command, and tar(1) behaves as the tar of OpenBSD, which writes pax
# (with an extended header) unless -F ustar is given.
_jstub=$work/jfstub
mkdir -p "$_jstub"
cat > "$_jstub/doas" <<'STUB'
#!/bin/sh
printf 'doas %s\n' "$*" >> "$WTFBSD_TEST_DOAS_LOG"
exec "$@"
STUB
cat > "$_jstub/tar" <<'STUB'
#!/bin/sh
_real=$(command -p getconf PATH 2> /dev/null || printf /usr/bin:/bin)
case ${1:-} in
-c | -cf) ;;
*) exec env PATH="$_real" tar "$@" ;;
esac
_fmt=pax
_file=''
[ "$1" = -cf ] && { _file=$2; shift; }
shift
while [ "$#" -gt 0 ]; do
	case $1 in
	-F) _fmt=$2; shift 2 ;;
	-f) _file=$2; shift 2 ;;
	*) break ;;
	esac
done
if env PATH="$_real" tar --version 2> /dev/null | grep -q GNU; then
	case $_fmt in
	ustar) set -- --format=ustar "$@" ;;
	*) set -- --format=posix --pax-option=comment:=pax "$@" ;;
	esac
else
	set -- --format "$_fmt" "$@"
fi
exec env PATH="$_real" tar -c -f "$_file" "$@"
STUB
chmod +x "$_jstub"/*

cp "$MEDIA_RUN" "$work/media-stage-helper"
chmod +x "$work/media-stage-helper"
# media_stage <name> <stage shell> — run the stage in a directory of its
# own, with out/site80.tgz and out/install.conf as the build writes them
media_stage() {
	_msd=$work/mstage-$1
	mkdir -p "$_msd/out"
	cp "$_staging/site.tgz" "$_msd/out/site80.tgz"
	cp "$_staging/install.conf" "$_msd/out/install.conf"
	: > "$_msd/doas.log"
	: > "$_msd/argv.log"
	( cd "$_msd" && env -i PATH="$_jstub:$_mstub:$PATH" HOME="$_msd" \
		RELEASE=8.0 ARCH=amd64 PROFILE=appliance ALLOW_NO_BOOT_TEST= \
		MEDIA_HELPER="$work/media-stage-helper" \
		WTFBSD_TEST_DOAS_LOG="$_msd/doas.log" \
		WTFBSD_TEST_UID="$_uid" \
		WTFBSD_TEST_ARGV="$_msd/argv.log" \
		WTFBSD_TEST_ISO_TREE="$_isotree" \
		WTFBSD_TEST_MKDLOG="$_msd/mkd.log" \
		WTFBSD_TEST_VND_COUNT="$_msd/vc" \
		WTFBSD_TEST_MOUNT_COUNT="$_msd/mc" \
		WTFBSD_TEST_VND_STATE="$_msd/vs" \
		WTFBSD_TEST_MKHYBRID_TREE="$_msd/htree" \
		sh -c "$2" > "$_msd/log" 2>&1 )
}
# the stock image check of the stage names the directory of the media
# node; the suite points it at its own stock directory
_jfstage_t=$(printf '%s\n' "$_jfstage" | sed "s|/usr/local/share/wtfbsd-media/|$STOCK/|")
if printf '%s\n' "$_jfstage_t" | grep -q "$STOCK/install"; then
	media_stage ok "$_jfstage_t"
	_rc=$?
	if [ "$_rc" -eq 0 ] && [ "$(cat "$_msd/media.iso" 2> /dev/null)" = 'the image of mkhybrid' ]; then
		ok 'the media stage and the helper prepare media.iso end to end'
	else
		no "the media stage and the helper prepare media.iso end to end (status $_rc, see $_msd/log)"
	fi
	if cmp -s "$_msd/htree/8.0/amd64/site80.tgz" "$_staging/site.tgz"; then
		ok 'the media stage stages the site set the build wrote (site80.tgz)'
	else
		no 'the media stage stages the site set the build wrote (site80.tgz)'
	fi
	if grep -q '^doas .*/media-stage-helper prepare 8\.0 amd64$' "$_msd/doas.log"; then
		ok 'the media stage runs the helper through doas with the release and the architecture'
	else
		no 'the media stage runs the helper through doas with the release and the architecture'
	fi
	# those checks can fail: the stage with the default format of the
	# tar of OpenBSD is refused by the helper, and the stage that copies
	# out/site.tgz finds no site set
	media_stage pax "$(printf '%s\n' "$_jfstage_t" | sed 's|tar -c -F ustar -f inputs\.tar|tar -cf inputs.tar|')"
	if [ "$?" -ne 0 ] && grep -q 'type flag 0x78' "$_msd/log"; then
		ok 'a stage that writes the default pax format is refused by the helper (type flag x)'
	else
		no 'a stage that writes the default pax format is refused by the helper (type flag x)'
	fi
	media_stage sitename "$(printf '%s\n' "$_jfstage_t" | sed 's|"\$outdir/site\$nn\.tgz"|"$outdir/site.tgz"|')"
	if [ "$?" -ne 0 ] && grep -q 'cannot stage the site set' "$_msd/log"; then
		ok 'a stage that copies out/site.tgz finds no site set'
	else
		no 'a stage that copies out/site.tgz finds no site set'
	fi
else
	no 'the stage shell names the stock directory of the media node'
fi

# --- the build stage needs no root -----------------------------------------

printf '== the Jenkinsfile runs doas for the media helper only ==\n'

# Every doas(1) of the Jenkinsfile that is code (not a comment, not the
# description of a parameter) is the one that runs the installed helper:
# build.sh, a file of the workspace, never runs as root.
_jfdoas=$(grep -n 'doas' "$JF" 2> /dev/null | grep -v "description:" \
	| grep -v '^[0-9]*:[[:space:]]*#' | grep -v '^[0-9]*:[[:space:]]*//')
if [ "$(printf '%s\n' "$_jfdoas" | grep -c .)" -eq 1 ] \
	&& printf '%s\n' "$_jfdoas" | grep -q 'doas "\$MEDIA_HELPER" prepare'; then
	ok 'the Jenkinsfile runs doas only for the installed media helper'
else
	no "the Jenkinsfile runs doas only for the installed media helper (got: $_jfdoas)"
fi
if grep -q 'doas.*build\.sh' "$JF" "$repo/README.md" 2> /dev/null; then
	no 'neither the Jenkinsfile nor the README runs build.sh through doas'
else
	ok 'neither the Jenkinsfile nor the README runs build.sh through doas'
fi
_bstage=$(jenkins_sh_with 'build.sh "')
if printf '%s\n' "$_bstage" | grep -q '^[[:space:]]*\./build\.sh "\$@"$'; then
	ok 'the build stage runs build.sh as the account of the job'
else
	no 'the build stage runs build.sh as the account of the job'
fi


# --- the validate stage: the architecture is the one of the product ---

printf '== the validate stage: the architecture of the product ==\n'

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
if grep -q 'DISTRO_ARCH' "$work/valstage2.log" 2>/dev/null; then
	ok 'the refusal of an architecture names DISTRO_ARCH'
else
	no 'the refusal of an architecture names DISTRO_ARCH'
fi
# the boot test stage fails when the media stage prepared no image,
# unless the build says that it accepts a build without a boot test
_bootstage=$(jenkins_sh_with 'boot-test.sh')
if [ -n "$_bootstage" ]; then
	ok 'the boot test stage of the Jenkinsfile was found'
else
	no 'the boot test stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" ALLOW_NO_BOOT_TEST= \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=8.0 VM_PROVIDER=fake \
	sh -c "$_bootstage" > "$work/bootstage.log" 2>&1; then
	no 'the boot test stage fails when no image was prepared'
else
	ok 'the boot test stage fails when no image was prepared'
fi
grep -q 'media.iso' "$work/bootstage.log" 2> /dev/null \
	&& ok 'the failure of the boot test stage names the image' \
	|| no 'the failure of the boot test stage names the image'
if env -i PATH="$PATH" VM_LIST="$work/vmlist" ALLOW_NO_BOOT_TEST=yes \
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
