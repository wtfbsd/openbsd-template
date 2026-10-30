#!/bin/sh
#
# tests/fixtures/fake-provider.sh — a VM provider that fakes a serial console.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It implements the ci/vm.sh provider contract without touching any
# hypervisor, so the test suite can exercise tests/boot-test.sh on any
# host:
#
#   create NAME IMAGE   writes a canned serial log
#   console NAME        prints the path of that log
#   addr NAME           prints a host name that never resolves
#   destroy NAME        records the call
#
# Every call is appended to $WTFBSD_FAKE_DIR/calls.log, so a test can prove
# that the VM was destroyed.
#
# Environment:
#   WTFBSD_FAKE_DIR    where the fake state is kept (required)
#   WTFBSD_FAKE_LOG    "login" (default) or "nologin": whether the canned
#                      serial log ends in a login prompt
#   WTFBSD_FAKE_ADDR   the address "addr" prints
#                      (default: no-such-host.invalid, which never resolves)
#   WTFBSD_FAKE_FAIL   the subcommand that must fail, e.g. "destroy"

set -eu

PROG=$(basename -- "$0")
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# The longest name a VM may have, and the shape of a name: a lower case
# letter, then lower case letters, digits and '-'. A case pattern and a
# length test, not a pattern matched line by line: a name that holds a
# newline would pass such a test. The rule is the one of ci/vm.sh and of
# the shipped provider: the fake provider stands in for a real one.
MAX_NAME=31

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

DIR=${WTFBSD_FAKE_DIR:-}
[ -n "$DIR" ] || die 'WTFBSD_FAKE_DIR is not set'
mkdir -p "$DIR"

[ $# -ge 1 ] || die 'usage: fake-provider.sh create|console|addr|destroy NAME [IMAGE]'
CMD=$1
shift
[ $# -ge 1 ] || die "usage: $PROG $CMD NAME [IMAGE]"
NAME=$1
valid_name "$NAME" \
	|| die "invalid VM name: '$NAME' (a lower case letter, then lower case letters, digits and '-', at most $MAX_NAME characters)"

printf '%s %s\n' "$CMD" "$NAME" >> "$DIR/calls.log"

case $CMD in
create)
	if [ "${WTFBSD_FAKE_FAIL:-}" = create ]; then
		die "the fake provider cannot create $NAME"
	fi
	{
		cat <<'EOF'
OpenBSD 7.8 (GENERIC) #82: Fri Sep  6 14:24:57 MDT 2024
    Copyright (c) 1982, 1986, 1993, 1994 The Regents of the University of California.

cpu0 at mainbus0: apid 0 (boot processor)
cpu0 at mainbus0: apid 8 (application processor)
real mem = 2048000 (2000 MB)

root on sd0a swap on sd0b
dump on sd0b

initializing disks... done.
checking for presence of other hardware... done.
press ^] to enter alternate boot (or send a carriage return to continue)
EOF
		if [ "${WTFBSD_FAKE_LOG:-login}" = login ]; then
			printf 'login:\n'
		fi
	} > "$DIR/serial.log"
	;;
console)
	printf '%s\n' "$DIR/serial.log"
	;;
addr)
	printf '%s\n' "${WTFBSD_FAKE_ADDR:-no-such-host.invalid}"
	;;
destroy)
	if [ "${WTFBSD_FAKE_FAIL:-}" = destroy ]; then
		die "the fake provider cannot destroy $NAME"
	fi
	;;
*)
	die "unknown subcommand: $CMD"
	;;
esac
