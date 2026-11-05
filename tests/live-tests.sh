# tests/live-tests.sh — the tests of the live image: the live set of the
# build, the live verb of the media helper and the install command of the
# live image.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Sourced by tests/run-tests.sh after the tests of the media helper: it uses
# ok/no, $work, $repo, build, mkconf, $KEYFILE, $PWFILE, $HASH, the stubs
# of the media helper ($_mstub), the tar helpers (tar_file, tar_end),
# stock_dir and sha_of. No root, no network, no VM.
# shellcheck disable=SC2154 # those variables are set by tests/run-tests.sh

printf '== the live set of the desktop (build.sh) ==\n'

SLUG=examplebsd

# member_line <tgz> <name> — the verbose listing line of a member
member_line() {
	tar -tvzf "$1" 2> /dev/null | n="$2" awk 'BEGIN { n = ENVIRON["n"] } $NF == n { print; exit }'
}
# set_file <tgz> <name> — the contents of a member
set_file() {
	tar -xOzf "$1" "$2" 2> /dev/null
}
has_member() {
	tar -tzf "$1" 2> /dev/null | grep -qx -- "$2"
}

mkconf live-desktop -e "s/^PROFILE=.*/PROFILE='desktop'/"
LCONF=$work/live-desktop.conf
LOUT=$work/out-live
sh "$BUILD" -c "$LCONF" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$LOUT" > "$work/live-build.log" 2>&1
_rc=$?
LIVE=$LOUT/live80.tgz
SITE=$LOUT/site80.tgz
if [ "$_rc" -eq 0 ] && [ -f "$LIVE" ]; then
	ok 'a desktop build writes the live set live80.tgz next to the site set'
else
	no "a desktop build writes the live set live80.tgz next to the site set (status $_rc, see $work/live-build.log)"
fi
if grep -q ' live80.tgz$' "$LOUT/SHA256" 2> /dev/null; then
	ok 'the SHA256 file of a desktop build lists the live set'
else
	no 'the SHA256 file of a desktop build lists the live set'
fi

# the media helper reads every header itself and accepts plain ustar only
_magic=$(gzip -dc "$LIVE" 2> /dev/null | dd bs=1 skip=257 count=8 2> /dev/null | od -An -tx1 | tr -d ' \n')
if [ "$_magic" = 7573746172003030 ]; then
	ok 'the live set is a POSIX ustar archive (the format is named, not the default of the host)'
else
	no "the live set is a POSIX ustar archive (magic $_magic)"
fi
_bad=$(tar -tvzf "$LIVE" 2> /dev/null | awk '$2 != "0/0" && $2 != "root/root"' | head -n 1)
_types=$(tar -tvzf "$LIVE" 2> /dev/null | cut -c1 | sort -u | tr -d '\n')
if [ -s "$LIVE" ] && [ -z "$_bad" ] && [ "$_types" = - ]; then
	ok 'the live set holds regular files only, owned by 0:0'
else
	no "the live set holds regular files only, owned by 0:0 ($_bad; types $_types)"
fi

for _m in "etc/rc.d/${SLUG}_live" "usr/local/libexec/$SLUG/live-x" "usr/local/libexec/$SLUG/live-session" \
	"usr/local/libexec/$SLUG/live-user-session" "usr/local/sbin/$SLUG-install" usr/local/bin/wtfbsd-installer \
	"usr/local/libexec/$SLUG/live-tui"; do
	case $(member_line "$LIVE" "$_m") in
		-rwxr-xr-x*) ok "the live set holds $_m, executable" ;;
		*) no "the live set holds $_m, executable ($(member_line "$LIVE" "$_m"))" ;;
	esac
done
case $(member_line "$LIVE" etc/doas.conf) in
	-rw-------*) ok 'the doas.conf of the live set has the mode 0600' ;;
	*) no "the doas.conf of the live set has the mode 0600 ($(member_line "$LIVE" etc/doas.conf))" ;;
esac
if has_member "$LIVE" "usr/local/share/$SLUG/live-packages.list" \
	&& set_file "$LIVE" "usr/local/share/$SLUG/live-packages.list" | grep -qw 'py3-gobject3' \
	&& set_file "$LIVE" "usr/local/share/$SLUG/live-packages.list" | grep -qw 'gtk+3'; then
	ok 'the live set lists the packages of the graphical installer (py3-gobject3, gtk+3)'
else
	no 'the live set lists the packages of the graphical installer (py3-gobject3, gtk+3)'
fi
if set_file "$LIVE" "usr/local/share/$SLUG/live-packages.list" | grep -qw xfce; then
	no 'the packages of the site set are not in the list of the live set'
else
	ok 'the packages of the site set are not in the list of the live set'
fi
if ! tar -tzf "$LIVE" 2> /dev/null | grep -q '@SLUG@' \
	&& ! tar -xOzf "$LIVE" 2> /dev/null | grep -q '@SLUG@\|@DISTRO_NAME@'; then
	ok 'the live set holds no placeholder: names and files carry the product'
else
	no 'the live set holds no placeholder: names and files carry the product'
fi

# the one root rule of the live user: the GTK-free helper of the installer,
# no environment of the user; the front ends run as live
_ld=$(set_file "$LIVE" etc/doas.conf | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
_lr=$(printf '%s\n' "$_ld" | grep -w live)
if [ "$_lr" = 'permit nopass live as root cmd /usr/local/libexec/wtfbsd-installer/installer-apply' ]; then
	ok 'the doas.conf of the live image has exactly one permit line for live: installer-apply, no environment'
else
	no "the doas.conf of the live image has exactly one permit line for live: installer-apply, no environment (rules: $_lr)"
fi
if printf '%s\n' "$_ld" | grep -q 'keepenv\|setenv'; then
	no 'no rule of the live image keeps or sets an environment'
else
	ok 'no rule of the live image keeps or sets an environment'
fi
if tar -xOzf "$LIVE" 2> /dev/null | grep -q 'doas[^#]*wtfbsd-installer\([^/]\|$\)\|si:localuser:root'; then
	no 'no front end of the installer is run as root on the display of the live user'
else
	ok 'no front end of the installer is run as root on the display of the live user'
fi
case $(member_line "$LIVE" usr/local/libexec/wtfbsd-installer/installer-apply) in
	-rwxr-xr-x*) ok 'without the installer-template the live set carries a stand-in installer-apply' ;;
	*) no 'without the installer-template the live set carries a stand-in installer-apply' ;;
esac

# the one rc.conf.local of the live image: base, desktop fragment, live
_lrc=$(set_file "$LIVE" etc/rc.conf.local)
_xen=$(printf '%s\n' "$_lrc" | grep -n '^xenodm_flags=' | tail -n 1)
_pks=$(printf '%s\n' "$_lrc" | grep -n "^pkg_scripts=.*${SLUG}_live")
if [ "${_xen#*:}" = 'xenodm_flags=NO' ] && [ -n "$_pks" ] \
	&& printf '%s\n' "$_lrc" | grep -q '^sshd_flags=NO$' \
	&& [ "${_xen%%:*}" -gt "$(printf '%s\n' "$_lrc" | grep -n '^xenodm_flags=$' | head -n 1 | cut -d: -f1)" ]; then
	ok 'the live rc.conf.local is the desktop one with the live fragment last: no greeter, the live session'
else
	no "the live rc.conf.local is the desktop one with the live fragment last ($_xen; $_pks)"
fi

# --- the installed system has none of the live image -------------------------

_sl=$(tar -tzf "$SITE" 2> /dev/null)
if [ -n "$_sl" ] && ! printf '%s\n' "$_sl" | grep -q '_live$\|wtfbsd-installer\|-install$\|autostart\|live-'; then
	ok 'the site set (the installed system) holds no live session, installer or autostart'
else
	no "the site set (the installed system) holds no live session, installer or autostart ($(printf '%s\n' "$_sl" | tr '\n' ' '))"
fi
_src=$(set_file "$SITE" etc/rc.conf.local)
if printf '%s\n' "$_src" | grep -q '^xenodm_flags=$' \
	&& ! printf '%s\n' "$_src" | grep -q 'xenodm_flags=NO\|_live'; then
	ok 'the installed system starts xenodm(1): the greeter, no automatic login'
else
	no 'the installed system starts xenodm(1): the greeter, no automatic login'
fi
if set_file "$SITE" etc/doas.conf | grep -v '^#' | grep -qw live; then
	no 'the doas.conf of the installed system has no rule for a live user'
else
	ok 'the doas.conf of the installed system has no rule for a live user'
fi
if tar -xOzf "$SITE" 2> /dev/null | grep -q 'useradd.*live' \
	|| set_file "$SITE" etc/rc.conf.local | grep -q '_autologin'; then
	no 'nothing of the site set creates a live user or turns an automatic login on'
else
	ok 'nothing of the site set creates a live user or turns an automatic login on'
fi
case $(member_line "$SITE" "etc/rc.d/${SLUG}_autologin") in
	-rwxr-xr-x*) ok 'the site set carries the automatic login service, off until the installer turns it on' ;;
	*) no 'the site set carries the automatic login service, off until the installer turns it on' ;;
esac
if set_file "$SITE" "usr/local/share/$SLUG/xenodm/Xresources" | grep -q '^xlogin\*greeting: ExampleBSD$'; then
	ok 'the site set carries the branding of the xenodm(1) greeter'
else
	no 'the site set carries the branding of the xenodm(1) greeter'
fi

# the appliance has no live image
mkconf live-appliance -e "s/^PROFILE=.*/PROFILE='appliance'/"
sh "$BUILD" -c "$work/live-appliance.conf" -u operator -k "$KEYFILE" -o "$work/out-live-app" > "$work/live-app.log" 2>&1
if [ -f "$work/out-live-app/site80.tgz" ] && [ ! -e "$work/out-live-app/live80.tgz" ]; then
	ok 'the appliance build writes no live set'
else
	no 'the appliance build writes no live set'
fi

# the dry run names the live set and where its installer comes from
sh "$BUILD" -n -c "$LCONF" -o "$work/out-live-dry" > "$work/live-dry.log" 2>&1
if grep -q 'live80.tgz (the live set: the stand-in text installer' "$work/live-dry.log" \
	&& [ ! -e "$work/out-live-dry" ]; then
	ok 'the dry run names the live set and its stand-in installer, and writes nothing'
else
	no 'the dry run names the live set and its stand-in installer, and writes nothing'
fi

# --- the installer-template ------------------------------------------------

# without INSTALLER_DIR or INSTALLER_REF: the stand-in launcher
if set_file "$LIVE" usr/local/bin/wtfbsd-installer | grep -q 'stand-in' \
	&& has_member "$LIVE" "usr/local/share/applications/$SLUG-install.desktop"; then
	ok 'without an installer-template the live set carries the stand-in launcher and its menu entry'
else
	no 'without an installer-template the live set carries the stand-in launcher and its menu entry'
fi

_itpl=$repo/tests/fixtures/installer-template
mkconf live-itpl -e "s/^PROFILE=.*/PROFILE='desktop'/"
printf "INSTALLER_DIR='%s'\n" "$_itpl" >> "$work/live-itpl.conf"
sh "$BUILD" -c "$work/live-itpl.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-live-itpl" > "$work/live-itpl.log" 2>&1
_it=$work/out-live-itpl/live80.tgz
if set_file "$_it" usr/local/bin/wtfbsd-installer | grep -q 'graphical installer (fixture)'; then
	ok 'INSTALLER_DIR: the launcher of the installer-template replaces the stand-in'
else
	no "INSTALLER_DIR: the launcher of the installer-template replaces the stand-in (see $work/live-itpl.log)"
fi
_ic=$(set_file "$_it" usr/local/libexec/wtfbsd-installer/installer.conf)
if printf '%s\n' "$_ic" | grep -qx 'OS=openbsd' \
	&& printf '%s\n' "$_ic" | grep -qx "PRODUCT_SLUG=$SLUG" \
	&& printf '%s\n' "$_ic" | grep -qx 'PRODUCT_NAME=ExampleBSD'; then
	ok 'INSTALLER_DIR: install-into-stage.sh is given the configuration of this product on OpenBSD'
else
	no "INSTALLER_DIR: install-into-stage.sh is given the configuration of this product on OpenBSD ($_ic)"
fi
case $(member_line "$_it" usr/local/libexec/wtfbsd-installer/bin/installer-gui) in
	-rwxr-xr-x*) ok 'INSTALLER_DIR: the executables of the installer-template stay executable' ;;
	*) no 'INSTALLER_DIR: the executables of the installer-template stay executable' ;;
esac
if ! has_member "$_it" "usr/local/share/applications/$SLUG-install.desktop" \
	&& has_member "$_it" usr/local/share/applications/wtfbsd-installer.desktop; then
	ok 'INSTALLER_DIR: the menu entry of the installer-template replaces the one of the stand-in'
else
	no 'INSTALLER_DIR: the menu entry of the installer-template replaces the one of the stand-in'
fi

mkconf live-both -e "s/^PROFILE=.*/PROFILE='desktop'/"
printf "INSTALLER_DIR='%s'\nINSTALLER_REF='main'\n" "$_itpl" >> "$work/live-both.conf"
if sh "$BUILD" -c "$work/live-both.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-live-both" > "$work/live-both.log" 2>&1; then
	no 'INSTALLER_REF and INSTALLER_DIR together are refused'
else
	grep -q 'do not go together' "$work/live-both.log" \
		&& ok 'INSTALLER_REF and INSTALLER_DIR together are refused' \
		|| no 'INSTALLER_REF and INSTALLER_DIR together are refused (message)'
fi
mkdir -p "$work/empty-itpl"
mkconf live-noitpl -e "s/^PROFILE=.*/PROFILE='desktop'/"
printf "INSTALLER_DIR='%s'\n" "$work/empty-itpl" >> "$work/live-noitpl.conf"
if sh "$BUILD" -c "$work/live-noitpl.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-live-noitpl" > "$work/live-noitpl.log" 2>&1; then
	no 'an installer-template without install-into-stage.sh is refused'
else
	grep -q 'has no install-into-stage.sh' "$work/live-noitpl.log" \
		&& ok 'an installer-template without install-into-stage.sh is refused' \
		|| no 'an installer-template without install-into-stage.sh is refused (message)'
fi

# --- the live session ------------------------------------------------------

_lx=$(set_file "$LIVE" "usr/local/libexec/$SLUG/live-session")
if printf '%s\n' "$_lx" | grep -q "exec su -l live -c" \
	&& printf '%s\n' "$_lx" | grep -q 'xhost +si:localuser:live'; then
	ok 'the live session runs as the live user on a display the live user may use'
else
	no 'the live session runs as the live user on a display the live user may use'
fi
_lu=$(set_file "$LIVE" "usr/local/libexec/$SLUG/live-user-session")
if printf '%s\n' "$_lu" | grep -q 'autostart/wtfbsd-installer.desktop' \
	&& printf '%s\n' "$_lu" | grep -q '\.config/autostart' \
	&& printf '%s\n' "$_lu" | grep -q 'exec /usr/local/bin/startxfce4'; then
	ok 'the live user session opens the installer first (autostart) in Xfce'
else
	no 'the live user session opens the installer first (autostart) in Xfce'
fi
# the session keeps the display console: a serial console (set tty com0)
# takes the keyboard away from the display under bhyve
if tar -xOzf "$LIVE" 2> /dev/null | grep -q 'set tty com0' || has_member "$LIVE" etc/boot.conf; then
	no 'the live image keeps the console on the display (no boot.conf, no set tty com0)'
else
	ok 'the live image keeps the console on the display (no boot.conf, no set tty com0)'
fi

# --- the install command: <slug>-install -------------------------------------

printf '== the install command of the live image ==\n'

INST_SRC=$work/live-stage-install
mkdir -p "$INST_SRC"
tar -xzf "$LIVE" -C "$INST_SRC" "usr/local/sbin/$SLUG-install" 2> /dev/null
_ishare=$work/ishare
# inst_copy — a copy of the install command whose share directory is the
# fixture of the suite (the real one is /usr/local/share/<slug>)
INST=$work/inst.sh
sed -e "s|^SHARE=/usr/local/share/\$SLUG\$|SHARE=$_ishare|" \
	-e "s|^MANIFEST=/usr/local/share/wtfbsd-installer/MANIFEST\$|MANIFEST=$work/inst-manifest|" \
	-e "s|^LOCALEDIR=/usr/share/locale\$|LOCALEDIR=$work/locale|" \
	-e "s|^DEVDIR=/dev\$|DEVDIR=$work/devd|" \
	"$INST_SRC/usr/local/sbin/$SLUG-install" > "$INST"
