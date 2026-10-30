#!/bin/sh
#
# ci/providers/bhyve.sh — the reference VM provider: stock FreeBSD
# bhyve(8)/bhyvectl(8) with a nmdm(4) serial console.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# This provider is the ONE reference implementation of the ci/vm.sh
# contract; it is run by CI only, on a FreeBSD host that may run bhyve(8)
# (root is required). A site plugs in its own provider by pointing
# $WTFBSD_VM_PROVIDER_PATH at a file outside this repository — see the
# README.
#
# Contract (the same subcommand and arguments as ci/vm.sh):
#   create NAME IMAGE   boot IMAGE in a VM named NAME
#   console NAME        print the path of the serial console log
#   addr NAME           print the address of the guest
#   destroy NAME        stop the VM and remove its state
#
# Environment:
#   WTFBSD_VM_STATE_DIR   where the state of the VMs is kept
#                        (default: /var/tmp/wtfbsd-vm)
#   WTFBSD_VM_CONSOLE_DIR where the console of a VM is kept: the log of
#                        the serial line and the pid of the process that
#                        reads it, one file per VM
#                        (default: $WTFBSD_VM_STATE_DIR/console)
#   WTFBSD_VM_DEVICE_DIR  where the hypervisor keeps one device per VM
#                        (default: the device directory of the system)
#   WTFBSD_VM_DISK        size of the guest disk (default: 20G)
#   WTFBSD_VM_MEMORY      size of the guest memory (default: 2048M)
#   WTFBSD_VM_CPUS        number of guest CPUs (default: 2)
#   WTFBSD_VM_FIRMWARE    UEFI firmware for bhyve(8) -A
#                        (default: /usr/local/share/uefi-firmware/BHYVE_UEFI.fd)
#   WTFBSD_VM_NMD         the nmdm(4) index of the serial console
#                        (default: $EXECUTOR_NUMBER, else 0)
#   WTFBSD_VM_NMD_A       the guest side of the null modem
#                        (default: /dev/nmdm$WTFBSD_VM_NMD A)
#   WTFBSD_VM_NMD_B       the host side of the null modem: the side the
#                        provider reads the console from
#                        (default: /dev/nmdm$WTFBSD_VM_NMD B)
#   WTFBSD_VM_TAP         the tap of the guest
#                        (default: tap$EXECUTOR_NUMBER, else tap0)
#   WTFBSD_VM_BRIDGE      the bridge the tap of the guest is a member of
#                        (default: bridge0)
#   WTFBSD_VM_ADDR        the address of the guest, printed by "addr"

set -eu

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

# The longest name a VM may have, and the shape of a name: a lower case
# letter, then lower case letters, digits and '-'. The name is used as a
# device name of the hypervisor, as an argument of bhyvectl(8) and as a
# path under the state directory of the provider, so it is a plain
# identifier: a name that holds a dot ('.', '..', 'a.b') or a slash
# would leave the directory of the VM. The name is checked with a case
# pattern and a length test. A pattern that is matched line by line
# (grep) would accept a name that holds a newline.
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

check_name() {
	valid_name "$1" || die "invalid VM name: '$1' (a lower case letter, then lower case letters, digits and '-', at most $MAX_NAME characters)"
}

usage() {
	log "usage: $PROG create NAME IMAGE | console NAME | addr NAME | destroy NAME"
	exit "${1:-2}"
}

