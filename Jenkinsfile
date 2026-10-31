// Jenkinsfile — CI for the OpenBSD template.
//
// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// Generic on purpose: every parameter is a plain string or a choice, the
// VM is driven through ci/vm.sh, and the provider is chosen with
// WTFBSD_VM_PROVIDER, so this file runs unchanged on any Jenkins. The
// credential is referenced by its documented ID only ("wtfbsd-ai-token");
// no secret is ever written here.
//
// The agent label is a parameter. A declarative pipeline cannot use a
// parameter in the top level agent block (the parameters do not exist yet
// when the agent is resolved), so the pipeline runs with "agent none" and
// every stage asks for the node itself.

pipeline {
	agent none

	parameters {
		string(
			name: 'AGENT_LABEL',
			defaultValue: 'bsd-builder',
			description: 'label of the node that runs the build')
		string(
			name: 'MEDIA_AGENT_LABEL',
			defaultValue: 'openbsd',
			description: 'label of the node that prepares the media: it runs OpenBSD, and it runs the installed copy of ci/media.sh (MEDIA_HELPER) as root through doas(1)')
		choice(
			name: 'PROFILE',
			choices: ['appliance', 'desktop', 'both'],
			description: 'appliance = headless, serial console + key-only sshd; desktop = X11 (Xenocara + xfce, started by xenodm(1)), sshd disabled; both = one site set of each')
		string(
			name: 'RELEASE',
			defaultValue: '8.0',
			description: 'OpenBSD release the site set is built for (N.N); 8.0 builds site80.tgz')
		file(
			name: 'PRODUCT_CONF',
			description: 'product.conf to build from (the format of wtfbsd/agents scripts/apply-answers.sh); needs the File Parameter plugin')
		string(
			name: 'OPERATOR_USER',
			defaultValue: 'operator',
			description: 'the account the installer creates; the site set is key-only, so the account needs an SSH public key (OPERATOR_PUBKEY)')
		file(
			name: 'OPERATOR_PUBKEY',
			description: 'the SSH public key of the operator account, one key in the file; needs the File Parameter plugin')
		file(
			name: 'OPERATOR_PASSWORD_HASH',
			description: 'the bcrypt hash of the password of the operator account, one hash in the file; required by the desktop profile (the console is the only way in there), optional for the appliance; needs the File Parameter plugin')
		string(
			name: 'VM_PROVIDER',
			defaultValue: 'bhyve',
			description: 'VM provider used by ci/vm.sh (shipped: bhyve)')
		string(
			name: 'MEDIA_HELPER',
			defaultValue: '/usr/local/libexec/wtfbsd-media',
			description: 'the media helper of the media node: a root owned copy of ci/media.sh, so the rule of doas.conf(5) names a file the account of the job cannot rewrite; it must be the path named in the permit line of doas.conf(5) on the media node, or doas(1) refuses the run')
		string(
			name: 'ARCH',
			defaultValue: 'amd64',
			description: 'the architecture of the sets of the media: the DISTRO_ARCH of product.conf (amd64 or aarch64)')
		string(
			name: 'ALLOW_NO_BOOT_TEST',
			defaultValue: '',
			description: 'yes accepts a build without a boot test (the boot test stage is work in progress: the template has never been boot-tested)')
		string(
			name: 'BOOT_TIMEOUT',
			defaultValue: '600',
			description: 'seconds the boot test waits for the login prompt')
	}

	environment {
		// The list of the VMs this build created. The boot test appends
		// the name of its VM before the VM exists, the post block
		// destroys every name of the list, also when a stage failed.
		VM_LIST = '.wtfbsd-vm-list'
	}

	stages {
		stage('Validate params') {
			agent { label "${params.AGENT_LABEL}" }
			steps {
				script {
					// A file parameter does not land in the workspace of a
					// Pipeline (JENKINS-27413): the file has to be
					// unstashed, or the build reads a product.conf that
					// is not there.
					def productConf = stashedFile(name: 'PRODUCT_CONF')
					unstash 'PRODUCT_CONF'
					echo "product.conf: ${productConf}"
					def operatorPubkey = stashedFile(name: 'OPERATOR_PUBKEY')
					unstash 'OPERATOR_PUBKEY'
					echo "operator public key: ${operatorPubkey}"
					// the password hash is optional: the appliance is
					// key-only, the desktop needs it
					if (params.OPERATOR_PASSWORD_HASH?.trim()) {
						def operatorHash = stashedFile(name: 'OPERATOR_PASSWORD_HASH')
						unstash 'OPERATOR_PASSWORD_HASH'
						echo "operator password hash file: ${operatorHash}"
					}
				}
				sh '''
					set -eu
					list="$VM_LIST"
					: > "$list"
					case "$RELEASE" in
					[0-9]*.[0-9]*) ;;
					*) echo "RELEASE must be N.N, e.g. 8.0 (got: $RELEASE)" >&2; exit 1 ;;
					esac
					case "$PROFILE" in
					appliance | desktop | both) ;;
					*) echo "PROFILE must be appliance, desktop or both" >&2; exit 1 ;;
					esac
					case "$VM_PROVIDER" in
					*[!A-Za-z0-9_-]*) echo "VM_PROVIDER may hold letters, digits, - and _ only" >&2; exit 1 ;;
					esac
					case "$BOOT_TIMEOUT" in
					'' | *[!0-9]*) echo "BOOT_TIMEOUT must be a number of seconds" >&2; exit 1 ;;
					esac
					case "$OPERATOR_USER" in
					'' | *[!a-z0-9_-]*) echo "OPERATOR_USER may hold lowercase letters, digits, - and _ only" >&2; exit 1 ;;
					esac
					case "$ARCH" in
					'' | *[!a-z0-9]*) echo "ARCH must be a lowercase name, e.g. amd64 (got: $ARCH)" >&2; exit 1 ;;
					esac
					[ -f "$PRODUCT_CONF" ] || { echo "no such product.conf: $PRODUCT_CONF" >&2; exit 1; }
					[ -f "$OPERATOR_PUBKEY" ] || { echo "no such public key file: $OPERATOR_PUBKEY" >&2; exit 1; }
					# The architecture of the media is the architecture
					# of the product: the sets of the media are the
					# sets of that architecture. The product.conf is
					# parsed, never sourced, and build.sh reads the
					# same key.
					_prod_arch=''
					while IFS= read -r _line || [ -n "$_line" ]; do
						case $_line in
						'' | '#'*) continue ;;
						DISTRO_ARCH=*) _prod_arch=${_line#DISTRO_ARCH=} ;;
						esac
					done < "$PRODUCT_CONF"
					_prod_arch=$(printf '%s' "$_prod_arch" | tr -cd 'a-z0-9')
					[ -n "$_prod_arch" ] || _prod_arch=amd64
					[ "$_prod_arch" = "$ARCH" ] || {
						echo "the architecture of the media is $ARCH, the DISTRO_ARCH of product.conf is $_prod_arch" >&2
						exit 1
					}
					if [ -n "${OPERATOR_PASSWORD_HASH:-}" ]; then
						[ -f "$OPERATOR_PASSWORD_HASH" ] || { echo "no such password hash file: $OPERATOR_PASSWORD_HASH" >&2; exit 1; }
					fi
					case "$PROFILE" in
					desktop | both)
						# the desktop has no sshd: the console is the only
						# way in, so it needs the password of the account
						[ -n "${OPERATOR_PASSWORD_HASH:-}" ] || { echo "OPERATOR_PASSWORD_HASH is required for the desktop profile" >&2; exit 1; }
						;;
					esac
					echo "product.conf: $PRODUCT_CONF"
					echo "operator: $OPERATOR_USER (public key $OPERATOR_PUBKEY)"
					echo "release: $RELEASE, profile: $PROFILE, provider: $VM_PROVIDER"
				'''
			}
		}

		stage('Build site set') {
			agent { label "${params.AGENT_LABEL}" }
			steps {
				script {
					// every stage asks for its own workspace: the file
					// parameters are unstashed again, so the build works
					// when the stages do not share one node.
					unstash 'PRODUCT_CONF'
					unstash 'OPERATOR_PUBKEY'
					if (params.OPERATOR_PASSWORD_HASH?.trim()) {
						unstash 'OPERATOR_PASSWORD_HASH'
					}
				}
				sh '''
					set -eu
					rm -rf -- ./out
					# the password hash of the operator account is
					# required by the desktop profile and optional for
					# the appliance
					set -- -c "$PRODUCT_CONF" -r "$RELEASE" -p "$PROFILE" -o ./out -u "$OPERATOR_USER" -k "$OPERATOR_PUBKEY"
					if [ -n "${OPERATOR_PASSWORD_HASH:-}" ]; then
						set -- "$@" -P "$OPERATOR_PASSWORD_HASH"
					fi
					# The Build stage runs as the account of the job, on a
					# FreeBSD or Linux node whose tar(1) sets the owner of
					# the members (bsdtar --uid 0, GNU tar --owner=0): no
					# root. Only the Media stage needs the OpenBSD node.
					./build.sh "$@"
					ls -l ./out
				'''
				script {
					// The media stage runs on another node: the site
					// set and the response file travel with a stash.
					stash name: 'SITE_SET', includes: 'out/**/site*.tgz,out/site*.tgz,out/**/install.conf,out/install.conf'
				}
			}
		}

		stage('Media') {
			agent { label "${params.MEDIA_AGENT_LABEL}" }
			steps {
				sh '''
					set -eu
					# The workspace of a node holds the files of the
					# last build that ran there: only the files of
					# this build are used, and no image of another
					# build is ever booted.
					rm -rf -- ./out media.iso
				'''
				script {
					unstash 'SITE_SET'
				}
				sh '''
					set -eu
					# The stock install image is not an input of the
					# job: the media node holds it, root-owned, with the
					# signed SHA256 file of its release, and the helper
					# checks both. Without it the media is not prepared
					# and the boot test cannot run.
					nn=$(printf '%s' "$RELEASE" | tr -d '.')
					stock="/usr/local/share/wtfbsd-media/install$nn.iso"
					if [ ! -f "$stock" ]; then
						if [ "${ALLOW_NO_BOOT_TEST:-no}" = yes ]; then
							echo "no stock image $stock on the media node: the media is not prepared and the boot test is skipped (ALLOW_NO_BOOT_TEST=yes)"
							exit 0
						fi
						echo "no stock image $stock on the media node: the media cannot be prepared. Install it as README.md says (The media stage), or set ALLOW_NO_BOOT_TEST=yes to accept a build without a boot test." >&2
						exit 1
					fi
					# The site set and the response file are named by
					# the exact path the build writes them to: the
					# profile appliance and the profile desktop write
					# them into the output directory itself, the
					# profile both writes them into a directory of
					# their name.
					case $PROFILE in
					appliance | desktop) outdir=./out ;;
					both) outdir=./out/appliance ;;
					*) echo "unknown profile: $PROFILE" >&2; exit 1 ;;
					esac
					# The inputs of the helper are exactly two regular
					# files, and they come on stdin, not on the command
					# line: a ustar tar of site.tgz and install.conf.
					# The tar(1) of OpenBSD writes pax by default, whose
					# extended headers the helper refuses, so the format
					# is named: -F ustar. No path of the job is passed
					# to the helper.
					inputs="$PWD/.wtfbsd-inputs"
					rm -rf -- "$inputs"
					mkdir -p "$inputs"
					# the build names the site set after the release
					# (site80.tgz); the helper reads it as site.tgz
					cp "$outdir/site$nn.tgz" "$inputs/site.tgz" \
						|| { echo "cannot stage the site set" >&2; exit 1; }
					cp "$outdir/install.conf" "$inputs/install.conf" \
						|| { echo "cannot stage the response file" >&2; exit 1; }
					tar -c -F ustar -f inputs.tar -C "$inputs" site.tgz install.conf \
						|| { echo "cannot build inputs.tar" >&2; exit 1; }
					# The image comes out of the helper on stdout. It
					# is written to a temporary file first, and renamed
					# only after the run succeeded, so a failed run
					# leaves no image behind.
					# The helper runs as root: the media node grants it
					# with doas.conf(5), and the rule names the installed
					# copy of the helper, a file the account of the job
					# cannot rewrite.
					[ -x "$MEDIA_HELPER" ] || {
						echo "the media helper is missing on the media node: $MEDIA_HELPER (install it with: install -o root -g wheel -m 0555 ci/media.sh $MEDIA_HELPER) and set MEDIA_HELPER to its path" >&2
						exit 1
					}
					# The copies of the workspace go when the stage ends,
					# also when a signal stops it: a trap on EXIT alone
					# is not run when the stage is killed.
					cleanup() {
						rm -rf -- "$inputs"
						rm -f -- inputs.tar media.iso.tmp
					}
					trap 'cleanup' EXIT
					trap 'exit 129' HUP
					trap 'exit 130' INT
					trap 'exit 143' TERM
					doas "$MEDIA_HELPER" prepare "$RELEASE" "$ARCH" \
						< inputs.tar > media.iso.tmp \
						&& mv media.iso.tmp media.iso
				'''
				script {
					// The boot test runs on another node: the image
					// travels with a stash.
					stash name: 'MEDIA_ISO', includes: 'media.iso', allowEmpty: true
				}
			}
		}

		stage('Boot test') {
			agent { label "${params.AGENT_LABEL}" }
			steps {
				sh '''
					set -eu
					# The image of the last build that ran on this
					# node is not the image of this build: it goes
					# before the stash, so a leftover is never
					# booted.
					rm -f -- media.iso
				'''
				script {
					unstash 'MEDIA_ISO'
				}
				sh '''
					set -eu
					list="$VM_LIST"
					if [ ! -f media.iso ]; then
						if [ "${ALLOW_NO_BOOT_TEST:-no}" = yes ]; then
							echo "no media.iso: no boot test is run (ALLOW_NO_BOOT_TEST=yes)"
							exit 0
						fi
						echo "no media.iso: the boot test cannot run. The media stage prepares it, or ALLOW_NO_BOOT_TEST=yes accepts a build without a boot test." >&2
						exit 1
					fi
					profile=$PROFILE
					[ "$profile" = both ] && profile=appliance
					# A deterministic name, so two jobs never fight over
					# the same VM and the post block knows what to
					# destroy. The name of a VM is a plain identifier:
					# a lower case letter, then lower case letters,
					# digits and '-', at most 31 characters. The number
					# of the build comes first, so a long name of the
					# job never hides it.
					job=$(printf '%s' "$JOB_BASE_NAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-8)
					vm=$(printf 'boot-%s-%s-%s' "$BUILD_NUMBER" "$profile" "$job" | cut -c1-31)
					[ -n "$vm" ] || { echo "empty VM name" >&2; exit 1; }
					echo "$vm" >> "$list"
					WTFBSD_VM_PROVIDER="$VM_PROVIDER" WTFBSD_BOOT_TIMEOUT="$BOOT_TIMEOUT" \
						./tests/boot-test.sh media.iso "$profile" "$vm"
				'''
			}
		}

		stage('Archive') {
			agent { label "${params.AGENT_LABEL}" }
			steps {
				// The response file holds the hash of the password of
				// the operator account: it is a secret, and an archived
				// artefact must not carry one. The redacted copy of it
				// is archived instead.
				archiveArtifacts(
					artifacts: 'out/**/site*.tgz,out/**/install.conf.redacted,out/**/SHA256',
					allowEmptyArchive: false)
			}
		}
	}

	post {
		always {
			// never leave a VM behind, also when a stage failed. Every
			// name of the list is destroyed, not only the last one. With
			// "agent none" there is no node for the post block, so it
			// asks for one itself.
			script {
				node(params.AGENT_LABEL) {
					sh '''
						set -eu
						list="$VM_LIST"
						[ -f "$list" ] || exit 0
						while IFS= read -r vm; do
							[ -n "$vm" ] || continue
							echo "destroying $vm"
							WTFBSD_VM_PROVIDER="${VM_PROVIDER:-bhyve}" ./ci/vm.sh destroy "$vm" || true
						done < "$list"
					'''
				}
			}
		}
	}
}