printf '/usr/local/bin/wtfbsd-installer\n/etc/motd\n../../etc/passwd\n' > "$work/inst-manifest"
mkdir -p "$work/locale/UTF-8" "$work/devd"
# the raw disk a secure wipe writes to: a device that is full at once
ln -s /dev/full "$work/devd/rsd1c"
if grep -q "^SHARE=$_ishare\$" "$INST"; then
	ok 'the copy of the install command the suite runs uses the fixture sets'
else
	no 'the copy of the install command the suite runs uses the fixture sets'
fi

# the sets of the fixture: base holds what the install edits
_isets=$_ishare/sets/8.0/amd64
mkdir -p "$_isets" "$_ishare/packages" "$_ishare/firmware"
# /etc is not in the base set itself: it is var/sysmerge/etc.tgz of the
# base set (and xetc.tgz of xbase), as in the sets of the release
_bt=$work/ibase
_be=$work/ibase-etc
mkdir -p "$_be/etc" "$_bt/dev" "$_bt/var/db" "$_bt/var/sysmerge" "$_bt/usr/share"
printf 'root:*:0:0:daemon:0:0:Charlie &:/root:/bin/ksh\n' > "$_be/etc/master.passwd"
printf 'root:*:0:0:Charlie &:/root:/bin/ksh\n' > "$_be/etc/passwd"
printf 'wheel:*:0:root\n' > "$_be/etc/group"
tar -czf "$_bt/var/sysmerge/etc.tgz" -C "$_be" etc
printf '#!/bin/sh\nexit 0\n' > "$_bt/dev/MAKEDEV"
printf 'base\n' > "$_bt/usr/share/base.marker"
tar -czf "$_isets/base80.tgz" -C "$_bt" dev var usr
for _s in comp man game xbase xshare xfont xserv; do
	mkdir -p "$work/iset-$_s/usr/share"
	printf '%s\n' "$_s" > "$work/iset-$_s/usr/share/$_s.marker"
	if [ "$_s" = xbase ]; then
		mkdir -p "$work/ixetc/etc/X11/xenodm" "$work/iset-$_s/var/sysmerge"
		printf 'xetc\n' > "$work/ixetc/etc/X11/xetc.marker"
		# the defaults of xenodm(1) as OpenBSD ships them: the Puffy logo for
		# every depth, the host name greeting, the weave background
		cat > "$work/ixetc/etc/X11/xenodm/Xresources" <<'XRES'
xlogin*greeting: CLIENTHOST
xlogin*namePrompt: \040\040\040\040\040\040\040Login:
#ifdef COLOR
xlogin*background: #596a79
xlogin*greetColor: #3b6ea5
#endif
#if PLANES >= 8
xlogin*logoFileName: /usr/X11R6/include/X11/bitmaps/OpenBSD_8bpp.xpm
#elif PLANES >= 4
xlogin*logoFileName: /usr/X11R6/include/X11/bitmaps/OpenBSD_4bpp.xpm
#else
xlogin*logoFileName: /usr/X11R6/include/X11/bitmaps/OpenBSD_1bpp.xpm
#endif
xlogin*useShape: true
XRES
		cat > "$work/ixetc/etc/X11/xenodm/Xsetup_0" <<'XSET'
#!/bin/sh
prefix="/usr/X11R6"
${prefix}/bin/xsetroot -fg \#6f6f6f -bg \#bfbfbf -bitmap ${prefix}/include/X11/bitmaps/root_weave
${prefix}/bin/xconsole -geometry 480x130-0-0 -daemon -notify -verbose -fn fixed -exitOnFail
XSET
		# display :0 starts the session with GiveConsole (xenodm-config)
		cat > "$work/ixetc/etc/X11/xenodm/GiveConsole" <<'XGIV'
#!/bin/sh
prefix="/usr/X11R6"
exec_prefix="${prefix}"
GROUP=`id -g $USER`
chown $USER:$GROUP /dev/console
${exec_prefix}/bin/sessreg -a -l $DISPLAY -u none $USER
XGIV
		cat > "$work/ixetc/etc/X11/xenodm/Xstartup" <<'XSTA'
#!/bin/sh
if [ -f /etc/nologin ]; then
	exit 1
fi
exec /usr/X11R6/bin/sessreg -a -l $DISPLAY -u /var/run/utmp $USER
XSTA
		tar -czf "$work/iset-$_s/var/sysmerge/xetc.tgz" -C "$work/ixetc" etc
		tar -czf "$_isets/${_s}80.tgz" -C "$work/iset-$_s" usr var
	else
		tar -czf "$_isets/${_s}80.tgz" -C "$work/iset-$_s" usr
	fi
done
for _k in bsd bsd.mp bsd.rd; do printf 'the kernel %s\n' "$_k" > "$_isets/$_k"; done
cp "$SITE" "$_isets/site80.tgz"
printf 'the package xfce\n' > "$_ishare/packages/xfce-4.20.tgz"

# the stubs of the install command: each logs its argv
_istub=$work/inststub
mkdir -p "$_istub"
cp "$_mstub/stat" "$_istub/stat"
for _t in fdisk newfs installboot pwd_mkdb; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$WTFBSD_TEST_ARGV"\nexit 0\n' "$_t" > "$_istub/$_t"
done
cat > "$_istub/sysctl" <<'STUB'
#!/bin/sh
printf 'sysctl %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
printf '%s\n' "${WTFBSD_TEST_DISKNAMES:-sd0:aaaaaaaaaaaaaaaa,sd1:,sd2:,sd3:,cd0:}"
STUB
cat > "$_istub/bioctl" <<'STUB'
#!/bin/sh
printf 'bioctl %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
printf 'softraid0: %s volume attached as sd5\n' "${WTFBSD_TEST_BIOLEVEL:-RAID 1}"
STUB
cat > "$_istub/fw_update" <<'STUB'
#!/bin/sh
printf 'fw_update DESTDIR=%s %s\n' "${DESTDIR:-}" "$*" >> "$WTFBSD_TEST_ARGV"
STUB
cat > "$_istub/disklabel" <<'STUB'
#!/bin/sh
printf 'disklabel %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
if [ "${1:-}" = -E ]; then
	printf 'disklabel-E-input %s\n' "$(tr '\n' '|')" >> "$WTFBSD_TEST_ARGV"
	exit 0
fi
_f=''
_prev=''
for _a in "$@"; do
	[ "$_prev" = -F ] && _f=$_a
	[ "$_prev" = -T ] && cp "$_a" "$WTFBSD_TEST_ARGV.template"
	_prev=$_a
done
if [ -n "$_f" ]; then
	_t=''
	_prev=''
	for _a in "$@"; do
		[ "$_prev" = -T ] && _t=$_a
		_prev=$_a
	done
	# a template whose first mount point is not / is a data disk: one
	# partition on that mount point
	_m=$( [ -n "$_t" ] && awk 'NR == 1 { print $1 }' "$_t")
	if [ -n "$_m" ] && [ "$_m" != / ]; then
		printf 'cccccccccccccccc.a %s ffs rw,nodev,nosuid 1 2\n' "$_m" > "$_f"
		exit 0
	fi
	printf 'bbbbbbbbbbbbbbbb.a / ffs rw 1 1\nbbbbbbbbbbbbbbbb.b none swap sw\nbbbbbbbbbbbbbbbb.d /usr ffs rw,nodev 1 2\n' > "$_f"
	exit 0
fi
printf '# /dev/rsd1c:\nduid: bbbbbbbbbbbbbbbb\n'
STUB
cat > "$_istub/mount" <<'STUB'
#!/bin/sh
if [ "$#" -eq 0 ]; then
	printf '%s on / type ffs (local)\n' "${WTFBSD_TEST_ROOTDEV:-/dev/sd0a}"
	[ -z "${WTFBSD_TEST_MOUNTED:-}" ] || printf '%s on /mnt type ffs (local)\n' "$WTFBSD_TEST_MOUNTED"
	exit 0
fi
printf 'mount %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_mnt=''
for _a in "$@"; do _mnt=$_a; done
mkdir -p "$_mnt"
exit 0
STUB
cat > "$_istub/umount" <<'STUB'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_m=''
for _a in "$@"; do _m=$_a; done
case $_m in
*/root)
	if [ -n "${WTFBSD_TEST_UMOUNT_TREE:-}" ] && [ -d "$_m" ]; then
		mkdir -p "$WTFBSD_TEST_UMOUNT_TREE"
		cp -RP "$_m/." "$WTFBSD_TEST_UMOUNT_TREE/" 2> /dev/null
	fi
	;;
esac
exit 0
STUB
cat > "$_istub/sha256" <<'STUB'
#!/bin/sh
printf 'SHA256 (%s) = 0000\n' "$1"
STUB
cat > "$_istub/ifconfig" <<'STUB'
#!/bin/sh
printf 'vio0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmedia: Ethernet autoselect\nlo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 32768\n'
STUB
# chroot(8): the root is the first argument; useradd writes the account
# into the files of the root, the others are logged only
cat > "$_istub/chroot" <<'STUB'
#!/bin/sh
printf 'chroot %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_r=$1
shift
case $1 in
useradd)
	_u=''
	for _a in "$@"; do _u=$_a; done
	printf '%s:*:1000:1000:default:0:0:%s:/home/%s:/bin/ksh\n' "$_u" "$_u" "$_u" >> "$_r/etc/master.passwd"
	printf '%s:*:1000:1000:%s:/home/%s:/bin/ksh\n' "$_u" "$_u" "$_u" >> "$_r/etc/passwd"
	mkdir -p "$_r/home/$_u"
	;;
esac
exit 0
STUB
chmod +x "$_istub"/*

# the hash file of the account: mode 0600, one bcrypt hash
IHASH=$work/inst.hash
( umask 077; printf '%s\n' "$HASH" > "$IHASH" )

# runinst [NAME=VALUE ...] -- <arguments> — the install command with the
# stubs; IRUN holds out (stdout), err, argv.log and tree (the new root)
_irun=0
runinst() {
	_irun=$((_irun + 1))
	IRUN=$work/irun-$_irun
	mkdir -p "$IRUN"
	: > "$IRUN/argv.log"
	_ienv=''
	while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
		_ienv="$_ienv $1"
		shift
	done
	[ "${1:-}" = -- ] && shift
	# shellcheck disable=SC2086
	env PATH="$_istub:$PATH" WTFBSD_TEST_UID="$_uid" WTFBSD_TEST_ARGV="$IRUN/argv.log" \
		WTFBSD_TEST_UMOUNT_TREE="$IRUN/tree" $_ienv \
		sh "$INST" "$@" > "$IRUN/out" 2> "$IRUN/err"
}
# progress_only — stdout holds PROGRESS and ERROR lines only
progress_only() {
	! grep -v '^PROGRESS [0-9][0-9]* .\|^ERROR .' "$IRUN/out" | grep -q .
}
# inst_refused <pattern> <what> — non-zero, an ERROR line, nothing written
inst_refused() {
	if [ "$1" -ne 0 ] && grep -q "^ERROR .*$2" "$IRUN/out" && progress_only \
		&& ! grep -q '^fdisk\|^disklabel\|^newfs' "$IRUN/argv.log"; then
		ok "$3"
	else
		no "$3 (status $1; out: $(tr '\n' ' ' < "$IRUN/out"))"
	fi
}

runinst -- -d sd1 -u wtfuser -k "$KEYFILE" -H "$IHASH" -n desk -z Europe/Berlin -K de -y --progress
_rc=$?
_t=$IRUN/tree
_ok=$IRUN
if [ "$_rc" -eq 0 ] && tail -n 1 "$IRUN/out" | grep -q '^PROGRESS 100 '; then
	ok 'the install command installs onto the disk and ends with PROGRESS 100'
else
	no "the install command installs onto the disk and ends with PROGRESS 100 (status $_rc, see $IRUN/err)"
fi
if progress_only && [ -s "$IRUN/out" ]; then
	ok 'with --progress, stdout holds PROGRESS lines and nothing else'
else
	no 'with --progress, stdout holds PROGRESS lines and nothing else'
fi
if awk '$1 == "PROGRESS" { if ($2 + 0 < last) bad = 1; last = $2 + 0 } END { exit bad }' "$IRUN/out"; then
	ok 'the percentages of the PROGRESS lines never go back'
else
	no 'the percentages of the PROGRESS lines never go back'
fi
if grep -qx 'fdisk -gy -b 532480 sd1' "$_ok/argv.log" \
	&& grep -q '^disklabel -w -A -F .* sd1$' "$_ok/argv.log" \
	&& grep -qx 'newfs -q /dev/rsd1a' "$_ok/argv.log" && grep -qx 'newfs -q /dev/rsd1d' "$_ok/argv.log" \
	&& grep -qx 'installboot -p sd1' "$_ok/argv.log"; then
	ok 'the disk gets the GPT and the automatic layout of the installer (fdisk -gy -b 532480, disklabel -A, newfs)'
else
	no "the disk gets the GPT and the automatic layout of the installer (see $_ok/argv.log)"
fi
if grep -q '^installboot -c -r .*/root sd1$' "$_ok/argv.log"; then
	ok 'the boot loader is installed on the disk and set as the boot entry (installboot -c)'
else
	no 'the boot loader is installed on the disk and set as the boot entry (installboot -c)'
fi
if grep -q '^mount /dev/sd1a .*/root$' "$_ok/argv.log" && grep -q '^mount /dev/sd1d .*/root/usr$' "$_ok/argv.log" \
	&& [ "$(grep -n '^mount /dev/sd1a' "$_ok/argv.log" | cut -d: -f1)" -lt "$(grep -n '^mount /dev/sd1d' "$_ok/argv.log" | cut -d: -f1)" ]; then
	ok 'the file systems are mounted / first, then the ones below it'
else
	no 'the file systems are mounted / first, then the ones below it'
fi
_ok_sets=1
for _s in base comp man game xbase xshare xfont xserv; do
	[ -f "$_t/usr/share/$_s.marker" ] || _ok_sets=0
done
if [ "$_ok_sets" -eq 1 ] && [ -f "$_t/bsd" ] && [ -f "$_t/bsd.sp" ] && [ -f "$_t/bsd.rd" ] \
	&& [ "$(cat "$_t/bsd")" = 'the kernel bsd.mp' ]; then
	ok 'the eight sets are unpacked and bsd.mp is the kernel (/bsd), bsd is /bsd.sp'
else
	no 'the eight sets are unpacked and bsd.mp is the kernel (/bsd), bsd is /bsd.sp'
fi
if grep -q '^bbbbbbbbbbbbbbbb.a / ffs' "$_t/etc/fstab" 2> /dev/null; then
	ok 'the fstab of the new system names its file systems by the DUID of the disk'
else
	no 'the fstab of the new system names its file systems by the DUID of the disk'
fi
# the site set, and nothing of the live set
if [ -f "$_t/usr/local/share/$SLUG/packages.list" ] && grep -q '^xenodm_flags=$' "$_t/etc/rc.conf.local" 2> /dev/null \
	&& [ ! -e "$_t/install.site" ]; then
	ok 'the site set is unpacked over the new root (and its install.site is not left behind)'
else
	no 'the site set is unpacked over the new root (and its install.site is not left behind)'
fi
if [ -d "$_t/etc" ] && ! grep -rqs "${SLUG}_live" "$_t/etc" && ! grep -q 'xenodm_flags=NO' "$_t/etc/rc.conf.local" \
	&& [ ! -e "$_t/usr/local/bin/wtfbsd-installer" ] && [ ! -e "$_t/home/live" ] \
	&& ! grep -q '^live:' "$_t/etc/master.passwd" 2> /dev/null; then
	ok 'the installed system has no live user, no live session and no installer'
else
	no 'the installed system has no live user, no live session and no installer'
fi
# the account
if grep -q "^wtfuser:$(printf '%s' "$HASH" | sed 's/[$.]/\\&/g'):" "$_t/etc/master.passwd" 2> /dev/null; then
	ok 'the account gets the bcrypt hash of the hash file in master.passwd'
else
	no 'the account gets the bcrypt hash of the hash file in master.passwd'
fi
if grep -qF "$HASH" "$_ok/argv.log" "$_ok/err" "$_ok/out" 2> /dev/null; then
	no 'the hash is never an argument of a command and never printed'
else
	ok 'the hash is never an argument of a command and never printed'
fi
if grep -q '^chroot .* useradd -m -G wheel .*wtfuser$' "$_ok/argv.log" && grep -q '^pwd_mkdb -p -d .*/etc ' "$_ok/argv.log"; then
	ok 'the account is a member of wheel and the password databases are rebuilt'
