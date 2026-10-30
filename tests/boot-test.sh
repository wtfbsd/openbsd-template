#!/bin/sh
#
# tests/boot-test.sh IMAGE PROFILE [NAME] — boot IMAGE in a VM and wait
# for a login.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The VM is driven only through ci/vm.sh, so the test works with every
# provider. The serial console is watched for the "login:" prompt (bounded
# timeout, 600 s by default). For the appliance profile sshd must also
# answer on the guest address. The VM is always destroyed, also when the
# test fails.
#
# usage: tests/boot-test.sh IMAGE PROFILE [NAME]
#
# NAME is the name of the VM. A CI job passes a deterministic name, so the
# job can destroy the VM itself when the test is killed.
#
# Environment:
#   WTFBSD_VM_PROVIDER       the provider to use (see ci/vm.sh)
#   WTFBSD_VM_PROVIDER_PATH  a provider file of your own
#   WTFBSD_BOOT_TIMEOUT      seconds to wait for "login:" (default 600)
#   WTFBSD_SSH_TIMEOUT       seconds to wait for sshd (default 120)
#   WTFBSD_SSH_PORT          port the guest sshd must answer on (default 22)
#   WTFBSD_VM_NAME           name of the VM (default: boot-PROFILE-PID)

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG IMAGE PROFILE [NAME]"
	log ''
	log '  PROFILE appliance: also waits for sshd on the guest address'
	log '  PROFILE desktop:   waits for the login prompt only'
	log '  NAME:              the name of the VM (default: boot-PROFILE-PID)'
	exit "${1:-2}"
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage 2
IMAGE=$1
PROFILE=$2
[ -f "$IMAGE" ] || die "no such image: $IMAGE"
case $PROFILE in
appliance | desktop) ;;
*) die "PROFILE must be appliance or desktop (got: $PROFILE)" ;;
esac

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
VM="$REPO/ci/vm.sh"
[ -x "$VM" ] || die "ci/vm.sh is not executable: $VM"

TIMEOUT=${WTFBSD_BOOT_TIMEOUT:-600}
SSH_TIMEOUT=${WTFBSD_SSH_TIMEOUT:-120}
SSH_PORT=${WTFBSD_SSH_PORT:-22}
NAME=${3:-${WTFBSD_VM_NAME:-boot-$PROFILE-$$}}

CREATED=0
cleanup() {
	if [ "$CREATED" = 1 ]; then
		CREATED=0
		if ! _err=$("$VM" destroy "$NAME" 2>&1 > /dev/null); then
			printf '%s: could not destroy the VM %s\n' "$PROG" "$NAME" >&2
			if [ -n "$_err" ]; then
				printf '%s: %s\n' "$PROG" "$_err" >&2
			fi
		fi
	fi
	return 0
}
on_signal() { # on_signal EXIT_CODE — a signal stops the test at once
	cleanup
	log "interrupted"
	exit "$1"
}
trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

now() { date +%s; }

serial_log() { # serial_log — the content of the serial console so far
	_out=$("$VM" console "$NAME" 2> /dev/null || true)
	case $_out in
	/*)
		if [ -f "$_out" ]; then
			cat "$_out" 2> /dev/null || true
		fi
		;;
	*)
		printf '%s\n' "$_out"
		;;
	esac
}

wait_for_login() { # wait_for_login [seconds]
	_limit=${1:-$TIMEOUT}
	_end=$(( $(now) + _limit ))
	while [ "$(now)" -lt "$_end" ]; do
		if serial_log | grep -q 'login:'; then
			return 0
		fi
		sleep 2
	done
	return 1
}

wait_for_ssh() { # wait_for_ssh [seconds]
	_limit=${1:-$SSH_TIMEOUT}
	_addr=$("$VM" addr "$NAME" 2> /dev/null || true)
	[ -n "$_addr" ] || return 1
	log "waiting for sshd on $_addr port $SSH_PORT"
	_end=$(( $(now) + _limit ))
	while [ "$(now)" -lt "$_end" ]; do
		if nc -z -w 2 "$_addr" "$SSH_PORT" > /dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	return 1
}

log "booting $IMAGE as $PROFILE (vm $NAME)"
"$VM" create "$NAME" "$IMAGE"
CREATED=1

if ! wait_for_login "$TIMEOUT"; then
	die "no login prompt on the serial console within $TIMEOUT s"
fi
log 'login prompt seen'

if [ "$PROFILE" = appliance ]; then
	if ! wait_for_ssh "$SSH_TIMEOUT"; then
		die "sshd did not answer within $SSH_TIMEOUT s"
	fi
	log 'sshd answered'
fi

log 'boot test passed'
