#!/bin/sh
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# A stand-in of the install-into-stage.sh of the installer-template, for
# the suite: it writes the launcher, the menu entry and the autostart entry
# the real one writes, and the configuration it was given, so the suite can
# check what build.sh hands it.
#
#   install-into-stage.sh DESTDIR [--conf FILE] [--metalog FILE]
#
# Like the real one, it refuses to run without root unless it is given a
# metalog to write the owners into.

set -eu
dest=$1
shift
conf=''
metalog=''
while [ $# -gt 0 ]; do
	case $1 in
		--conf) conf=$2; shift 2 ;;
		--metalog) metalog=$2; shift 2 ;;
		*) printf 'install-into-stage: unknown argument %s\n' "$1" >&2; exit 2 ;;
	esac
done
[ -d "$dest" ] || exit 2
if [ "$(id -u)" != 0 ] && [ -z "$metalog" ]; then
	printf 'install-into-stage: not root and no --metalog\n' >&2
	exit 2
fi
[ -z "$metalog" ] || printf './usr/local/bin/wtfbsd-installer type=file uname=root gname=wheel mode=0755\n' >> "$metalog"
mkdir -p "$dest/usr/local/bin" "$dest/usr/local/share/applications" \
	"$dest/usr/local/share/wtfbsd-installer/autostart" \
	"$dest/usr/local/libexec/wtfbsd-installer/bin"
printf '#!/bin/sh\n# the launcher of the graphical installer (fixture)\n' > "$dest/usr/local/bin/wtfbsd-installer"
chmod 755 "$dest/usr/local/bin/wtfbsd-installer"
printf '#!/bin/sh\n# the graphical installer (fixture)\n' > "$dest/usr/local/libexec/wtfbsd-installer/bin/installer-gui"
chmod 755 "$dest/usr/local/libexec/wtfbsd-installer/bin/installer-gui"
printf '[Desktop Entry]\nName=Install\n' > "$dest/usr/local/share/applications/wtfbsd-installer.desktop"
printf '[Desktop Entry]\nName=Installer\n' > "$dest/usr/local/share/wtfbsd-installer/autostart/wtfbsd-installer.desktop"
if [ -n "$conf" ]; then
	cp "$conf" "$dest/usr/local/libexec/wtfbsd-installer/installer.conf"
fi
printf 'install-into-stage: installed (fixture)\n'