else
	no 'the account is a member of wheel and the password databases are rebuilt'
fi
if [ "$(cat "$_t/home/wtfuser/.ssh/authorized_keys" 2> /dev/null)" = "$(cat "$KEYFILE")" ]; then
	ok 'the public key goes into the authorized_keys of the account'
else
	no 'the public key goes into the authorized_keys of the account'
fi
if [ "$(cat "$_t/etc/myname" 2> /dev/null)" = desk ]; then
	ok 'the name of the host is the name given'
else
	no "the name of the host is the name given ($(cat "$_t/etc/myname" 2> /dev/null))"
fi
if [ "$(readlink "$_t/etc/localtime" 2> /dev/null)" = /usr/share/zoneinfo/Europe/Berlin ]; then
	ok 'the time zone is the one given'
else
	no 'the time zone is the one given'
fi
if grep -qx 'keyboard.encoding=de' "$_t/etc/wsconsctl.conf" 2> /dev/null \
	&& grep -q '"XkbLayout" "de"' "$_t/etc/X11/xorg.conf.d/00-$SLUG-keyboard.conf" 2> /dev/null; then
	ok 'the keyboard layout is set for wscons(4) and for the X server'
else
	no 'the keyboard layout is set for wscons(4) and for the X server'
fi
if grep -q '^chroot .* env PKG_PATH=/var/cache/[^ ]*/ pkg_add -I xfce' "$_ok/argv.log" \
	&& [ ! -e "$_t/var/cache/$SLUG-packages" ]; then
	ok 'the packages of the site set come from the package cache of the live image, which is not left behind'
else
	no 'the packages of the site set come from the package cache of the live image, which is not left behind'
fi
if [ "$(cat "$_t/etc/hostname.vio0" 2> /dev/null)" = "$(printf 'inet autoconf\ninet6 autoconf')" ]; then
	ok 'every Ethernet adapter of the machine asks for an address'
else
	no 'every Ethernet adapter of the machine asks for an address'
fi
if grep -qx '/usr/sbin/fw_update' "$_t/etc/rc.firsttime" 2> /dev/null; then
	ok 'the first boot fetches the firmware, as after the stock installer'
else
	no 'the first boot fetches the firmware, as after the stock installer'
fi
if [ "$(grep -c '^umount ' "$_ok/argv.log")" -ge 2 ] && grep -q '^umount .*/root$' "$_ok/argv.log" \
	&& [ "$(grep -n '^umount .*/root/usr$' "$_ok/argv.log" | cut -d: -f1)" -lt "$(grep -n '^umount .*/root$' "$_ok/argv.log" | cut -d: -f1)" ]; then
	ok 'the file systems are unmounted, the ones below / first'
else
	no 'the file systems are unmounted, the ones below / first'
fi

if [ -f "$_t/etc/X11/xetc.marker" ] && [ -f "$_t/etc/group" ]; then
	ok 'the /etc of the new system comes from etc.tgz and xetc.tgz of the base and xbase sets'
else
	no 'the /etc of the new system comes from etc.tgz and xetc.tgz of the base and xbase sets'
fi
if [ -f "$_t/etc/myname" ] && [ ! -e "$_t/etc/motd" ] && [ -f "$_t/etc/passwd" ]; then
	ok 'the paths of the MANIFEST of the installer are removed from the new root (and only those)'
else
	no 'the paths of the MANIFEST of the installer are removed from the new root (and only those)'
fi
if grep -q '^chroot .* useradd -m -G wheel -s /bin/ksh -c wtfuser wtfuser$' "$_ok/argv.log" \
	&& ! grep -q '^permit nopass wtfuser' "$_t/etc/doas.conf" 2> /dev/null; then
	ok 'without -c the full name is the user name, and without -P doas asks for the password'
else
	no 'without -c the full name is the user name, and without -P doas asks for the password'
fi

# -c, -P and -N
runinst -- -d sd1 -u wtfuser -H "$IHASH" -c 'Wtf User' -P -N vio0:192.0.2.10/24:192.0.2.1 -N em0:dhcp -y --progress
_rc=$?
_t2=$IRUN/tree
if [ "$_rc" -eq 0 ] && grep -q "^chroot .* useradd -m -G wheel -s /bin/ksh -c Wtf User wtfuser\$" "$IRUN/argv.log"; then
	ok '-c gives the account its full name'
else
	no "-c gives the account its full name (status $_rc)"
fi
if grep -qx 'permit nopass wtfuser as root' "$_t2/etc/doas.conf" 2> /dev/null; then
	ok '-P lets the account use doas(1) without its password'
else
	no '-P lets the account use doas(1) without its password'
fi
if [ "$(cat "$_t2/etc/hostname.vio0" 2> /dev/null)" = 'inet 192.0.2.10/24' ] \
	&& [ "$(cat "$_t2/etc/mygate" 2> /dev/null)" = 192.0.2.1 ] \
	&& [ "$(cat "$_t2/etc/hostname.em0" 2> /dev/null)" = "$(printf 'inet autoconf\ninet6 autoconf')" ]; then
	ok '-N writes the static address and the default route, or DHCP, per adapter'
else
	no '-N writes the static address and the default route, or DHCP, per adapter'
fi
runinst -- -d sd1 -u wtfuser -H "$IHASH" -N vio0:192.0.2/24:192.0.2.1 -y --progress
inst_refused $? 'not an IPv4 address' 'the install command refuses -N with an address that is not one'
runinst -- -d /dev/sd1 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not a disk name' 'the install command takes a bare disk name, never a path'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -c 'a:b' -y --progress
inst_refused $? 'colon' 'the install command refuses a full name with a colon'


# --- the parity of the installer: disks, encryption, users, network --------

printf '== the install command: softraid, swap, users, network, updates ==\n'

# secret <file> <content> — a 0600 file
secret() { ( umask 077; printf '%s\n' "$2" > "$1" ); }
_pass=$work/plan.pass
secret "$_pass" 'a passphrase of the suite'
plan() { # plan <name> <json> — a 0600 plan file
	secret "$work/plan-$1.json" "$2"
	printf '%s' "$work/plan-$1.json"
}

runinst -- -p "$(plan raid1 '{"version": 1, "mode": "erase", "disks": ["sd1", "sd2"], "layout": "raid1", "encryption": {"enabled": false, "swap": false}}')" \
	-u wtfuser -H "$IHASH" -y --progress
_rc=$?
_a=$IRUN/argv.log
if [ "$_rc" -eq 0 ] && grep -qx 'fdisk -gy -b 532480 sd1' "$_a" && grep -qx 'fdisk -gy -b 532480 sd2' "$_a" \
	&& grep -qx 'disklabel -E sd1' "$_a" && grep -qx 'disklabel -E sd2' "$_a" \
	&& grep -q 'disklabel-E-input a a|||RAID|w|q|' "$_a"; then
	ok 'raid1: every disk gets the GPT of the installer and one RAID partition'
else
	no "raid1: every disk gets the GPT of the installer and one RAID partition (status $_rc, see $_a)"
fi
if grep -qx 'bioctl -C force -c 1 -l sd1a,sd2a softraid0' "$_a" && grep -qx 'fdisk -iy sd5' "$_a" \
	&& grep -q '^disklabel -w -A -F .* sd5$' "$_a" && grep -q '^mount /dev/sd5a .*/root$' "$_a"; then
	ok 'raid1: bioctl(8) makes the RAID 1 volume and the system goes onto it'
else
	no 'raid1: bioctl(8) makes the RAID 1 volume and the system goes onto it'
fi
if grep -qx 'installboot -p sd1' "$_a" && grep -qx 'installboot -p sd2' "$_a" \
	&& grep -q '^installboot -c -r .*/root sd5$' "$_a"; then
	ok 'raid1: the EFI partition of every disk is prepared and the boot loader goes onto the volume'
else
	no 'raid1: the EFI partition of every disk is prepared and the boot loader goes onto the volume'
fi

runinst WTFBSD_TEST_BIOLEVEL=CRYPTO -- -p "$(plan crypt '{"version": 1, "mode": "erase", "disks": ["sd1"], "layout": "single", "encryption": {"enabled": true, "swap": false}}')" \
	-E "$_pass" -u wtfuser -H "$IHASH" -y --progress
_rc=$?
if [ "$_rc" -eq 0 ] && grep -qx "bioctl -C force -c C -l sd1a -p $_pass softraid0" "$IRUN/argv.log" \
	&& ! grep -q 'a passphrase of the suite' "$IRUN/argv.log" "$IRUN/out" "$IRUN/err"; then
	ok 'encryption: softraid CRYPTO with the passphrase from its file, never an argument'
else
	no "encryption: softraid CRYPTO with the passphrase from its file, never an argument (status $_rc)"
fi
runinst -- -p "$(plan crypt1 '{"version": 1, "mode": "erase", "disks": ["sd1", "sd2"], "layout": "raid1", "encryption": {"enabled": true}}')" \
	-E "$_pass" -u wtfuser -H "$IHASH" -y --progress
if [ $? -eq 0 ] && grep -qx "bioctl -C force -c 1C -l sd1a,sd2a -p $_pass softraid0" "$IRUN/argv.log"; then
	ok 'encryption with raid1: one RAID 1C volume (mirrored and encrypted)'
else
	no 'encryption with raid1: one RAID 1C volume (mirrored and encrypted)'
fi
chmod 0644 "$_pass"
runinst -- -p "$(plan crypt2 '{"version": 1, "mode": "erase", "disks": ["sd1"], "encryption": {"enabled": true}}')" \
	-E "$_pass" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'mode 0600' 'the install command refuses a passphrase file others may read'
chmod 0600 "$_pass"
runinst -- -p "$(plan r5 '{"version": 1, "mode": "erase", "disks": ["sd1", "sd2", "sd3"], "layout": "raid5"}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not one OpenBSD can boot from' 'the install command refuses a layout OpenBSD cannot boot from (RAID 5)'
runinst -- -p "$(plan r1one '{"version": 1, "mode": "erase", "disks": ["sd1"], "layout": "raid1"}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'needs two disks' 'the install command refuses raid1 on one disk'
runinst -- -p "$(plan live '{"version": 1, "mode": "erase", "disks": ["sd1", "sd0"], "layout": "raid1"}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'running live system' 'the install command refuses a plan that names the live disk'
runinst -- -p "$(plan twice '{"version": 1, "mode": "erase", "disks": ["sd1", "sd1"], "layout": "raid1"}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'names a disk twice' 'the install command refuses a plan that names a disk twice'
runinst -- -p "$(plan notjson 'disks = sd1')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not JSON' 'the install command refuses a plan that is not JSON'
runinst -- -p "$(plan noenc '{"version": 1, "mode": "erase", "disks": ["sd1"], "encryption": {"enabled": true}}')" \
	-u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'passphrase is required' 'the install command refuses an encrypted plan without a passphrase file'
runinst -- -p "$(plan manual '{"version": 1, "mode": "manual", "disks": [], "partitions": [{"type": "root"}]}')" \
	-u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not offered on OpenBSD yet' 'the install command says that manual partitioning is not offered on OpenBSD yet'
runinst -- -p "$(plan v2 '{"version": 2, "mode": "erase", "disks": ["sd1"]}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not version 1' 'the install command refuses a plan of another version'
runinst -- -p "$(plan wipe '{"version": 1, "mode": "erase", "disks": ["sd1"], "wipe": {"sd1": "secure"}}')" \
	-u wtfuser -H "$IHASH" -y --progress
if [ $? -eq 0 ] && grep -q '^PROGRESS 1 Erasing sd1' "$IRUN/out" && grep -q "^DEVDIR=$work/devd\$" "$INST"; then
	ok 'a secure wipe of the plan erases every block of the disk first'
else
	no 'a secure wipe of the plan erases every block of the disk first'
fi
_wp=$(plan wide '{"version": 1, "mode": "erase", "disks": ["sd1"]}')
chmod 0644 "$_wp"
runinst -- -p "$_wp" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'mode 0600' 'the install command refuses a plan file others may read'
runinst -- -p "$(plan both '{"version": 1, "mode": "erase", "disks": ["sd1"]}')" -d sd1 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'do not go together' 'the install command refuses -d with -p'

# swap
runinst -- -p "$(plan swap '{"version": 1, "mode": "erase", "disks": ["sd1"], "swap_mb": 2048}')" -u wtfuser -H "$IHASH" -y --progress
if [ $? -eq 0 ] && grep -qx 'swap 2048M' "$IRUN/argv.log.template" 2> /dev/null \
	&& grep -q '^disklabel -w -A -T .* -F .* sd1$' "$IRUN/argv.log"; then
	ok 'the swap size of the plan goes into the layout of disklabel(8)'
else
	no 'the swap size of the plan goes into the layout of disklabel(8)'
fi
runinst -- -p "$(plan noswap '{"version": 1, "mode": "erase", "disks": ["sd1"], "swap_mb": 0}')" -u wtfuser -H "$IHASH" -y --progress
if [ $? -eq 0 ] && [ -f "$IRUN/argv.log.template" ] && ! grep -q '^swap' "$IRUN/argv.log.template" \
	&& grep -q '^/ ' "$IRUN/argv.log.template"; then
	ok 'swap_mb 0 in the plan gives a layout without swap'
else
	no 'swap_mb 0 in the plan gives a layout without swap'
fi
runinst -- -d sd1 --swap 0 -u wtfuser -H "$IHASH" -y --progress
if [ $? -eq 2 ] && grep -q 'unknown option --swap' "$IRUN/err"; then
	ok 'the install command takes the options of the contract only (no --swap)'
else
	no 'the install command takes the options of the contract only (no --swap)'
fi
runinst -- -p "$(plan sep '{"version": 1, "mode": "erase", "usage": "separate", "disks": ["sd1"], "layout": "single", "data": [{"name": "data", "disks": ["sd2"], "layout": "single", "filesystem": "ffs", "mount": "/data"}]}')" \
	-u wtfuser -H "$IHASH" -y --progress
_rc=$?
if [ "$_rc" -eq 0 ] && grep -qx 'fdisk -gy sd2' "$IRUN/argv.log" && grep -qx '/data 1M-\* 100%' "$IRUN/argv.log.template" \
	&& grep -q '/data ffs' "$IRUN/tree/etc/fstab" && [ -d "$IRUN/tree/data" ]; then
	ok 'a data disk of the plan gets one FFS on its mount point, in the fstab'
else
	no "a data disk of the plan gets one FFS on its mount point, in the fstab (status $_rc)"
fi
runinst -- -p "$(plan sep2 '{"version": 1, "mode": "erase", "usage": "separate", "disks": ["sd1", "sd2"], "layout": "raid1"}')" \
	-u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'usage separate' 'usage separate takes one system disk with the single layout'
runinst -- -p "$(plan dboth '{"version": 1, "mode": "erase", "disks": ["sd1"], "data": [{"name": "d", "disks": ["sd1"], "mount": "/d"}]}')" \
	-u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'system disk and a data disk' 'a disk cannot be a system disk and a data disk'
runinst -- -p "$(plan unk '{"version": 1, "mode": "erase", "disks": ["sd1"], "colour": "red"}')" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'unknown keys' 'the install command refuses a plan with an unknown key'
runinst -- -p "$(plan encswap '{"version": 1, "mode": "erase", "disks": ["sd1"], "encryption": {"enabled": false, "swap": true}, "swap_mb": 0}')" \
	-u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'encrypted swap needs swap' 'encrypted swap needs swap'


# users: root, locale, autologin; clock; updates; firmware; greeter
# IPv6 documentation addresses, written in full and through variables, so
# the leak check of the repository sees whole documentation addresses only
A6=2001:db8:0:0:0:0:0:10
G6=2001:db8:0:0:0:0:0:1
A6BAD=2001:db8:0:0:0:0:0:zz
V6IF=vio0
_rh=$work/root.hash
secret "$_rh" '$2b$12$ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkjihgfedcba0'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -r "$_rh" -L de_DE.UTF-8 -A \
	-Z local -z Europe/Berlin -U -D 192.0.2.53 -D 2001:db8::53 \
	-N vio0:192.0.2.10/24:192.0.2.1 -6 "${V6IF}:$A6/64:$G6" -6 em1:slaac -y --progress
_rc=$?
_t3=$IRUN/tree
if [ "$_rc" -eq 0 ] && grep -q '^root:\$2b\$12\$ZYXW' "$_t3/etc/master.passwd" \
	&& ! grep -qF 'ZYXWVUTSRQ' "$IRUN/argv.log"; then
	ok '-r FILE gives root the hash of its file, never through an argument'
