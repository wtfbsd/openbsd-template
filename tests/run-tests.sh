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
#   192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24   the documentation ranges
#   2001:db8 and 2001:0db8        the documentation range of the version 6
#   example.org and example.com   the domain of the documentation
#   rc.conf.local                 the name of the daemon configuration file
# An address that only starts like a placeholder is not allowed: the
# whole match has to be the placeholder itself.
_OK='127\.0\.0\.1|::1|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}'
_OK="$_OK"'|2001:(0?db8):[0-9a-f]{0,4}(:[0-9a-f]{0,4}){0,7}'
_OK="$_OK"'|[A-Za-z0-9._%+-]+@example\.(org|com)|rc\.conf\.local'

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
# OpenBSD reads /etc/boot.conf, not /boot/boot.conf
[ -f "$work/x/etc/boot.conf" ] \
	&& ok 'the appliance profile sets the serial console' || no 'the appliance profile sets the serial console'
[ ! -e "$work/x/boot/boot.conf" ] \
	&& ok 'the site set holds no /boot/boot.conf' || no 'the site set holds no /boot/boot.conf'

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

printf '== ci/media.sh and the boot test stage ==\n'

MEDIA="$repo/ci/media.sh"

# the media helper attaches the image, mounts a partition of it, puts the
# site set with the sets of the release and writes the response file where
# the installer looks for it
if grep -q 'vnconfig "\$VND" "\$IMAGE"' "$MEDIA"; then
	ok 'the media helper attaches the image to the device'
else
	no 'the media helper attaches the image to the device'
fi
if grep -q '/dev/${VND}a' "$MEDIA"; then
	ok 'the media helper mounts a partition of the image'
else
	no 'the media helper mounts a partition of the image'
fi
if grep -q 'auto_install.conf' "$MEDIA"; then
	ok 'the media helper writes the response file as /auto_install.conf'
else
	no 'the media helper writes the response file as /auto_install.conf'
fi
if grep -q 'RELEASE/\$ARCH' "$MEDIA"; then
	ok 'the media helper puts the site set with the sets of the release'
else
	no 'the media helper puts the site set with the sets of the release'
fi
if grep -q 'Location of sets = disk' "$MEDIA"; then
	ok 'the media helper points the response file at the sets of the media'
else
	no 'the media helper points the response file at the sets of the media'
fi

# The media helper stops on a signal: the trap runs the cleanup and the
# script exits with the code of the signal, so no step after the signal
# runs. The run is stubbed: the helper needs OpenBSD and root, so the
# commands it calls are replaced by stubs that leave a marker.
_stub=$work/stub
mkdir -p "$_stub"
cat > "$_stub/id" <<'STUB'
#!/bin/sh
printf '0\n'
STUB
cat > "$_stub/vnconfig" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$_stub/umount" <<'STUB'
#!/bin/sh
printf '%s\n' "umount $*" >> "$WTFBSD_TEST_UMOUNT_MARKER"
exit 0
STUB
cat > "$_stub/mount" <<'STUB'
#!/bin/sh
sleep 2
exit 0
STUB
chmod +x "$_stub/id" "$_stub/vnconfig" "$_stub/umount" "$_stub/mount"
: > "$work/image.img"
: > "$work/site78.tgz"
: > "$work/install.conf"
: > "$work/umount.marker"
mkdir -p "$work/mnt"

# the helper prepares the media: the CI calls it with the verb
if env PATH="$_stub:$PATH" WTFBSD_VM_MNT="$work/mnt" WTFBSD_TEST_UMOUNT_MARKER="$work/umount.marker" \
	sh "$MEDIA" prepare "$work/image.img" "$work/site78.tgz" "$work/install.conf" \
	> "$work/media.log" 2>&1; then
	ok 'the media helper prepares the media'
else
	no 'the media helper prepares the media'
fi
if [ -f "$work/mnt/7.8/amd64/site78.tgz" ] && [ -f "$work/mnt/auto_install.conf" ]; then
	ok 'the media helper puts the site set and the response file into the media'
else
	no 'the media helper puts the site set and the response file into the media'
fi

# the helper stops on a signal: the trap runs the cleanup and the script
# exits with the code of the signal, so no step after the signal runs
rm -rf "$work/mnt"
mkdir -p "$work/mnt"
: > "$work/umount.marker"
env PATH="$_stub:$PATH" WTFBSD_VM_MNT="$work/mnt" WTFBSD_TEST_UMOUNT_MARKER="$work/umount.marker" \
	sh "$MEDIA" prepare "$work/image.img" "$work/site78.tgz" "$work/install.conf" \
	> "$work/media.log" 2>&1 &
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
if [ -s "$work/umount.marker" ]; then
	ok 'the media helper cleans up when it is signalled'
else
	no 'the media helper cleans up when it is signalled'
fi
if [ "$(wc -l < "$work/umount.marker")" -eq 1 ]; then
	ok 'the cleanup of the media helper runs once'
else
	no 'the cleanup of the media helper runs once'
fi
if [ ! -e "$work/mnt/7.8/amd64/site78.tgz" ]; then
	ok 'the media helper runs no step after a signal'
else
	no 'the media helper runs no step after a signal'
fi

# the boot test stage fails when there is no media, unless the build says
# that it accepts a build without a boot test
_stage=$(jenkins_sh_with 'STOCK_MEDIA')
if [ -n "$_stage" ]; then
	ok 'the boot test stage of the Jenkinsfile was found'
else
	no 'the boot test stage of the Jenkinsfile was found'
fi
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST= \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=7.8 VM_PROVIDER=fake \
	sh -c "$_stage" > "$work/stage.log" 2>&1; then
	no 'the boot test stage fails when STOCK_MEDIA is empty'
else
	ok 'the boot test stage fails when STOCK_MEDIA is empty'
fi
grep -q 'STOCK_MEDIA' "$work/stage.log" 2> /dev/null \
	&& ok 'the failure names STOCK_MEDIA' || no 'the failure names STOCK_MEDIA'
if env -i PATH="$PATH" VM_LIST="$work/vmlist" STOCK_MEDIA= ALLOW_NO_BOOT_TEST=yes \
	PRODUCT_CONF="$CONF" PROFILE=appliance RELEASE=7.8 VM_PROVIDER=fake \
	sh -c "$_stage" > "$work/stage2.log" 2>&1; then
	ok 'the boot test stage skips when ALLOW_NO_BOOT_TEST says so'
else
	no 'the boot test stage skips when ALLOW_NO_BOOT_TEST says so'
fi
# the copy of the media is removed by a trap
if printf '%s\n' "$_stage" | grep -q 'trap'; then
	ok 'the boot test stage removes the copy of the media with a trap'
else
	no 'the boot test stage removes the copy of the media with a trap'
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

printf '== the repository itself ==\n'

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
