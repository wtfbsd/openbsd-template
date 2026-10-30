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
		choice(
			name: 'PROFILE',
			choices: ['appliance', 'desktop', 'both'],
			description: 'appliance = headless, serial console + key-only sshd; desktop = X11 (Xenocara + xfce, started by xenodm(1)), sshd disabled; both = one site set of each')
		string(
			name: 'RELEASE',
			defaultValue: '7.8',
			description: 'OpenBSD release the site set is built for (N.N); 7.8 builds site78.tgz')
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
			name: 'STOCK_MEDIA',
			defaultValue: '',
			description: 'stock upstream install media (installNN.img or installNN.iso); the boot test fails without it unless ALLOW_NO_BOOT_TEST says so')
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
					*) echo "RELEASE must be N.N, e.g. 7.8 (got: $RELEASE)" >&2; exit 1 ;;
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
					[ -f "$PRODUCT_CONF" ] || { echo "no such product.conf: $PRODUCT_CONF" >&2; exit 1; }
					[ -f "$OPERATOR_PUBKEY" ] || { echo "no such public key file: $OPERATOR_PUBKEY" >&2; exit 1; }
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
					./build.sh "$@"
					ls -l ./out
				'''
			}
		}

		stage('Boot test') {
			agent { label "${params.AGENT_LABEL}" }
			steps {
				sh '''
					set -eu
					list="$VM_LIST"
					if [ -z "$STOCK_MEDIA" ]; then
						if [ "${ALLOW_NO_BOOT_TEST:-no}" = yes ]; then
							echo "STOCK_MEDIA is empty: the boot test is skipped (ALLOW_NO_BOOT_TEST=yes)"
							exit 0
						fi
						echo "STOCK_MEDIA is empty: the boot test cannot run. Set STOCK_MEDIA, or set ALLOW_NO_BOOT_TEST=yes to accept a build without a boot test." >&2
						exit 1
					fi
					[ -f "$STOCK_MEDIA" ] || { echo "no such media: $STOCK_MEDIA" >&2; exit 1; }
					site=$(ls ./out/*/site*.tgz ./out/site*.tgz 2> /dev/null | head -1)
					[ -n "$site" ] || { echo "no site set in ./out" >&2; exit 1; }
					conf=$(ls ./out/*/install.conf ./out/install.conf 2> /dev/null | head -1)
					[ -n "$conf" ] || { echo "no install.conf in ./out" >&2; exit 1; }
					image=$(mktemp -t wtfbsd-boot-media.XXXXXX)
					# The copy of the media is removed when the stage
					# ends, also when it fails.
					trap 'rm -f "$image"' EXIT HUP INT TERM
					cp "$STOCK_MEDIA" "$image"
					./ci/media.sh prepare "$image" "$site" "$conf"
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
						./tests/boot-test.sh "$image" "$profile" "$vm"
					rm -f "$image"
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