else
	no "-r FILE gives root the hash of its file, never through an argument (status $_rc, see $IRUN/err)"
fi
if grep -q '^root:\*\*\*\*\*\*\*\*\*\*\*\*\*:' "$_t/etc/master.passwd" 2> /dev/null; then
	ok 'without -r (or -r locked) root is locked'
else
	no 'without -r (or -r locked) root is locked'
fi
if grep -qx 'export LANG=de_DE.UTF-8' "$_t3/home/wtfuser/.profile" 2> /dev/null; then
	ok '-L sets LANG for the account'
else
	no '-L sets LANG for the account'
fi
if grep -qx 'xenodm_flags=NO' "$_t3/etc/rc.conf.local" && grep -qx "${SLUG}_autologin_flags=wtfuser" "$_t3/etc/rc.conf.local" \
	&& grep -q "^pkg_scripts=.*${SLUG}_autologin" "$_t3/etc/rc.conf.local"; then
	ok '-A logs the account in at boot instead of the greeter'
else
	no '-A logs the account in at boot instead of the greeter'
fi
if ! grep -q '_autologin\|xenodm_flags=NO' "$_t/etc/rc.conf.local"; then
	ok 'without -A the greeter shows'
else
	no 'without -A the greeter shows'
fi
_off=$(TZ=Europe/Berlin date +%z | awk '{ s = substr($0, 1, 1); h = substr($0, 2, 2) + 0; m = substr($0, 4, 2) + 0; o = h * 60 + m; if (s == "-") o = -o; print o }')
if grep -qx "kern.utc_offset=$_off" "$_t3/etc/sysctl.conf" 2> /dev/null; then
	ok '-Z local sets the offset of the hardware clock'
else
	no "-Z local sets the offset of the hardware clock (want $_off)"
fi
if grep -qx '/usr/sbin/syspatch' "$_t3/etc/rc.firsttime" && grep -qx '/usr/sbin/pkg_add -u' "$_t3/etc/rc.firsttime"; then
	ok '-U patches the system and updates the packages at the first boot'
else
	no '-U patches the system and updates the packages at the first boot'
fi
if ! grep -q 'syspatch' "$_t/etc/rc.firsttime" 2> /dev/null; then
	ok 'without -U nothing is updated at the first boot'
else
	no 'without -U nothing is updated at the first boot'
fi
if [ "$(cat "$_t3/etc/resolv.conf" 2> /dev/null)" = "$(printf 'nameserver 192.0.2.53\nnameserver 2001:db8::53')" ]; then
	ok '-D writes the name servers'
else
	no '-D writes the name servers'
fi
if [ "$(cat "$_t3/etc/hostname.vio0" 2> /dev/null)" = "$(printf 'inet 192.0.2.10/24\ninet6 %s 64' "$A6")" ] \
	&& [ "$(cat "$_t3/etc/mygate" 2> /dev/null)" = "$(printf '192.0.2.1\n%s' "$G6")" ]; then
	ok '-N and -6 give one adapter an IPv4 and an IPv6 address, each with its route'
else
	no '-N and -6 give one adapter an IPv4 and an IPv6 address, each with its route'
fi
if [ "$(cat "$_t3/etc/hostname.em1" 2> /dev/null)" = 'inet6 autoconf' ]; then
	ok '-6 IF:slaac gives the adapter IPv6 by SLAAC'
else
	no '-6 IF:slaac gives the adapter IPv6 by SLAAC'
fi
runinst -- -d sd1 -u wtfuser -H "$IHASH" -r locked -y --progress
if [ $? -eq 0 ] && grep -q '^root:\*\*\*\*\*\*\*\*\*\*\*\*\*:' "$IRUN/tree/etc/master.passwd"; then
	ok '-r locked locks root'
else
	no '-r locked locks root'
fi
if grep -q "^fw_update DESTDIR=.*/root -p $_ishare/firmware\$" "$IRUN/argv.log"; then
	ok 'the firmware the machine needs comes from the live image (fw_update -p), not the network'
else
	no 'the firmware the machine needs comes from the live image (fw_update -p), not the network'
fi
runinst -- -d sd1 -u wtfuser -H "$IHASH" -6 "${V6IF}:$A6BAD/64:" -y --progress
inst_refused $? 'not an IPv6 address' 'the install command refuses -6 with an IPv6 address that is not one'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -6 "${V6IF}:$A6/0:" -y --progress
inst_refused $? 'prefix length' 'the install command refuses a prefix length of 0'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -N "${V6IF}:$A6/64:" -y --progress
inst_refused $? 'goes with -6' 'the install command sends an IPv6 address given to -N to -6'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -L xx_YY.KOI9 -y --progress
inst_refused $? 'no such locale' 'the install command refuses a locale the system does not have'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -Z sometimes -y --progress
inst_refused $? 'utc or local' 'the install command refuses a clock that is neither utc nor local'

# Wi-Fi (0600 JSON of the contract)
_wf=$work/wifi.json
secret "$_wf" '{"if": "iwm0", "ssid": "Example Net", "security": "wpa2", "psk": "a key of the suite"}'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
_rc=$?
if [ "$_rc" -eq 0 ] && [ "$(cat "$IRUN/tree/etc/hostname.iwm0" 2> /dev/null)" = "$(printf 'join "Example Net" wpakey "a key of the suite"\ninet autoconf\ninet6 autoconf')" ] \
	&& ! grep -q 'a key of the suite' "$IRUN/argv.log" "$IRUN/out" "$IRUN/err"; then
	ok '-W joins the network with ifconfig join and its WPA key, never through an argument'
else
	no "-W joins the network with ifconfig join and its WPA key, never through an argument (status $_rc)"
fi
secret "$_wf" '{"if": "iwm0", "ssid": "Open Example", "security": "open"}'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
if [ $? -eq 0 ] && [ "$(head -n 1 "$IRUN/tree/etc/hostname.iwm0" 2> /dev/null)" = 'join "Open Example"' ]; then
	ok '-W joins an open network without a key'
else
	no '-W joins an open network without a key'
fi
secret "$_wf" '{"if": "iwm0", "ssid": "Example", "security": "wpa2", "psk": "short"}'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
inst_refused $? '8 to 63' 'the install command refuses a WPA key of fewer than 8 characters'
secret "$_wf" '{"if": "iwm0", "ssid": "Ex\"ample", "security": "wpa2", "psk": "long enough key"}'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
inst_refused $? 'may not hold' 'the install command refuses a network name with a quote'
secret "$_wf" '{"if": "iwm0", "ssid": "Example", "security": "wep", "psk": "long enough key"}'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
inst_refused $? 'wpa2, wpa3 or open' 'the install command refuses a security that is not wpa2, wpa3 or open'
chmod 0644 "$_wf"
runinst -- -d sd1 -u wtfuser -H "$IHASH" -W "$_wf" -y --progress
inst_refused $? 'mode 0600' 'the install command refuses a Wi-Fi file others may read'
_ep=$work/short.pass
secret "$_ep" 'short'
runinst -- -p "$(plan shortp '{"version": 1, "mode": "erase", "disks": ["sd1"], "encryption": {"enabled": true}}')" \
	-E "$_ep" -u wtfuser -H "$IHASH" -y --progress
inst_refused $? '8 to 1024 bytes' 'the install command refuses a passphrase shorter than 8 bytes'

# xres_last <file> <resource> — the value xrdb(1) ends with: the last line
# for the resource wins, whatever the #if branches before it chose
xres_last() {
	k="$2" awk 'BEGIN { k = ENVIRON["k"] } index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v) } END { print v }' "$1" 2> /dev/null
}
_xd=$_t/etc/X11/xenodm
if [ "$(xres_last "$_xd/Xresources" 'xlogin*greeting')" = ExampleBSD ]; then
	ok 'the xenodm(1) greeter of the installed system carries the name of the product'
else
	no 'the xenodm(1) greeter of the installed system carries the name of the product'
fi
_lg=$(xres_last "$_xd/Xresources" 'xlogin*logoFileName')
if [ "$_lg" = "/usr/local/share/$SLUG/xenodm/logo.xpm" ] && [ -f "$_t$_lg" ] \
	&& head -1 "$_t$_lg" | grep -q '^/\* XPM \*/$'; then
	ok 'the xenodm(1) greeter of the installed system shows the logo of the product (an XPM of the site set)'
else
	no "the xenodm(1) greeter of the installed system shows the logo of the product (got ${_lg:-none})"
fi
# no OpenBSD default stays in effect: Puffy, the host name, the weave
_def=''
case $_lg in *OpenBSD_*) _def="$_def logo" ;; esac
[ "$(xres_last "$_xd/Xresources" 'xlogin*greeting')" != CLIENTHOST ] || _def="$_def greeting"
[ "$(xres_last "$_xd/Xresources" 'xlogin*background')" != '#596a79' ] || _def="$_def background"
tail -n 16 "$_xd/Xsetup_0" 2> /dev/null | grep -q "xsetroot -solid" || _def="$_def root-weave"
if [ -z "$_def" ]; then
	ok 'no OpenBSD default (Puffy, the host name greeting, the colours, the weave) stays in the xenodm(1) config'
else
	no "no OpenBSD default stays in the xenodm(1) config (still in effect:$_def)"
fi
if grep -q "identity-line.ascii" "$_xd/Xsetup_0" 2> /dev/null && grep -q -- '-geometry +16-12' "$_xd/Xsetup_0" \
	&& grep -qxF "echo \$! > /var/run/$SLUG-identity.pid" "$_xd/Xsetup_0" \
	&& grep -q "kill .*/var/run/$SLUG-identity.pid" "$_xd/Xstartup" \
	&& grep -q "kill .*/var/run/$SLUG-identity.pid" "$_xd/GiveConsole" \
	&& [ "$(tail -n 1 "$_xd/Xstartup")" = 'exec /usr/X11R6/bin/sessreg -a -l $DISPLAY -u /var/run/utmp $USER' ]; then
	ok 'the greeter shows the identity line lower left, and a session removes it (GiveConsole of :0, Xstartup before its exec)'
else
	no 'the greeter shows the identity line lower left, and a session removes it (GiveConsole of :0, Xstartup before its exec)'
fi
cp "$_xd/Xresources" "$work/xres.once"
cp "$_xd/Xsetup_0" "$work/xsetup.once"
sh "$_t/usr/local/libexec/$SLUG/brand-xenodm" "$_t" > /dev/null 2>&1
if cmp -s "$_xd/Xresources" "$work/xres.once" && cmp -s "$_xd/Xsetup_0" "$work/xsetup.once"; then
	ok 'branding xenodm(1) a second time changes nothing'
else
	no 'branding xenodm(1) a second time changes nothing'
fi

# --- the licensed software ---------------------------------------------------

_cat=$work/lic.json
set_file "$LIVE" "usr/local/share/$SLUG/licensed-software.json" > "$_cat"
if python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["os"] == "openbsd" and c["items"] == [] and c["product"] == "ExampleBSD"' "$_cat" 2> /dev/null; then
	ok 'the live image ships licensed-software.json: OpenBSD has nothing that needs a licence acceptance'
else
	no 'the live image ships licensed-software.json: OpenBSD has nothing that needs a licence acceptance'
fi
cp "$_cat" "$_ishare/licensed-software.json"
_acc=$work/accept.json
secret "$_acc" '[]'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -l "$_acc" -y --progress
if [ $? -eq 0 ] && [ "$(cat "$IRUN/tree/var/db/$SLUG/licenses-accepted.json" 2> /dev/null)" = '[]' ]; then
	ok '-l records the accepted licences on the installed system'
else
	no '-l records the accepted licences on the installed system'
fi
secret "$_acc" '[{"id": "vendor-driver", "license": "proprietary", "sha256": "00", "timestamp": "2026-11-01T00:00:00Z"}]'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -l "$_acc" -y --progress
inst_refused $? 'not an item of the licensed software' 'the install command refuses an accepted id that is not in the catalogue'

# --- the hardware report -----------------------------------------------------

_hw=$work/hw
mkdir -p "$_hw/fw" "$_hw/x"
tar -xzf "$LIVE" -C "$_hw/x" "usr/local/libexec/$SLUG/hwreport" 2> /dev/null
cat > "$_hw/dmesg" <<'DMESG'
OpenBSD 7.9 (GENERIC.MP)
iwn0 at pci3 dev 0 function 0 "Intel Old Card" rev 0x00
OpenBSD 8.0 (GENERIC.MP)
inteldrm0 at pci0 dev 2 function 0 "Intel UHD Graphics 620" rev 0x07
iwm0 at pci2 dev 0 function 0 "Intel Dual Band Wireless-AC 8265" rev 0x78, msi
azalia0 at pci0 dev 31 function 3 "Intel 200 Series HD Audio" rev 0x21: msi
em0 at pci0 dev 31 function 6 "Intel I219-V" rev 0x21: msi, address 00:00:5e:00:53:01
pckbd0 at pckbc0 (kbd slot)
sd0 at scsibus1 targ 0 lun 0: <ATA, Example SSD 512, 1.0>
DMESG
printf '# patterns\ninteldrm ^inteldrm\niwm ^iwm[0-9]+ at \n' > "$_hw/patterns"
printf 'x\n' > "$_hw/fw/inteldrm-firmware-x"
_hr=$(HWREPORT_DMESG="$_hw/dmesg" HWREPORT_PATTERNS="$_hw/patterns" HWREPORT_FWDIR="$_hw/fw" \
	sh "$_hw/x/usr/local/libexec/$SLUG/hwreport" 2>&1)
if printf '%s\n' "$_hr" | python3 -I -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' 2> /dev/null \
	&& printf '%s\n' "$_hr" | grep -q '"class": "wifi", "device": "iwm0", "driver": "iwm", "description": "Intel Dual Band Wireless-AC 8265", "firmware": "missing"' \
	&& printf '%s\n' "$_hr" | grep -q '"device": "inteldrm0".*"firmware": "present"' \
	&& printf '%s\n' "$_hr" | grep -q '"class": "audio", "device": "azalia0".*"firmware": "none"' \
	&& printf '%s\n' "$_hr" | grep -q '"class": "input", "device": "pckbd0"' \
	&& ! printf '%s\n' "$_hr" | grep -q 'iwn0'; then
	ok 'the hardware report lists the devices of the last boot, their class, driver and firmware state, as JSON'
else
	no "the hardware report lists the devices of the last boot, their class, driver and firmware state, as JSON ($_hr)"
fi

# --- the refusals of the install command ------------------------------------

runinst -- -d sd0 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'running live system' 'the install command refuses the disk of the running live system'
runinst WTFBSD_TEST_ROOTDEV=aaaaaaaaaaaaaaaa.a -- -d sd0 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'running live system' 'the install command finds the disk of the live system by its DUID too'
runinst WTFBSD_TEST_MOUNTED=/dev/sd1e -- -d sd1 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'mounted file system' 'the install command refuses a disk with a mounted file system'
runinst -- -d sd7 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'no such disk' 'the install command refuses a disk the machine does not have'
runinst -- -d cd0 -u wtfuser -H "$IHASH" -y --progress
inst_refused $? 'not a disk to install onto' 'the install command refuses an optical drive'
runinst -- -d sd1 -u wtfuser -H "$IHASH" --progress
inst_refused $? 'without -y' 'the install command refuses to erase a disk without -y'
runinst -- -d sd1 -u live -H "$IHASH" -y --progress
inst_refused $? 'taken by the system' 'the install command refuses the user name live'
runinst -- -d sd1 -u Wtf -H "$IHASH" -y --progress
inst_refused $? 'not a user name' 'the install command refuses a user name that is not one'
_wh=$work/inst-wide.hash
printf '%s\n' "$HASH" > "$_wh"
chmod 0644 "$_wh"
runinst -- -d sd1 -u wtfuser -H "$_wh" -y --progress
inst_refused $? 'mode 0600' 'the install command refuses a hash file others may read'
_sh=$work/inst-sha.hash
( umask 077; printf '%s\n' '$6$saltsalt$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./abcdefghijklmnopqrstu' > "$_sh" )
runinst -- -d sd1 -u wtfuser -H "$_sh" -y --progress
inst_refused $? 'no bcrypt hash' 'the install command refuses a hash that is not bcrypt (OpenBSD: $2b$)'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -z ../../etc/passwd -y --progress
inst_refused $? 'not a time zone' 'the install command refuses a time zone with ..'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -n 'bad host' -y --progress
inst_refused $? 'not a host name' 'the install command refuses a host name that is not one'
runinst -- -d sd1 -u wtfuser -H "$IHASH" -y
_rc=$?
if [ "$_rc" -eq 0 ] && [ ! -s "$IRUN/out" ] && grep -q 'is installed on sd1' "$IRUN/err"; then
	ok 'without --progress the install command reports on stderr and writes nothing to stdout'
