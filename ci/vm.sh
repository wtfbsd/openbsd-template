#!/bin/sh
#
# ci/vm.sh — the one VM front door of this template.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Every VM operation of this repository goes through this script, so the
# CI works the same on every site. The provider is chosen with
# $WTFBSD_VM_PROVIDER:
#
#   ci/providers/<provider>.sh   a provider shipped with this repository
#                                 (exactly one: bhyve)
#   $WTFBSD_VM_PROVIDER_PATH     a provider file outside this repository,
#                                 so a site can plug in its own
#
# An unknown or missing provider fails closed: nothing is started.
#
# Subcommands (the provider gets the same subcommand and arguments):
#   create NAME IMAGE   create a VM named NAME that boots IMAGE
#   console NAME        print the path of the serial console log of NAME
#   addr NAME           print the address of the guest
#   destroy NAME        destroy the VM named NAME

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# The longest name a VM may have. A name is used as a file name, as a
# device name, as an argument of bhyvectl(8) and as a path under the
# state directory of a provider, so it stays short.
MAX_NAME=31

# valid_name NAME — a VM name is a plain identifier: a lower case
# letter, then lower case letters, digits and '-'. A name that holds a
# dot ('.', '..', 'a.b') or a slash is refused: it would leave the
# directory of the VM. The test is a case pattern and a length test on
# purpose: a pattern that is matched line by line (grep) would accept a
# name that holds a newline, and such a name breaks every path and
# every argument built from it. The rule is the one of the shipped
# provider, so the front door and the provider agree.
valid_name() {
	_v=$1
	[ -n "$_v" ] || return 1
	[ "${#_v}" -le "$MAX_NAME" ] || return 1
	# the name starts with a lower case letter
	case $_v in
	[a-z]*) ;;
	*) return 1 ;;
	esac
	# and holds nothing but lower case letters, digits and '-'
	case $_v in
	*[!a-z0-9-]*) return 1 ;;
	esac
	return 0
}

check_name() {
	valid_name "$1" || die "invalid VM name: '$1' (a lower case letter, then lower case letters, digits and '-', at most $MAX_NAME characters)"
}

usage() {
	log "usage: $PROG create NAME IMAGE | console NAME | addr NAME | destroy NAME"
	log ''
	log '  provider: $WTFBSD_VM_PROVIDER (shipped: bhyve) or'
	log '            $WTFBSD_VM_PROVIDER_PATH (a provider file of your own)'
	exit "${1:-2}"
}

[ $# -ge 1 ] || usage 2
CMD=$1
shift

case $CMD in
create)
	[ $# -eq 2 ] || usage 2
	check_name "$1"
	;;
console | addr | destroy)
	[ $# -eq 1 ] || usage 2
	check_name "$1"
	;;
-h | --help)
	usage 0
	;;
*)
	printf '%s: unknown subcommand: %s\n' "$PROG" "$CMD" >&2
	usage 2 >&2
	;;
esac

PROVIDER=${WTFBSD_VM_PROVIDER:-}
[ -n "$PROVIDER" ] \
	|| die 'no VM provider: set WTFBSD_VM_PROVIDER (shipped: bhyve) or WTFBSD_VM_PROVIDER_PATH to a provider file of your own'
case $PROVIDER in
*[!A-Za-z0-9_-]*) die "invalid WTFBSD_VM_PROVIDER (letters, digits, - and _ only): $PROVIDER" ;;
esac

if [ -n "${WTFBSD_VM_PROVIDER_PATH:-}" ]; then
	[ -f "$WTFBSD_VM_PROVIDER_PATH" ] \
		|| die "no such provider file: $WTFBSD_VM_PROVIDER_PATH"
	PROVIDER_FILE=$WTFBSD_VM_PROVIDER_PATH
else
	PROVIDER_FILE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/providers/$PROVIDER.sh"
	[ -f "$PROVIDER_FILE" ] \
		|| die "unknown VM provider '$PROVIDER': no such provider script: $PROVIDER_FILE (shipped providers: $(ls "$(dirname -- "$0")/providers" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' '))"
fi

[ -x "$PROVIDER_FILE" ] || die "provider script is not executable: $PROVIDER_FILE"

exec "$PROVIDER_FILE" "$CMD" "$@"