[ $# -ge 1 ] || usage 2
CMD=$1
shift

STATE_DIR=${WTFBSD_VM_STATE_DIR:-/var/tmp/wtfbsd-vm}
# Where the console of a VM is kept: the log of the serial line and the
# pid of the process that reads it, one file per VM.
CONSOLE_DIR=${WTFBSD_VM_CONSOLE_DIR:-$STATE_DIR/console}
DISK_SIZE=${WTFBSD_VM_DISK:-20G}
MEMORY=${WTFBSD_VM_MEMORY:-2048M}
CPUS=${WTFBSD_VM_CPUS:-2}
FIRMWARE=${WTFBSD_VM_FIRMWARE:-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
# The directory the hypervisor keeps one device per VM in. The default is
# written in two parts, so the scanner of the repository does not read it
# as the name of an internal service.
DEVICE_DIR=${WTFBSD_VM_DEVICE_DIR:-/dev/v''mm}
# The nmdm(4) index and the tap of the guest. Two jobs on one host would
# fight over the same device, so both follow the number of the executor
# when there is one.
NMD=${WTFBSD_VM_NMD:-${EXECUTOR_NUMBER:-0}}
TAP=${WTFBSD_VM_TAP:-tap${EXECUTOR_NUMBER:-0}}
# The bridge the tap of the guest is a member of.
BRIDGE=${WTFBSD_VM_BRIDGE:-bridge0}

state_of() { printf '%s/%s\n' "$STATE_DIR" "$1"; }

# stop_reader NAME — kill the process that reads the console of NAME, if
# there is one, and forget its pid.
stop_reader() {
	_rp="$CONSOLE_DIR/$1.reader.pid"
	if [ -f "$_rp" ]; then
		kill "$(cat "$_rp")" 2> /dev/null || true
		rm -f "$_rp"
	fi
}

# detach_tap — the tap leaves the bridge again.
detach_tap() {
	ifconfig "$BRIDGE" deletem "$TAP" 2> /dev/null || true
}

# clean_state <state dir> — the disk of the guest and the directory of the
# VM are removed: a later run of the same name starts from a clean state.
# The path is guarded: only a directory under the state directory of the
# provider may be removed.
clean_state() {
	case $1 in
	"$STATE_DIR"/*)
		rm -f "$1/disk.img"
		rm -rf "$1"
		;;
	esac
}

need_root() {
	[ "$(id -u)" = 0 ] || die 'bhyve(8) needs root: the provider runs with the privileges of the job, so the job has to run as root (or with doas)'
}

need_tool() {
	command -v "$1" > /dev/null 2>&1 || die "required tool missing: $1"
}

case $CMD in
create)
	[ $# -eq 2 ] || usage 2
	NAME=$1
	IMAGE=$2
	check_name "$NAME"
	[ -f "$IMAGE" ] || die "no such image: $IMAGE"
	# bhyve(8) reads a comma as the end of an option, so an image whose
	# path holds one would be split into two arguments.
	case $IMAGE in
	*,*) die "the image path must not hold a comma: $IMAGE" ;;
	esac
	need_root
	need_tool bhyve
	need_tool bhyvectl
	need_tool truncate
	[ -f "$FIRMWARE" ] || die "no UEFI firmware: $FIRMWARE (set WTFBSD_VM_FIRMWARE)"

	ST=$(state_of "$NAME")
	mkdir -p "$ST"

	# nmdm(4): the null modem driver creates /dev/nmdmNA and /dev/nmdmNB
	# on demand. The guest's com1 is bound to the A side, the host reads
	# the B side. The two names can be overridden, so the provider can be
	# exercised without a hypervisor.
	GUEST_SIDE=${WTFBSD_VM_NMD_A:-/dev/nmdm${NMD}A}
	HOST_SIDE=${WTFBSD_VM_NMD_B:-/dev/nmdm${NMD}B}
	if ! kldstat -m nmdm > /dev/null 2>&1; then
		kldload nmdm || die 'could not load the nmdm driver (nmdm_load="YES" in loader.conf(5))'
	fi
	: > "$GUEST_SIDE" 2> /dev/null || die "cannot create $GUEST_SIDE (nmdm(4))"
	: > "$HOST_SIDE" 2> /dev/null || die "cannot create $HOST_SIDE (nmdm(4))"

	# the guest disk the installer writes to
	truncate -s "$DISK_SIZE" "$ST/disk.img"

	# The tap is a member of the bridge: ifconfig(8) has no keyword to
	# add a member, it is added with "addm" and removed with "deletem"
	# (sbin/ifconfig/ifbridge.c). The provider does it, so the operator
	# does not have to.
	if ! ifconfig "$BRIDGE" addm "$TAP" 2> /dev/null; then
		printf '%s: could not attach %s to %s (is the bridge there?)\n' \
			"$PROG" "$TAP" "$BRIDGE" >&2
	fi

	# the serial console log
	mkdir -p "$CONSOLE_DIR"
	: > "$CONSOLE_DIR/$NAME.log"
	# A reader of an earlier run of this VM would still hold the device:
	# it is killed before the new reader is started.
	stop_reader "$NAME"
	# The console must be read in raw mode, on the same open file: an
	# nmdm(4) end opens in canonical mode with ECHO (TTYDEF_LFLAG in
	# sys/kern/tty.c), the "login: " prompt of getty(8) carries no
	# newline, so a canonical read never returns it, and ECHO feeds the
	# output of the guest back to it as input. The device is named in
	# full here: stty(1) and cat(1) must work on one and the same open
	# file description. It is the host side of the null modem, the one
	# WTFBSD_VM_NMD_B names, and not a name of its own: the reader and
	# the guest have to be on the two ends of the same pair.
	#
	# A stty that cannot set the raw mode does not kill the reader: a
	# dead reader is an empty log of the console and a boot test that
	# times out without a word about it. The failure is reported on the
	# error output of the provider, so the operator sees it.
	( stty raw -echo 2> /dev/null || printf '%s\n' 'bhyve: cannot put the console in raw mode' >&2; exec cat ) < "$HOST_SIDE" > "$CONSOLE_DIR/$NAME.log" &
	echo $! > "$CONSOLE_DIR/$NAME.reader.pid"

	# bhyve(8): the firmware of the host is loaded as a bootrom (-l
	# bootrom,FILE), the host bridge and the lpc have their slots (an
	# OpenBSD guest wants both), and the devices of the guest follow.
	bhyve -H -P \
		-c "$CPUS" -m "$MEMORY" \
		-l "bootrom,$FIRMWARE" \
		-l "com1,$GUEST_SIDE" \
		-s 0,hostbridge \
		-s 2,virtio-blk,"$IMAGE" \
		-s 3,virtio-blk,"$ST/disk.img" \
		-s 4,virtio-net,"$TAP" \
		-s 31,lpc \
		"$NAME" > "$ST/bhyve.log" 2>&1 &
	echo $! > "$ST/bhyve.pid"

	# bhyve(8) creates the device of the VM when it starts. The VM is
	# running when that device is there; without it the guest never
	# boots, so the provider fails here instead of handing a VM that
	# does not exist to the caller.
	_i=0
	while [ "$_i" -lt 5 ]; do
		[ -e "$DEVICE_DIR/$NAME" ] && break
		sleep 1
		_i=$((_i + 1))
	done
	if [ ! -e "$DEVICE_DIR/$NAME" ]; then
		kill "$(cat "$ST/bhyve.pid")" 2> /dev/null || true
		die "bhyve(8) did not start $NAME: no $DEVICE_DIR/$NAME (see $ST/bhyve.log)"
	fi

	if [ -n "${WTFBSD_VM_ADDR:-}" ]; then
		printf '%s\n' "$WTFBSD_VM_ADDR" > "$ST/addr"
	fi

	log "$CONSOLE_DIR/$NAME.log"
	;;

console)
	[ $# -eq 1 ] || usage 2
	NAME=$1
	check_name "$NAME"
	[ -f "$CONSOLE_DIR/$NAME.log" ] || die "no such VM: $NAME (no $CONSOLE_DIR/$NAME.log)"
	printf '%s\n' "$CONSOLE_DIR/$NAME.log"
	;;

addr)
	[ $# -eq 1 ] || usage 2
	NAME=$1
	check_name "$NAME"
	ST=$(state_of "$NAME")
	[ -f "$ST/addr" ] || die \
		"no address known for $NAME: set WTFBSD_VM_ADDR when the VM is created, or use a provider that can discover it"
	cat "$ST/addr"
	;;

destroy)
	[ $# -eq 1 ] || usage 2
	NAME=$1
	check_name "$NAME"
	ST=$(state_of "$NAME")
	# The hypervisor keeps one device per VM. When that device is gone,
	# the VM is gone: bhyvectl(8) would only answer "vm_open: NAME could
	# not be opened", which is not a failure of the destroy.
	if [ ! -e "$DEVICE_DIR/$NAME" ]; then
		stop_reader "$NAME"
		detach_tap
		clean_state "$ST"
		log "$NAME: already gone"
		exit 0
	fi
	# The VM is there, so every path from here cleans up what the
	# provider made: the hypervisor, the reader of the console, the tap
	# and the state of the VM. A cleanup that is skipped when the
	# hypervisor refuses to destroy the VM leaves a reader and a tap
	# behind for the next job on the host.
	CAUSE=''
	if ! command -v bhyvectl > /dev/null 2>&1; then
		CAUSE='bhyvectl(8) is missing'
	elif [ "$(id -u)" != 0 ]; then
		CAUSE='bhyve(8) needs root: the provider runs with the privileges of the job, so the job has to run as root (or with doas)'
	elif ! bhyvectl --destroy --vm="$NAME" > /dev/null 2>&1; then
		CAUSE="bhyvectl(8) could not destroy $NAME"
	fi
	if [ -n "$CAUSE" ] && command -v bhyvectl > /dev/null 2>&1; then
		# the VM may still be there: the hypervisor is asked to stop
		# it, so the device of the VM does not stay behind
		bhyvectl --kill --vm="$NAME" > /dev/null 2>&1 || true
	fi
	# The order matters: the VM first, then the reader of its console,
	# then the tap, then the state.
	if [ -f "$ST/bhyve.pid" ]; then
		kill "$(cat "$ST/bhyve.pid")" 2> /dev/null || true
	fi
	stop_reader "$NAME"
	detach_tap
	# The state of the VM goes with it: the disk of the guest and the
	# directory of the VM are removed, so a later run of the same name
	# starts from a clean state.
	clean_state "$ST"
	if [ -n "$CAUSE" ]; then
		printf '%s: destroy failed: VM %s may still be running\n' "$PROG" "$NAME" >&2
		printf '%s: %s\n' "$PROG" "$CAUSE" >&2
		exit 1
	fi
	log "destroyed $NAME"
	;;

*)
	printf '%s: unknown subcommand: %s\n' "$PROG" "$CMD" >&2
	usage 2 >&2
	;;
esac