else
	no 'without --progress the install command reports on stderr and writes nothing to stdout'
fi

# --- the live verb of the media helper ----------------------------------------

printf '== the media helper builds the live image ==\n'

# live_copy <name> — a copy of the helper with the fixture stock
# directory, a 1 MB image and the work directory under the suite
live_copy() {
	sed -e "s|^STOCK_DIR=/usr/local/share/wtfbsd-media\$|STOCK_DIR=$2|" \
		-e "s|^LIVE_MB=7168\$|LIVE_MB=1|" \
		-e "s|^LIVE_TMP=/usr/local/share/wtfbsd-media/work\$|LIVE_TMP=$work/vartmp|" \
		"$MEDIA" > "$work/live-$1.sh"
	printf '%s' "$work/live-$1.sh"
}
LSTOCK=$(stock_dir live)
LHELPER=$(live_copy run "$LSTOCK")
if grep -q '^LIVE_MB=1$' "$LHELPER" && grep -q "^STOCK_DIR=$LSTOCK\$" "$LHELPER"; then
	ok 'the copy of the helper the suite runs builds a small image from the fixture stock directory'
else
	no 'the copy of the helper the suite runs builds a small image from the fixture stock directory'
fi

# the tree of the stock image: the eight sets and the kernels
_liso=$work/liveiso
mkdir -p "$_liso/8.0/amd64"
_lb=$work/lbase
_lbe=$work/lbase-etc
mkdir -p "$_lbe/etc/rc.d" "$_lb/dev" "$_lb/var/db" "$_lb/var/sysmerge" "$_lb/usr/share" "$_lb/home"
printf 'root:*:0:0:Charlie &:/root:/bin/ksh\n' > "$_lbe/etc/passwd"
printf 'wheel:*:0:root\n' > "$_lbe/etc/group"
printf 'pkg_scripts=""\n' > "$_lbe/etc/rc.conf.local"
tar -czf "$_lb/var/sysmerge/etc.tgz" -C "$_lbe" etc
printf '#!/bin/sh\nexit 0\n' > "$_lb/dev/MAKEDEV"
tar -czf "$_liso/8.0/amd64/base80.tgz" -C "$_lb" dev var usr home
for _s in comp man game xbase xshare xfont xserv; do
	cp "$_isets/${_s}80.tgz" "$_liso/8.0/amd64/${_s}80.tgz"
done
# a kernel holds its version string, as the release ones do
for _k in bsd bsd.mp bsd.rd; do
	printf 'the kernel %s\n\001OpenBSD 8.0 (GENERIC.MP) #0: Thu Oct  1 00:00:00 MDT 2026\n' "$_k" > "$_liso/8.0/amd64/$_k"
done
# the same tree, but its base set holds etc/rc.d as a symbolic link
_liso2=$work/liveiso-link
cp -R "$_liso" "$_liso2"
_lb2=$work/lbase-link
cp -R "$_lb" "$_lb2"
_lbe2=$work/lbase-etc-link
cp -R "$_lbe" "$_lbe2"
rm -rf "$_lbe2/etc/rc.d"
ln -s /nonexistent/elsewhere "$_lbe2/etc/rc.d"
tar -czf "$_lb2/var/sysmerge/etc.tgz" -C "$_lbe2" etc
tar -czf "$_liso2/8.0/amd64/base80.tgz" -C "$_lb2" dev var usr home

# the stubs of the live verb, in front of the ones of the media helper
_lstub=$work/livestub
mkdir -p "$_lstub"
for _t in fdisk newfs installboot chown; do
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$WTFBSD_TEST_ARGV"\nexit 0\n' "$_t" > "$_lstub/$_t"
done
# ftp(1): the file of -o gets a body; the signed list of the firmware
# names one firmware set
cat > "$_lstub/ftp" <<'STUB'
#!/bin/sh
printf 'ftp %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_o=''
_prev=''
for _a in "$@"; do
	[ "$_prev" = -o ] && _o=$_a
	_prev=$_a
done
case $_o in
SHA256.sig) printf 'untrusted comment: fixture\nSHA256 (iwm-firmware-1.tgz) = BDrLhzPpIYlJ5fZ1gYftBRDTlppbZJw29v7wx/s/WGY=\n' > "$_o" ;;
*) printf 'firmware\n' > "$_o" ;;
esac
STUB
cat > "$_lstub/signify" <<'STUB'
#!/bin/sh
printf 'signify %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
exit "${WTFBSD_TEST_SIGNIFY_RC:-0}"
STUB
cat > "$_lstub/disklabel" <<'STUB'
#!/bin/sh
printf 'disklabel %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
case $1 in -*) exit 0 ;; esac
printf '# /dev/r%sc:\nduid: cccccccccccccccc\n' "$1"
STUB
cat > "$_lstub/chroot" <<'STUB'
#!/bin/sh
printf 'chroot %s\n' "$*" >> "$WTFBSD_TEST_ARGV"
_r=$1
shift
_cache=''
for _a in "$@"; do
	case $_a in PKG_CACHE=*) _cache=${_a#PKG_CACHE=} ;; esac
done
case " $* " in
*" pkg_add "*)
	[ -z "$_cache" ] || { mkdir -p "$_r$_cache" && printf 'pkg\n' > "$_r${_cache%/}/xfce-4.20.tgz"; }
	# pkg_add(1) reports a package it cannot find and still exits 0
	if [ -n "${WTFBSD_TEST_PKG_MISSING:-}" ]; then
		printf "Can't find %s\n" "$WTFBSD_TEST_PKG_MISSING"
	fi
	;;
*" useradd "*)
	printf 'live:*:1100:1100:Live user:/home/live:/bin/ksh\n' >> "$_r/etc/passwd"
	mkdir -p "$_r/home/live"
	;;
esac
exit 0
STUB
chmod +x "$_lstub"/*

# the input of the live verb: site.tgz and live.tgz of the desktop build
_lin=$work/live-in
mkdir -p "$_lin"
LIN_OK=$work/live-in-ok.tar
: > "$LIN_OK"
tar_file "$LIN_OK" site.tgz "$SITE"
tar_file "$LIN_OK" live.tgz "$LIVE"
tar_end "$LIN_OK"

# runlive <helper> <tar> [NAME=VALUE ...] — the live verb with the stubs;
# RUNBASE holds out, err, argv.log, mtree (the new root at its unmount)
runlive() {
	_rh=$1
	_rt=$2
	shift 2
	_mrun=$((_mrun + 1))
	RUNBASE=$work/run-$_mrun
	mkdir -p "$RUNBASE"
	: > "$RUNBASE/argv.log"
	env PATH="$_lstub:$_mstub:$PATH" \
		WTFBSD_TEST_UID="$_uid" \
		WTFBSD_TEST_ARGV="$RUNBASE/argv.log" \
		WTFBSD_TEST_ISO_TREE="$_liso" \
		WTFBSD_TEST_MKDLOG="$RUNBASE/mkd.log" \
		WTFBSD_TEST_VND_COUNT="$RUNBASE/vc" \
		WTFBSD_TEST_MOUNT_COUNT="$RUNBASE/mc" \
		WTFBSD_TEST_VND_STATE="$RUNBASE/vs" \
		WTFBSD_TEST_UMOUNT_TREE="$RUNBASE/mtree" \
		"$@" \
		sh "$_rh" live 8.0 amd64 < "$_rt" > "$RUNBASE/out" 2> "$RUNBASE/err"
}

runlive "$LHELPER" "$LIN_OK"
_rc=$?
_lok=$RUNBASE
_lroot=$_lok/mtree/root
if [ "$_rc" -eq 0 ] && [ "$(wc -c < "$_lok/out" | tr -d ' ')" = 1048576 ]; then
	ok 'the live verb writes the image (LIVE_MB) to stdout'
else
	no "the live verb writes the image (LIVE_MB) to stdout (status $_rc, see $_lok/err)"
fi
if grep -q "^mktemp -d $work/vartmp/wtfbsd-live.XXXXXX\$" "$_lok/argv.log"; then
	ok 'the live verb makes its work directory with mktemp -d under LIVE_TMP'
else
	no 'the live verb makes its work directory with mktemp -d under LIVE_TMP'
fi
_wd=$(head -n 1 "$_lok/mkd.log" 2> /dev/null)
if [ -n "$_wd" ] && [ ! -e "$_wd" ]; then
	ok 'the work directory of the live verb is gone when it ends'
else
	no "the work directory of the live verb is gone when it ends ($_wd)"
fi
if grep -qx 'fdisk -gy -b 532480 vnd1' "$_lok/argv.log" \
	&& grep -q '^disklabel -w -A -T .* vnd1$' "$_lok/argv.log" \
	&& grep -qx 'newfs -q /dev/rvnd1a' "$_lok/argv.log" \
	&& grep -qx 'installboot -p vnd1' "$_lok/argv.log" \
	&& grep -q '^installboot -r .*/root vnd1$' "$_lok/argv.log"; then
	ok 'the live image is a GPT disk with an EFI system partition, one FFS root and the boot loader'
else
	no "the live image is a GPT disk with an EFI system partition, one FFS root and the boot loader (see $_lok/argv.log)"
fi
if grep -q '^mount -t cd9660 -o rdonly,nodev,nosuid /dev/vnd0c ' "$_lok/argv.log"; then
	ok 'the live verb reads the sets from the stock image mounted read-only'
else
	no 'the live verb reads the sets from the stock image mounted read-only'
fi
if [ -f "$_lroot/usr/share/xserv.marker" ] && [ "$(head -n 1 "$_lroot/bsd" 2> /dev/null)" = 'the kernel bsd.mp' ] \
	&& grep -q '^cccccccccccccccc.a / ffs ' "$_lroot/etc/fstab" 2> /dev/null; then
	ok 'the new root holds the sets, bsd.mp as /bsd, and an fstab by DUID'
else
	no 'the new root holds the sets, bsd.mp as /bsd, and an fstab by DUID'
fi
_sd=$_lroot/usr/local/share/$SLUG/sets/8.0/amd64
if [ -f "$_sd/base80.tgz" ] && [ -f "$_sd/xserv80.tgz" ] && [ -f "$_sd/bsd.mp" ] \
	&& cmp -s "$_sd/site80.tgz" "$SITE" && [ -f "$_sd/SHA256.sig" ]; then
	ok 'the live image carries the sets, the kernels, the signed SHA256 and the site set it installs from'
else
	no 'the live image carries the sets, the kernels, the signed SHA256 and the site set it installs from'
fi
if grep -q "^chroot .* env PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/8.0/packages/amd64/ PKG_CACHE=/usr/local/share/$SLUG/packages/ pkg_add -I xfce\$" "$_lok/argv.log" \
	&& grep -q '^chroot .* env PKG_PATH=[^ ]* pkg_add -I py3-gobject3 gtk+3$' "$_lok/argv.log" \
	&& [ -f "$_lroot/usr/local/share/$SLUG/packages/xfce-4.20.tgz" ]; then
	ok 'the packages of the site set land in the cache of the live image; the live packages are installed apart'
else
	no "the packages of the site set land in the cache of the live image; the live packages are installed apart (see $_lok/argv.log)"
fi
if grep -q '^chroot .* useradd -m -u 1100 -g live .* -p  live$' "$_lok/argv.log" \
	&& grep -q '^chroot .* groupadd -g 1100 live$' "$_lok/argv.log"; then
	ok 'the live user gets the first free uid from 1100 and no password'
else
	no 'the live user gets the first free uid from 1100 and no password'
fi
if [ -x "$_lroot/etc/rc.d/${SLUG}_live" ] && [ -x "$_lroot/usr/local/sbin/$SLUG-install" ] \
	&& grep -q 'xenodm_flags=NO' "$_lroot/etc/rc.conf.local" && [ ! -e "$_lroot/install.site" ]; then
	ok 'the site set and then the live set are unpacked over the new root'
else
	no 'the site set and then the live set are unpacked over the new root'
fi
# nothing of the job runs in the new root: the last command of the new
# root comes before the sets are unpacked
_last_chroot=$(grep -n '^chroot ' "$_lok/argv.log" | tail -n 1 | cut -d: -f1)
_first_unpack=$(grep -n '^installboot -r ' "$_lok/argv.log" | cut -d: -f1)
if [ -n "$_last_chroot" ] && [ -n "$_first_unpack" ] && [ "$_last_chroot" -lt "$_first_unpack" ] \
	&& ! grep -q '^chroot .*install.site' "$_lok/argv.log"; then
	ok 'no command runs in the new root after the sets of the job are in it, and install.site never runs'
else
	no 'no command runs in the new root after the sets of the job are in it, and install.site never runs'
fi
if grep -qx 'ftp -V -o SHA256.sig https://firmware.openbsd.org/firmware/8.0/SHA256.sig' "$_lok/argv.log" \
	&& grep -qx 'ftp -V -o iwm-firmware-1.tgz https://firmware.openbsd.org/firmware/8.0/iwm-firmware-1.tgz' "$_lok/argv.log" \
	&& grep -q '^signify -C -p .*/root/etc/signify/openbsd-80-fw.pub -x SHA256.sig$' "$_lok/argv.log" \
	&& [ -f "$_lroot/usr/local/share/$SLUG/firmware/iwm-firmware-1.tgz" ] \
	&& grep -q "^chroot .* fw_update -a -p /usr/local/share/$SLUG/firmware\$" "$_lok/argv.log" \
	&& [ -f "$_lroot/usr/local/share/$SLUG/firmware/SHA256.sig" ]; then
	ok 'the live image carries the firmware of every driver, signed, and the live system uses it'
else
	no 'the live image carries the firmware of every driver, signed, and the live system uses it'
fi
if [ "$(grep -c '^vnconfig -u ' "$_lok/argv.log")" = 2 ] && [ ! -s "$_lok/vs" ]; then
	ok 'the live verb detaches the live image and the stock image'
else
	no 'the live verb detaches the live image and the stock image'
fi

# the refusals: members of the input, then members of the sets
_lrefused() { # _lrefused <status> <pattern> <what>
	if [ "$1" -ne 0 ] && [ ! -s "$RUNBASE/out" ] && grep -q -- "$2" "$RUNBASE/err"; then
		ok "$3"
	else
		no "$3 (status $1; stderr: $(tr '\n' ' ' < "$RUNBASE/err"))"
	fi
}
_lt=$work/live-in-conf.tar
: > "$_lt"
tar_file "$_lt" site.tgz "$SITE"
tar_file "$_lt" install.conf "$_staging/install.conf"
tar_end "$_lt"
runlive "$LHELPER" "$_lt"
_lrefused $? 'only site.tgz and live.tgz are accepted' 'the live verb accepts site.tgz and live.tgz only'

# a live set with a member of each refused kind, built byte by byte
mk_set() { # mk_set <out.tgz> <name> <typeflag> [<linkname>]
	_ms=$work/mkset.tar
	: > "$_ms"
	printf 'x\n' > "$work/mkset.data"
	if [ "$3" = 0 ]; then
		tar_file "$_ms" "$2" "$work/mkset.data"
	else
		tar_hdr "$_ms" "$2" "$3" 0 "${4:-}"
	fi
	tar_end "$_ms"
	gzip -c "$_ms" > "$1"
}
_bad_set() { # _bad_set <name> <typeflag> <linkname> <pattern> <what>
	mk_set "$work/bad-live.tgz" "$1" "$2" "$3"
	_bt=$work/live-in-bad.tar
	: > "$_bt"
	tar_file "$_bt" site.tgz "$SITE"
	tar_file "$_bt" live.tgz "$work/bad-live.tgz"
	tar_end "$_bt"
	runlive "$LHELPER" "$_bt"
	_lrefused $? "$4" "$5"
	if grep -q '^fdisk\|^chroot' "$RUNBASE/argv.log"; then
		no "$5: refused before the image is made"
	else
		ok "$5: refused before the image is made"
	fi
}
_bad_set etc/rc.d/x 2 /etc/master.passwd 'not a regular file' 'the live verb refuses a symbolic link in a set'
_bad_set etc/x 1 etc/master.passwd 'not a regular file' 'the live verb refuses a hard link in a set'
_bad_set ../../etc/x 0 '' 'not a plain relative path' "the live verb refuses a set member with '..'"
_bad_set /etc/x 0 '' 'not a plain relative path' 'the live verb refuses a set member with an absolute path'
_bad_set 'etc/a b' 0 '' 'not a plain relative path' 'the live verb refuses a set member with a blank in its name'

runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_ISO_TREE="$_liso2"
_lrefused $? 'as a symbolic link' 'the live verb refuses to write a set member through a symbolic link of the new root'
if [ ! -e "/nonexistent/elsewhere" ]; then
	ok 'nothing was written through the symbolic link'
else
	no 'nothing was written through the symbolic link'
fi

# BASE of the identity is what the image holds: the version string of its
# kernel, checked against the release and the site set
if grep -q 'live: base system OpenBSD 8.0 (the kernel: OpenBSD 8.0 (GENERIC.MP))' "$_lok/err"; then
	ok 'the live verb reads the base system from the version string of the staged kernel'
else
	no 'the live verb reads the base system from the version string of the staged kernel'
fi
_liso3=$work/liveiso-other
rm -rf "$_liso3"
cp -R "$_liso" "$_liso3"
printf 'the kernel bsd.mp\n\001OpenBSD 7.9 (GENERIC.MP) #0: Thu Oct  1 00:00:00 MDT 2026\n' > "$_liso3/8.0/amd64/bsd.mp"
runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_ISO_TREE="$_liso3"
_lrefused $? 'the kernel of the image is OpenBSD 7.9, not the release 8.0' \
	'the live verb refuses an image whose kernel says another release than the one asked for'
printf 'the kernel bsd.mp\n' > "$_liso3/8.0/amd64/bsd.mp"
runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_ISO_TREE="$_liso3"
_lrefused $? 'holds no version string' 'the live verb refuses an image whose kernel has no version string'
printf 'the kernel bsd.mp\n\001OpenBSD 8.0-beta (GENERIC.MP) #1\n' > "$_liso3/8.0/amd64/bsd.mp"
runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_ISO_TREE="$_liso3"
_lrefused $? 'says BASE=OpenBSD 8.0, the kernel of the image is OpenBSD 8.0-beta' \
	'the live verb refuses an image whose kernel disagrees with BASE of the site set'

# the package lists are data: a name that is not a package name is refused
mkdir -p "$work/badpkg-stage/usr/local/share/$SLUG"
tar -xzf "$LIVE" -C "$work/badpkg-stage"
printf 'gtk+3;reboot\n' > "$work/badpkg-stage/usr/local/share/$SLUG/live-packages.list"
( cd "$work/badpkg-stage" && find . -type f | sed 's|^\./||' > "$work/badpkg.list" )
if tar --version 2> /dev/null | grep -q 'GNU tar'; then
	tar --format=ustar -czf "$work/badpkg.tgz" -C "$work/badpkg-stage" -T "$work/badpkg.list"
else
	tar --format ustar -czf "$work/badpkg.tgz" -C "$work/badpkg-stage" -T "$work/badpkg.list"
fi
_bt=$work/live-in-badpkg.tar
: > "$_bt"
tar_file "$_bt" site.tgz "$SITE"
tar_file "$_bt" live.tgz "$work/badpkg.tgz"
tar_end "$_bt"
runlive "$LHELPER" "$_bt"
_lrefused $? 'not a package name' 'the live verb refuses a package list entry that is not a package name'

runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_PKG_MISSING=gtk+3
_lrefused $? 'could not be installed' "the live verb fails when pkg_add(1) cannot find a package (it exits 0 then)"

runlive "$LHELPER" "$LIN_OK" WTFBSD_TEST_SIGNIFY_RC=1
_lrefused $? 'does not match its signed list' 'the live verb refuses firmware that signify(1) does not verify'

# the mirror of the media node: root-owned, an http(s) URL
printf 'http://127.0.0.1/pub/OpenBSD\n' > "$LSTOCK/installurl"
chmod 0444 "$LSTOCK/installurl"
runlive "$LHELPER" "$LIN_OK"
if [ $? -eq 0 ] && grep -q '^chroot .* env PKG_PATH=http://127.0.0.1/pub/OpenBSD/8.0/packages/amd64/ PKG_CACHE=' "$RUNBASE/argv.log" \
	&& grep -qx 'ftp -V -o SHA256.sig http://127.0.0.1/pub/OpenBSD/firmware/8.0/SHA256.sig' "$RUNBASE/argv.log"; then
	ok 'the live verb takes the packages from the mirror the media node names'
else
	no 'the live verb takes the packages from the mirror the media node names'
fi
chmod 0644 "$LSTOCK/installurl"
printf 'ftp://example.org/pub\n' > "$LSTOCK/installurl"
chmod 0444 "$LSTOCK/installurl"
runlive "$LHELPER" "$LIN_OK"
_lrefused $? 'not an http(s) URL' 'the live verb refuses a mirror that is not an http(s) URL'
chmod 0644 "$LSTOCK/installurl"
printf 'http://127.0.0.1/pub/OpenBSD\n' > "$LSTOCK/installurl"
chmod 0646 "$LSTOCK/installurl"
runlive "$LHELPER" "$LIN_OK"
_lrefused $? 'writable by the group or by others' 'the live verb refuses a mirror file others may write'
rm -f "$LSTOCK/installurl"

# --- the README shows the proof: every image link resolves -------------------

_bad_img=''
_n_img=0
for _img in $(sed -n 's/.*!\[[^]]*\](\([^)]*\)).*/\1/p' "$repo/README.md"); do
	_n_img=$((_n_img + 1))
	case $_img in
		http://* | https://*) _bad_img="$_bad_img $_img(remote)" ;;
		*) [ -f "$repo/$_img" ] || _bad_img="$_bad_img $_img" ;;
	esac
done
if [ -z "$_bad_img" ]; then
	ok "every image link of the README resolves to a file of the repository ($_n_img)"
else
	no "every image link of the README resolves to a file of the repository:$_bad_img"
fi
for _png in "$repo"/docs/screenshots/*.png; do
	[ -f "$_png" ] || continue
	if [ "$(wc -c < "$_png")" -le 307200 ]; then
		ok "the screenshot ${_png##*/} is at most 300 KB"
	else
		no "the screenshot ${_png##*/} is at most 300 KB"
	fi
done

# --- the title of the xenodm(1) greeter is readable ---------------------------

# contrast <rrggbb> <rrggbb> — the WCAG contrast ratio of two colours,
# computed here apart from build.sh
contrast() {
	python3 -I -c '
import sys
def lum(h):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
a, b = sorted((lum(sys.argv[1]), lum(sys.argv[2])), reverse=True)
print("%.2f" % ((a + 0.05) / (b + 0.05)))' "$1" "$2"
}
# the background of the login box, from the branding of xenodm
_xbg=1e2440
for _bc in 3b6ea5 000080 ffff00 596a79; do
	mkconf "greet-$_bc" -e "s/^PROFILE=.*/PROFILE='desktop'/" -e "s/^BRAND_COLOR=.*/BRAND_COLOR='$_bc'/"
	sh "$BUILD" -c "$work/greet-$_bc.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-greet-$_bc" > /dev/null 2>&1
	_gb=$(tar -xOzf "$work/out-greet-$_bc/site80.tgz" "usr/local/share/$SLUG/xenodm/Xresources" 2> /dev/null \
		| sed -n 's/^xlogin\*background: #\([0-9a-f]\{6\}\)$/\1/p')
	[ "${_gb:-}" = "$_xbg" ] || no "the login box of the greeter has the background #$_xbg (got #${_gb:-none})"
	_gc=$(tar -xOzf "$work/out-greet-$_bc/site80.tgz" "usr/local/share/$SLUG/xenodm/Xresources" 2> /dev/null \
		| sed -n 's/^xlogin\*greetColor: #\([0-9a-f]\{6\}\)$/\1/p')
	_cr=$(contrast "${_gc:-$_xbg}" "$_xbg" 2> /dev/null)
	if [ -n "$_gc" ] && c="$_cr" awk 'BEGIN { c = ENVIRON["c"] } BEGIN { exit !(c >= 4.5) }'; then
		ok "the greeter title for brand #$_bc (#$_gc) has a contrast of $_cr:1 (>= 4.5) on #$_xbg"
	else
		no "the greeter title for brand #$_bc has a contrast of at least 4.5:1 on #$_xbg (got #${_gc:-none}, ${_cr:-?}:1)"
	fi
done

# --- the identity of the image and the artwork --------------------------------

# idbuild <name> <sed-expression...> — a desktop site set of a product.conf
# derived from the fixture, built on a fixed day (SOURCE_DATE_EPOCH)
_epoch=1793491200
_day=$(date -u -d "@$_epoch" +%Y-%m-%d 2> /dev/null || date -u -r "$_epoch" +%Y-%m-%d)
idbuild() {
	_n=$1
	shift
	mkconf "id-$_n" -e "s/^PROFILE=.*/PROFILE='desktop'/" "$@"
	rm -rf "$work/out-id-$_n"
	SOURCE_DATE_EPOCH=$_epoch sh "$BUILD" -c "$work/id-$_n.conf" -u operator -k "$KEYFILE" -P "$PWFILE" \
		-o "$work/out-id-$_n" > "$work/id-$_n.log" 2>&1
}
_mid='\302\267'
_dot=$(printf "$_mid")

idbuild plain -e '$a\
'
_ym=$(printf '%s' "$_day" | sed 's/^\([0-9]*\)-\([0-9]*\)-.*/\1.\2/')
_want=$(printf 'PRODUCT=ExampleBSD\nVERSION=%s\nBASE=OpenBSD 8.0\nVARIANT=Default\nARCH=amd64\nBUILD=' "$_ym")
if [ "$(set_file "$work/out-id-plain/site80.tgz" "usr/local/share/$SLUG/identity")" = "$_want" ]; then
	ok 'the identity file matches product.conf (no PRODUCT_VERSION: the year.month of the build; no BUILD on a release)'
else
	no 'the identity file matches product.conf (no PRODUCT_VERSION: the year.month of the build; no BUILD on a release)'
fi

idbuild cyber -e '$a\
PRODUCT_VERSION='"'"'1.0'"'"'\
ARTWORK_VARIANT='"'"'cyberpunk'"'"''
_want=$(printf 'PRODUCT=ExampleBSD\nVERSION=1.0\nBASE=OpenBSD 8.0\nVARIANT=Cyberpunk\nARCH=amd64\nBUILD=')
_line="ExampleBSD 1.0 $_dot OpenBSD 8.0 $_dot Cyberpunk $_dot amd64"
if [ "$(set_file "$work/out-id-cyber/site80.tgz" "usr/local/share/$SLUG/identity")" = "$_want" ] \
	&& [ "$(set_file "$work/out-id-cyber/site80.tgz" "usr/local/share/$SLUG/identity-line")" = "$_line" ]; then
	ok 'PRODUCT_VERSION and ARTWORK_VARIANT reach the identity file and the identity line'
else
	no 'PRODUCT_VERSION and ARTWORK_VARIANT reach the identity file and the identity line'
fi
# the greeter draws the line with core fonts (not UTF-8): its copy has " | "
if [ "$(set_file "$work/out-id-cyber/site80.tgz" "usr/local/share/$SLUG/identity-line.ascii")" = 'ExampleBSD 1.0 | OpenBSD 8.0 | Cyberpunk | amd64' ] \
	&& set_file "$SITE" "usr/local/share/$SLUG/xenodm/Xsetup.append" | grep -q "identity-line.ascii"; then
	ok 'the identity line on the greeter is the ASCII copy (no UTF-8 middle dot in a core font)'
else
	no 'the identity line on the greeter is the ASCII copy (no UTF-8 middle dot in a core font)'
fi
if set_file "$work/out-id-cyber/site80.tgz" "usr/local/share/$SLUG/backgrounds/wallpaper.svg" \
	| grep -qF ">$_line</text>"; then
	ok 'the wallpaper of the desktop is stamped with the identity line'
else
	no 'the wallpaper of the desktop is stamped with the identity line'
fi
idbuild bad -e '$a\
ARTWORK_VARIANT='"'"'Cyber Punk'"'"''
if [ $? -ne 0 ] && grep -q 'ARTWORK_VARIANT must be' "$work/id-bad.log"; then
	ok 'the build refuses an ARTWORK_VARIANT that is not a lowercase name'
else
	no 'the build refuses an ARTWORK_VARIANT that is not a lowercase name'
fi

# a pre-rendered pack of the artwork template (the layout of its
# scripts/pack.sh; the stamp script is a stand-in that marks its output)
# mkpack <name> [spots-header] — the pack in $work/<name>.tar.xz, and $_psum
mkpack() {
	_pk=$work/pack-$1
	_pd=$_pk/examplebsd-0123456789ab-cyberpunk
	rm -rf "$_pk"
	mkdir -p "$_pd/branding" "$_pd/scripts" "$_pd/out/dm/pixmaps" "$_pd/out/dm/xenodm" \
		"$_pd/out/lightdm" "$_pd/out/wallpapers" "$_pd/out/icons/hicolor/48x48/apps" \
		"$_pd/out/icons/hicolor/scalable/apps"
	printf 'name=examplebsd\ncommit=0123456789ab\nvariant=cyberpunk\n' > "$_pd/PACK"
	printf 'NAME="ExampleBSD"\nNAME_LOWER="examplebsd"\n' > "$_pd/palette.env"
	mkdir -p "$_pd/out/console" "$_pd/out/xfce/xfconf"
	printf '# banner\n\t:im=\\r\\nExampleBSD (%%h) (%%t)\\r\\n\\r\\n:\n' > "$_pd/out/console/gettytab.fragment"
	printf '\nExampleBSD - Your BSD, your way\n\n' > "$_pd/out/console/issue"
	printf '<channel name="xfce4-panel"><property name="button-icon" type="string" value="examplebsd-menu"/><property name="button-title" type="string" value="ExampleBSD"/></channel>\n' > "$_pd/out/xfce/xfconf/xfce4-panel.xml"
	printf '<channel name="xsettings"/>\n' > "$_pd/out/xfce/xfconf/xsettings.xml"
	printf 'active_color_1=#2F6FDE\n' > "$_pd/out/xfce/xfwm4-themerc"
	printf '@define-color theme_bg_color #F4F6FB;\n' > "$_pd/out/xfce/gtk-colors.css"
	{
		printf '%s\n' "${2:-spot	what	shows	freebsd	netbsd	openbsd	dragonfly	illumos	size_format	source	rendered	notes}"
		printf 'motd\tm\tconsole\t/etc/motd\t/etc/motd\t/etc/motd\tx\tx\ttext\tconsole/motd.template\tconsole/motd.template\t\n'
		printf 'boot-splash\tb\tboot\t/boot/x\tn/a: no\tn/a: OpenBSD boot has no splash\tx\tx\tpng\tsrc/s.svg\tsplash/s.png\t\n'
		printf 'xenodm-logo\tl\tgreeter\tn/a: x\tn/a: x\t/etc/X11/xenodm/pixmaps/<slug>-color.xpm\tn/a\tn/a\txpm\tsrc/logo.svg\tdm/pixmaps/<slug>-color.xpm, dm/pixmaps/<slug>-8bpp.xpm, dm/pixmaps/<slug>-1bpp.xpm\t\n'
		printf 'xenodm-colours\tc\tgreeter\tn/a\tn/a\t/etc/X11/xenodm/Xresources\tn/a\tn/a\ttext\tdm/xenodm/Xresources\tdm/xenodm/Xresources\t\n'
		printf 'xenodm-background\tg\tgreeter\tn/a\tn/a\t/etc/X11/xenodm/Xsetup_0\tn/a\tn/a\tpng\tsrc/greeter.svg\tdm/xenodm/Xsetup_0, lightdm/greeter-1920x1080.png\t\n'
		printf 'wallpapers\tw\tdesktop\tx\tx\tsame as freebsd\tx\tx\tpng\tsrc/w.svg\twallpapers/wallpaper-1-1920x1080.png\t\n'
		for _i in distributor:logo menu:menu installer:installer; do
			printf 'icon-%s\ti\tmenu\tx\tx\t/usr/local/share/icons/hicolor/<size>/apps/<slug>-%s.png\tx\tx\tpng\tsrc/i.svg\ticons/hicolor/48x48/apps/<slug>-%s.png, icons/hicolor/scalable/apps/<slug>-%s.svg\t\n' \
				"${_i%%:*}" "${_i#*:}" "${_i#*:}" "${_i#*:}"
		done
		printf 'identity-line\ti\tall\tx\tx\tvia xenodm-colours\tx\tx\ttext\tscripts/identity-stamp.sh\t-\t\n'
		printf 'login-issue\tb\tconsole\tx\tx\t/etc/gettytab: im= of the default entry\tx\tx\ttext\tconsole/x\tconsole/gettytab.fragment, console/issue\t\n'
		printf 'xfce-theme\tt\tdesktop\tx\tx\t/usr/local/etc/xdg/xfce4/xfconf/\tx\tx\txml\txfce/x\txfce/xfconf/xfce4-panel.xml, xfce/xfconf/xsettings.xml, xfce/xfwm4-themerc, xfce/gtk-colors.css\t\n'
	} > "$_pd/branding/spots.tsv"
	for _x in color 8bpp 1bpp; do printf '/* XPM */\n/* the pack logo %s */\n' "$_x" > "$_pd/out/dm/pixmaps/examplebsd-$_x.xpm"; done
	cat > "$_pd/out/dm/xenodm/Xresources" <<'XR'
xlogin*greeting: ExampleBSD | Cyberpunk
#if PLANES >= 8
xlogin*background: #1E2440
xlogin*logoFileName: /etc/X11/xenodm/pixmaps/examplebsd-color.xpm
#else
xlogin*logoFileName: /etc/X11/xenodm/pixmaps/examplebsd-1bpp.xpm
#endif
XR
	printf '#!/bin/sh\nBG=/usr/local/share/examplebsd/lightdm/greeter-1920x1080.png\n/usr/X11R6/bin/xsetroot -solid "#14182B"\n/usr/X11R6/bin/xconsole -geometry 480x130-0-0 -daemon -notify -verbose -fn fixed -exitOnFail\n' > "$_pd/out/dm/xenodm/Xsetup_0"
	printf 'the greeter\n' > "$_pd/out/lightdm/greeter-1920x1080.png"
	printf 'wallpaper one\n' > "$_pd/out/wallpapers/wallpaper-1-1920x1080.png"
	for _i in logo menu installer; do
		printf 'png %s\n' "$_i" > "$_pd/out/icons/hicolor/48x48/apps/examplebsd-$_i.png"
		printf 'svg %s\n' "$_i" > "$_pd/out/icons/hicolor/scalable/apps/examplebsd-$_i.svg"
	done
	printf '#!/bin/sh\n# stand-in: [--variant V] [--bottom N] IDENTITY IN OUT\n[ "$1" = --variant ] && shift 2\n[ "$1" = --bottom ] && shift 2\n{ cat "$2"; printf "stamped: "; sed -n "s/^PRODUCT=//p" "$1"; } > "$3"\nprintf "bbox=1x1+0+0\\n"\n' > "$_pd/scripts/identity-stamp.sh"
	( cd "$_pk" && tar -cf - examplebsd-0123456789ab-cyberpunk | xz -c > "$work/$1.tar.xz" )
	_psum=$(sha256sum "$work/$1.tar.xz" 2> /dev/null | cut -d ' ' -f 1 || sha256 -q "$work/$1.tar.xz")
}
# packconf <name> <pack> <sum> — the lines of product.conf naming a pack
packconf() {
	printf "ARTWORK_REF='none'\nARTWORK_PACK='%s'\nARTWORK_PACK_SHA256='%s'\nARTWORK_VARIANT='cyberpunk'\n" "$2" "$3" >> "$work/id-$1.conf"
}
# idbuild2 <name> — idbuild of a conf already written (packconf appends)
idbuild2() {
	rm -rf "$work/out-id-$1"
	SOURCE_DATE_EPOCH=$_epoch sh "$BUILD" -c "$work/id-$1.conf" -u operator -k "$KEYFILE" -P "$PWFILE" \
		-o "$work/out-id-$1" > "$work/id-$1.log" 2>&1
}

mkpack good
mkconf id-pack -e "s/^PROFILE=.*/PROFILE='desktop'/"
packconf pack "$work/good.tar.xz" "$_psum"
idbuild2 pack
_rc=$?
_PS=$work/out-id-pack/site80.tgz
_d="usr/local/share/$SLUG"
if [ "$_rc" -eq 0 ] \
	&& set_file "$_PS" "$_d/xenodm/pixmaps/examplebsd-color.xpm" | grep -q 'the pack logo color' \
	&& set_file "$_PS" "$_d/xenodm/pixmaps/examplebsd-1bpp.xpm" | grep -q 'the pack logo 1bpp' \
	&& set_file "$_PS" "$_d/xenodm/Xresources.pack" | grep -q '^xlogin\*logoFileName: /etc/X11/xenodm/pixmaps/examplebsd-color.xpm$' \
	&& [ "$(set_file "$_PS" "$_d/xenodm/Xresources.pack" | grep '^xlogin\*greeting:' | tail -n 1)" = 'xlogin*greeting: ExampleBSD' ] \
	&& set_file "$_PS" "$_d/xenodm/Xsetup_0.pack" | grep -q "^BG=/usr/local/share/$SLUG/lightdm/" \
	&& has_member "$_PS" "usr/local/share/icons/hicolor/48x48/apps/$SLUG-installer.png" \
	&& has_member "$_PS" "usr/local/share/icons/hicolor/scalable/apps/$SLUG-logo.svg"; then
	ok 'the OpenBSD spots of a verified artwork pack are installed (logos for every depth, login box, setup, icons)'
else
	no "the OpenBSD spots of a verified artwork pack are installed (status $_rc, see $work/id-pack.log)"
fi
if [ "$(set_file "$_PS" "$_d/backgrounds/wallpaper.png")" = "$(printf 'wallpaper one\nstamped: ExampleBSD')" ] \
	&& [ "$(set_file "$_PS" "$_d/lightdm/greeter-1920x1080.png")" = "$(printf 'the greeter\nstamped: ExampleBSD')" ] \
	&& ! has_member "$_PS" "$_d/backgrounds/wallpaper.svg" \
	&& set_file "$_PS" "$_d/identity" | grep -qx 'VARIANT=Cyberpunk'; then
	ok "the wallpaper and the greeter background are stamped with the identity by the pack's identity-stamp.sh"
else
	no "the wallpaper and the greeter background are stamped with the identity by the pack's identity-stamp.sh"
fi
# the xenodm of the installed system with the pack: OpenBSD's files replaced
_px=$work/packx
rm -rf "$_px"
mkdir -p "$_px/root/etc/X11/xenodm"
cp "$work/ixetc/etc/X11/xenodm/"* "$_px/root/etc/X11/xenodm/"
tar -xzf "$_PS" -C "$_px/root"
sh "$_px/root/usr/local/libexec/$SLUG/brand-xenodm" "$_px/root" > /dev/null 2>&1
_xd=$_px/root/etc/X11/xenodm
_lg=$(xres_last "$_xd/Xresources" 'xlogin*logoFileName')
if ! grep -q 'OpenBSD_' "$_xd/Xresources" && ! grep -q 'CLIENTHOST' "$_xd/Xresources" \
	&& ! grep -q root_weave "$_xd/Xsetup_0" && grep -q CLIENTHOST "$_xd/Xresources.openbsd" \
	&& [ -f "$_px/root$_lg" ] && grep -q 'the pack logo' "$_px/root$_lg" \
	&& grep -q identity-line "$_xd/Xsetup_0" && grep -q "kill .*/var/run/$SLUG-identity.pid" "$_xd/Xstartup" \
	&& grep -q "kill .*/var/run/$SLUG-identity.pid" "$_xd/GiveConsole"; then
	ok 'with the pack, xenodm has no OpenBSD default left: the pack replaces its files (kept as .openbsd), logos in pixmaps'
else
	no 'with the pack, xenodm has no OpenBSD default left: the pack replaces its files (kept as .openbsd), logos in pixmaps'
fi
cp "$_xd/Xresources" "$work/pxres.once"; cp "$_xd/Xsetup_0" "$work/pxset.once"
sh "$_px/root/usr/local/libexec/$SLUG/brand-xenodm" "$_px/root" > /dev/null 2>&1
if cmp -s "$_xd/Xresources" "$work/pxres.once" && cmp -s "$_xd/Xsetup_0" "$work/pxset.once" \
	&& grep -q CLIENTHOST "$_xd/Xresources.openbsd"; then
	ok 'branding xenodm with the pack a second time changes nothing and keeps the OpenBSD originals'
else
	no 'branding xenodm with the pack a second time changes nothing and keeps the OpenBSD originals'
fi
# xenodm starts no session when the startup script fails: with nothing to
# kill (pkill exits 1) the branded GiveConsole and Xstartup still succeed
mkdir -p "$work/gcstub"
for _c in pkill sessreg chown id; do printf '#!/bin/sh\nexit %s\n' "$([ $_c = pkill ] && echo 1 || echo 0)" > "$work/gcstub/$_c"; chmod 0755 "$work/gcstub/$_c"; done
sed "s|/usr/X11R6/bin/|$work/gcstub/|g" "$_xd/GiveConsole" > "$work/gc.sh"
sed "s|/usr/X11R6/bin/|$work/gcstub/|g" "$_xd/Xstartup" > "$work/xs.sh"
if PATH="$work/gcstub:$PATH" USER=nobody DISPLAY=:0 sh "$work/gc.sh" > /dev/null 2>&1 \
	&& PATH="$work/gcstub:$PATH" USER=nobody DISPLAY=:0 sh "$work/xs.sh" > /dev/null 2>&1; then
	ok 'the branded GiveConsole and Xstartup succeed when there is nothing to kill (or xenodm refuses the session)'
else
	no 'the branded GiveConsole and Xstartup succeed when there is nothing to kill (or xenodm refuses the session)'
fi
if ! grep -q xconsole "$_xd/Xsetup_0" && grep -q '^pkill -x xconsole' "$_xd/GiveConsole"; then
	ok 'with the pack the greeter starts no xconsole, and a session start removes one (GiveConsole)'
else
	no 'with the pack the greeter starts no xconsole, and a session start removes one (GiveConsole)'
fi
# the login banner of getty: im= of the default entry, from the pack
printf 'default:\\\n\t:np:im=\\r\\n%%s/%%m (%%h) (%%t)\\r\\n\\r\\n:sp#9600:\n\nP|Pc|Pc console:\\\n\t:np:im=\\r\\nother\\r\\n:sp#9600:\n' > "$_px/root/etc/gettytab"
cp "$_px/root/etc/gettytab" "$work/gettytab.orig"
sh "$_px/root/usr/local/libexec/$SLUG/brand-getty" "$_px/root" > /dev/null 2>&1
_g1=$(sed -n 2p "$_px/root/etc/gettytab")
if [ "$_g1" = "$(printf '\t:np:im=\\r\\nExampleBSD (%%h) (%%t)\\r\\n\\r\\n:sp#9600:')" ] \
	&& grep -qF 'im=\r\nother\r\n' "$_px/root/etc/gettytab" && cmp -s "$work/gettytab.orig" "$_px/root/etc/gettytab.openbsd"; then
	ok 'the login banner of getty is the im= of the pack in the default entry only (original kept)'
else
	no "the login banner of getty is the im= of the pack in the default entry only (got: $_g1)"
fi
cp "$_px/root/etc/gettytab" "$work/gettytab.once"
sh "$_px/root/usr/local/libexec/$SLUG/brand-getty" "$_px/root" > /dev/null 2>&1
if cmp -s "$work/gettytab.once" "$_px/root/etc/gettytab"; then
	ok 'branding the login banner a second time changes nothing'
else
	no 'branding the login banner a second time changes nothing'
fi
# the Xfce theme of the pack reaches the first session of an account
_xh=$work/xfhome
rm -rf "$_xh" "$work/xfdefault"
mkdir -p "$_xh" "$work/xfdefault/xfwm4"
printf 'title_alignment=center\n' > "$work/xfdefault/xfwm4/themerc"
printf 'XPM\n' > "$work/xfdefault/xfwm4/close-active.xpm"
printf 'PNG\n' > "$work/xfdefault/xfwm4/close-active.png"
sed -e "s|^X=.*|X=$_px/root/usr/local/share/$SLUG/xfce|" -e "s|^\([[:space:]]*\)B=/usr/local/share/themes/Default/xfwm4|\1B=$work/xfdefault/xfwm4|" \
	-e "s|^W=.*|W=/nonexistent|" -e 's|^\[ -f "\$W" \] \|\| W=.*||' \
	"$_px/root/usr/local/libexec/$SLUG/desktop-defaults" > "$work/dd-theme.sh"
HOME=$_xh XDG_CONFIG_HOME='' sh "$work/dd-theme.sh"
_xc=$_xh/.config/xfce4/xfconf/xfce-perchannel-xml
if grep -q "value=\"$SLUG-menu\"" "$_xc/xfce4-panel.xml" 2> /dev/null && [ -f "$_xc/xsettings.xml" ] \
	&& grep -q "name=\"theme\" type=\"string\" value=\"$SLUG\"" "$_xc/xfwm4.xml" \
	&& [ "$(cat "$_xh/.themes/$SLUG/xfwm4/themerc")" = "$(printf 'title_alignment=center\nactive_color_1=#2F6FDE')" ] \
	&& [ -L "$_xh/.themes/$SLUG/xfwm4/close-active.xpm" ] && [ ! -e "$_xh/.themes/$SLUG/xfwm4/close-active.png" ] \
	&& grep -q "@import url(\"$_px/root/usr/local/share/$SLUG/xfce/gtk-colors.css\")" "$_xh/.config/gtk-3.0/gtk.css"; then
	ok 'the first session gets the Xfce theme of the pack: panel, settings, xfwm4 theme (Default XPMs + pack colours), GTK colours'
else
	no 'the first session gets the Xfce theme of the pack: panel, settings, xfwm4 theme (Default XPMs + pack colours), GTK colours'
fi

mkconf id-packsum -e "s/^PROFILE=.*/PROFILE='desktop'/"
packconf packsum "$work/good.tar.xz" "$(printf '%064d' 0)"
idbuild2 packsum
if [ $? -ne 0 ] && grep -q 'does not match its sha256' "$work/id-packsum.log"; then
	ok 'the build refuses an artwork pack that does not match ARTWORK_PACK_SHA256'
else
	no 'the build refuses an artwork pack that does not match ARTWORK_PACK_SHA256'
fi
mkpack nocol 'spot	what	shows	freebsd	netbsd	open_bsd	dragonfly	illumos	size_format	source	rendered	notes'
mkconf id-packcol -e "s/^PROFILE=.*/PROFILE='desktop'/"
packconf packcol "$work/nocol.tar.xz" "$_psum"
idbuild2 packcol
if [ $? -ne 0 ] && grep -q 'lacks a column this template reads' "$work/id-packcol.log"; then
	ok 'the build fails when branding/spots.tsv lacks a column it reads (by name: spot, openbsd, rendered)'
else
	no 'the build fails when branding/spots.tsv lacks a column it reads (by name: spot, openbsd, rendered)'
fi
mkpack newspot
printf 'console-font\tf\tconsole\tx\tx\t/usr/share/misc/x\tx\tx\tfnt\tsrc/f\tconsole/f\t\n' >> "$work/pack-newspot/examplebsd-0123456789ab-cyberpunk/branding/spots.tsv"
( cd "$work/pack-newspot" && tar -cf - examplebsd-0123456789ab-cyberpunk | xz -c > "$work/newspot.tar.xz" )
mkconf id-packnew -e "s/^PROFILE=.*/PROFILE='desktop'/"
packconf packnew "$work/newspot.tar.xz" "$(sha256sum "$work/newspot.tar.xz" | cut -d ' ' -f 1)"
idbuild2 packnew
if [ $? -ne 0 ] && grep -q 'spot OpenBSD supports that this template does not install: console-font' "$work/id-packnew.log"; then
	ok 'the build fails on a spot OpenBSD supports that the template neither installs nor names as handled elsewhere'
else
	no 'the build fails on a spot OpenBSD supports that the template neither installs nor names as handled elsewhere'
fi
mkpack nofile
rm "$work/pack-nofile/examplebsd-0123456789ab-cyberpunk/out/dm/pixmaps/examplebsd-8bpp.xpm"
( cd "$work/pack-nofile" && tar -cf - examplebsd-0123456789ab-cyberpunk | xz -c > "$work/nofile.tar.xz" )
mkconf id-packnof -e "s/^PROFILE=.*/PROFILE='desktop'/"
packconf packnof "$work/nofile.tar.xz" "$(sha256sum "$work/nofile.tar.xz" | cut -d ' ' -f 1)"
idbuild2 packnof
if [ $? -ne 0 ] && grep -q 'the artwork pack lacks dm/pixmaps/examplebsd-8bpp.xpm (spot xenodm-logo)' "$work/id-packnof.log"; then
	ok 'the build fails when the artwork pack lacks a rendered file of a spot it installs'
else
	no 'the build fails when the artwork pack lacks a rendered file of a spot it installs'
fi

# the pins: without a ref or a directory the build takes the pinned commits
mkconf id-pinart -e "s/^PROFILE=.*/PROFILE='desktop'/"
grep -v '^ARTWORK_REF=' "$work/id-pinart.conf" > "$work/id-pinart.conf.n" && mv "$work/id-pinart.conf.n" "$work/id-pinart.conf"
# the published pack of the pin, from a fixture release directory: right
# sum accepted, any other pack refused
_rel=$work/releases
mkdir -p "$_rel/pack-353ef29aa000"
cp "$work/good.tar.xz" "$_rel/pack-353ef29aa000/examplebsd-353ef29aa000-default.tar.xz"
printf "ARTWORK_RELEASES='file://%s'\n" "$_rel" >> "$work/id-pinart.conf"
idbuild2 pinart
if [ $? -ne 0 ] && grep -q 'the artwork pack does not match its sha256 (10f2507cd0bb325534157f073d79bc08da6a5e1ded34686ebe683a75a0a1d3e4)' "$work/id-pinart.log"; then
	ok 'without ARTWORK_REF, ARTWORK_DIR or ARTWORK_PACK the build fetches the published pack of the pin (353ef29) and refuses one that does not match the pinned sha256'
else
	no 'without ARTWORK_REF, ARTWORK_DIR or ARTWORK_PACK the build fetches the published pack of the pin (353ef29) and refuses one that does not match the pinned sha256'
fi
rm -f "$_rel/pack-353ef29aa000/examplebsd-353ef29aa000-default.tar.xz"
idbuild2 pinart
if [ $? -ne 0 ] && grep -q "cannot download the pack of artwork-template 353ef29aa000eda6c1f274774170a7a691768490 (default): file://$_rel/pack-353ef29aa000/examplebsd-353ef29aa000-default.tar.xz" "$work/id-pinart.log"; then
	ok 'the pack URL of the pin is release pack-<commit12>, <name>-<commit12>-<variant>.tar.xz'
else
	no 'the pack URL of the pin is release pack-<commit12>, <name>-<commit12>-<variant>.tar.xz'
fi
if grep -q '^INSTALLER_PIN=f2e9c48b051f473029ef44a78264b2239ff73141$' "$BUILD" \
	&& grep -qx "INSTALLER_DIR=''" "$BUILD" && grep -qx "ARTWORK_DIR=''" "$BUILD" \
	&& ! grep -Eq "^(INSTALLER|ARTWORK)_DIR=[^']|^(INSTALLER|ARTWORK)_DIR='[^']" "$BUILD"; then
	ok 'build.sh pins installer-template f2e9c48 and names no INSTALLER_DIR or ARTWORK_DIR'
else
	no 'build.sh pins installer-template f2e9c48 and names no INSTALLER_DIR or ARTWORK_DIR'
fi

# the live image brands its greeter too; every session gets the wallpaper
if set_file "$LIVE" "etc/rc.d/${SLUG}_live" | grep -q "/usr/local/libexec/$SLUG/brand-xenodm /"; then
	ok 'the live image brands the greeter of xenodm(1) at boot'
else
	no 'the live image brands the greeter of xenodm(1) at boot'
fi
_dd=$work/dd
rm -rf "$_dd"
mkdir -p "$_dd/home" "$_dd/bin"
set_file "$SITE" "usr/local/libexec/$SLUG/desktop-defaults" > "$_dd/desktop-defaults"
printf '#!/bin/sh\nprintf "Screen 0: minimum 1 x 1\\nVirtual-1 connected 1024x768+0+0\\nVirtual-2 disconnected\\n"\n' > "$_dd/bin/xrandr"
chmod 0755 "$_dd/bin/xrandr"
sed "s|^W=.*|W=$_dd/wall.svg|" "$_dd/desktop-defaults" > "$_dd/dd.sh"
: > "$_dd/wall.svg"
HOME=$_dd/home XDG_CONFIG_HOME='' PATH="$_dd/bin:$PATH" sh "$_dd/dd.sh"
_x=$_dd/home/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml
if grep -q 'name="monitorVirtual-1"' "$_x" 2> /dev/null && ! grep -q 'monitorVirtual-2' "$_x" \
	&& grep -q "name=\"last-image\" type=\"string\" value=\"$_dd/wall.svg\"" "$_x" \
	&& set_file "$SITE" etc/skel/.xsession | grep -q "libexec/$SLUG/desktop-defaults" \
	&& set_file "$SITE" etc/skel/.xinitrc | grep -q "libexec/$SLUG/desktop-defaults" \
	&& set_file "$LIVE" "usr/local/libexec/$SLUG/live-user-session" | grep -q 'desktop-defaults'; then
	ok 'every session sets the stamped wallpaper on each connected output (installed and live)'
else
	no 'every session sets the stamped wallpaper on each connected output (installed and live)'
fi

# every screenshot caption of the README names the BSD it shows
_nc=$(sed -n '/^## What it looks like/,/^## Layout/p' "$repo/README.md" | grep '!\[' | grep -vc 'OpenBSD 8\.0')
if [ "$_nc" -eq 0 ] && sed -n '/^## What it looks like/,/^## Layout/p' "$repo/README.md" | grep -q '!\['; then
	ok 'every screenshot caption of the README names OpenBSD 8.0'
else
	no "every screenshot caption of the README names OpenBSD 8.0 ($_nc do not)"
fi

# --- the product.conf keys of wtfbsd/agents for the live media ------------------
# INSTALLER_REF, INSTALLER_URL, PRODUCT_VERSION, ARTWORK_VARIANT, ARTWORK_REF,
# ARTWORK_SHA256: a value takes the place of the template's pin, an empty one
# keeps it. (The suite's fixture turns both templates off with "none": these
# confs drop those two lines and set the keys themselves.)
# pkconf <name> <lines> — the desktop fixture with the six keys as given
pkconf() {
	grep -v -e '^INSTALLER_REF=' -e '^ARTWORK_REF=' -e '^PROFILE=' "$CONF" > "$work/pk-$1.conf"
	printf "PROFILE='desktop'\n%s\n" "$2" >> "$work/pk-$1.conf"
}
_gsum=$(sha256sum "$work/good.tar.xz" | cut -d ' ' -f 1)
pkconf all "INSTALLER_REF='abcdef1'
INSTALLER_URL='https://example.org/fork/installer-template.git'
PRODUCT_VERSION='1.2'
ARTWORK_VARIANT='cyberpunk'
ARTWORK_REF='0123456789abcdef'
ARTWORK_SHA256='$_gsum'"
sh "$BUILD" -n -c "$work/pk-all.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-all" > "$work/pk-all.log" 2>&1
if [ $? -eq 0 ] && grep -q 'installer-template abcdef1 of https://example.org/fork/installer-template.git' "$work/pk-all.log" \
	&& grep -qF "artwork: artwork-template 0123456789abcdef (cyberpunk), published pack, sha256 $_gsum (product.conf)" "$work/pk-all.log"; then
	ok 'a product.conf with the six keys of wtfbsd/agents is accepted and its values replace the pins'
else
	no "a product.conf with the six keys of wtfbsd/agents is accepted and its values replace the pins (see $work/pk-all.log)"
fi
pkconf empty "INSTALLER_REF=''
INSTALLER_URL=''
PRODUCT_VERSION=''
ARTWORK_VARIANT=''
ARTWORK_REF=''
ARTWORK_SHA256=''"
sh "$BUILD" -n -c "$work/pk-empty.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-empty" > "$work/pk-empty.log" 2>&1
_prc=$?
_ipin=$(sed -n 's/^INSTALLER_PIN=//p' "$BUILD")
_apin=$(sed -n 's/^ARTWORK_PIN=//p' "$BUILD")
if [ "$_prc" -eq 0 ] && [ -n "$_ipin" ] && [ -n "$_apin" ] \
	&& grep -q "installer-template $_ipin of https://github.com/wtfbsd/installer-template.git" "$work/pk-empty.log" \
	&& grep -qF "artwork: artwork-template $_apin (default), published pack, sha256 pinned by this template" "$work/pk-empty.log"; then
	ok 'empty values of the six keys keep the template defaults (the pinned installer and artwork, variant default)'
else
	no "empty values of the six keys keep the template defaults (see $work/pk-empty.log)"
fi
# ARTWORK_REF + ARTWORK_SHA256: the published pack of that commit, checked
_rel2=$work/releases2
rm -rf "$_rel2"
mkdir -p "$_rel2/pack-0123456789ab"
cp "$work/good.tar.xz" "$_rel2/pack-0123456789ab/examplebsd-0123456789ab-cyberpunk.tar.xz"
pkconf dl "INSTALLER_REF='none'
ARTWORK_VARIANT='cyberpunk'
ARTWORK_REF='0123456789abcdef'
ARTWORK_SHA256='$_gsum'
ARTWORK_RELEASES='file://$_rel2'"
rm -rf "$work/out-pk-dl"
SOURCE_DATE_EPOCH=$_epoch sh "$BUILD" -c "$work/pk-dl.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-dl" > "$work/pk-dl.log" 2>&1
if [ $? -eq 0 ] && set_file "$work/out-pk-dl/site80.tgz" "usr/local/share/$SLUG/xenodm/pixmaps/examplebsd-color.xpm" | grep -q 'the pack logo color'; then
	ok 'ARTWORK_REF with ARTWORK_SHA256 installs the published pack of that commit'
else
	no "ARTWORK_REF with ARTWORK_SHA256 installs the published pack of that commit (see $work/pk-dl.log)"
fi
sed -i.bak "s/^ARTWORK_SHA256=.*/ARTWORK_SHA256='$(printf '%064d' 1)'/" "$work/pk-dl.conf"
rm -rf "$work/out-pk-dl"
sh "$BUILD" -c "$work/pk-dl.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-dl" > "$work/pk-dl2.log" 2>&1
if [ $? -ne 0 ] && grep -q 'the artwork pack does not match its sha256' "$work/pk-dl2.log"; then
	ok 'a pack that does not match ARTWORK_SHA256 is refused'
else
	no 'a pack that does not match ARTWORK_SHA256 is refused'
fi
pkconf badvar "ARTWORK_VARIANT='neon'"
sh "$BUILD" -n -c "$work/pk-badvar.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-badvar" > "$work/pk-badvar.log" 2>&1
if [ $? -ne 0 ] && grep -q 'the pinned artwork pack has no variant neon' "$work/pk-badvar.log"; then
	ok 'a variant the pinned artwork pack does not have is refused before the build'
else
	no 'a variant the pinned artwork pack does not have is refused before the build'
fi
pkconf shadir "ARTWORK_SHA256='$_gsum'
ARTWORK_DIR='$work'"
sh "$BUILD" -n -c "$work/pk-shadir.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-shadir" > "$work/pk-shadir.log" 2>&1
if [ $? -ne 0 ] && grep -q 'ARTWORK_SHA256 does not go with ARTWORK_DIR' "$work/pk-shadir.log"; then
	ok 'ARTWORK_SHA256 with ARTWORK_DIR is refused (a checkout is rendered)'
else
	no 'ARTWORK_SHA256 with ARTWORK_DIR is refused (a checkout is rendered)'
fi
pkconf shanone "ARTWORK_SHA256='$_gsum'
ARTWORK_REF='none'"
sh "$BUILD" -n -c "$work/pk-shanone.conf" -u operator -k "$KEYFILE" -P "$PWFILE" -o "$work/out-pk-shanone" > "$work/pk-shanone.log" 2>&1
if [ $? -ne 0 ] && grep -q 'ARTWORK_SHA256 does not go with ARTWORK_REF=none' "$work/pk-shanone.log"; then
	ok 'ARTWORK_SHA256 with ARTWORK_REF=none is refused (the template branding is not a pack)'
else
	no 'ARTWORK_SHA256 with ARTWORK_REF=none is refused (the template branding is not a pack)' "$(cat "$work/pk-shanone.log")"
fi

# --- the live medium: /var/run/wtfbsd-live-medium (installer-template) --------
_lm=$work/livemedium
rm -rf "$_lm"
mkdir -p "$_lm/bin" "$_lm/run"
set_file "$LIVE" "usr/local/libexec/$SLUG/live-medium" > "$_lm/live-medium.sh"
# lmrun <mount line of /> [hw.disknames] — the script with stubs of mount(8)
# and sysctl(8); prints its status
lmrun() {
	printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nprintf "/dev/sd9a on /x type ffs (local)\\n"\n' "$1" > "$_lm/bin/mount"
	printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "${2:-sd0:0123456789abcdef,sd1:fedcba9876543210}" > "$_lm/bin/sysctl"
	chmod 0755 "$_lm/bin/mount" "$_lm/bin/sysctl"
	PATH="$_lm/bin:$PATH" LIVE_MEDIUM_FILE="$_lm/run/wtfbsd-live-medium" sh "$_lm/live-medium.sh" > /dev/null 2>&1
	echo $?
}
_r=$(lmrun '/dev/sd0a on / type ffs (local)')
if [ "$_r" = 0 ] && [ "$(cat "$_lm/run/wtfbsd-live-medium")" = /dev/sd0 ] \
	&& [ "$(ls -l "$_lm/run/wtfbsd-live-medium" | cut -c1-10)" = '-rw-r--r--' ]; then
	ok 'the live image names its medium: the disk of / in /var/run/wtfbsd-live-medium, one line, mode 0644'
else
	no "the live image names its medium (status $_r)"
fi
_r=$(lmrun 'fedcba9876543210.a on / type ffs (local)')
if [ "$_r" = 0 ] && [ "$(cat "$_lm/run/wtfbsd-live-medium")" = /dev/sd1 ]; then
	ok 'a root mounted by its DUID is followed to its disk through hw.disknames'
else
	no "a root mounted by its DUID is followed to its disk through hw.disknames (status $_r)"
fi
rm -f "$_lm/run/wtfbsd-live-medium"
_r=$(lmrun '00000000000000aa.a on / type ffs (local)')
if [ "$_r" != 0 ] && [ ! -e "$_lm/run/wtfbsd-live-medium" ]; then
	ok 'a DUID that hw.disknames does not list writes no medium'
else
	no 'a DUID that hw.disknames does not list writes no medium'
fi
_r=$(lmrun 'tmpfs on / type tmpfs (local)')
if [ "$_r" != 0 ] && [ ! -e "$_lm/run/wtfbsd-live-medium" ]; then
	ok 'a root that is not the partition of a disk writes no medium (the installer then refuses, with LIVE_MEDIUM_REQUIRED)'
else
	no 'a root that is not the partition of a disk writes no medium'
fi
printf 'precious\n' > "$_lm/target"
ln -s "$_lm/target" "$_lm/run/wtfbsd-live-medium"
_r=$(lmrun '/dev/sd0a on / type ffs (local)')
if [ "$_r" = 0 ] && [ ! -L "$_lm/run/wtfbsd-live-medium" ] && [ "$(cat "$_lm/target")" = precious ] \
	&& [ "$(cat "$_lm/run/wtfbsd-live-medium")" = /dev/sd0 ]; then
	ok 'a link planted at /var/run/wtfbsd-live-medium is replaced, never followed'
else
	no 'a link planted at /var/run/wtfbsd-live-medium is replaced, never followed'
fi
if set_file "$LIVE" "etc/rc.d/${SLUG}_live" | awk '/^rc_pre\(\)/ { f = 1; next } f && /libexec/ { print; exit }' \
	| grep -q "/usr/local/libexec/$SLUG/live-medium"; then
	ok 'rc.d/<slug>_live names the live medium first, before the X session'
else
	no 'rc.d/<slug>_live names the live medium first, before the X session'
fi
if set_file "$_it" usr/local/libexec/wtfbsd-installer/installer.conf | grep -qx "LIVE_MEDIUM_REQUIRED=$(sed -n 's/^LIVE_MEDIUM_REQUIRED=//p' "$BUILD")"; then
	ok 'the installer.conf of the live set carries LIVE_MEDIUM_REQUIRED of build.sh'
else
	no 'the installer.conf of the live set carries LIVE_MEDIUM_REQUIRED of build.sh'
fi
# the live boot capture passed (the marker named the disk it booted from),
# so the installer refuses a memory root that names no medium
if [ "$(sed -n 's/^LIVE_MEDIUM_REQUIRED=//p' "$BUILD")" = yes ] \
	&& set_file "$_it" usr/local/libexec/wtfbsd-installer/installer.conf | grep -qx 'LIVE_MEDIUM_REQUIRED=yes'; then
	ok 'the live set requires the live medium (LIVE_MEDIUM_REQUIRED=yes)'
else
	no 'the live set requires the live medium (LIVE_MEDIUM_REQUIRED=yes)'
fi
