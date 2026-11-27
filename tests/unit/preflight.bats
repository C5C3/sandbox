#!/usr/bin/env bats
# preflight_run: the host check, on a simulated host.

setup() {
	load helpers
	healthy_host
}

COMMON_CHECKS="os,cgroup,docker,inotify,tool docker,tool kind,tool kubectl,tool jq,tool helm,tool flux,tool git,tool yq,tool openstack,plugin osc-placement,plugin python-barbicanclient,config,resolver"

@test "a healthy host passes every check of the three roles" {
	run preflight_run management storage compute
	[ "$status" -eq 0 ]
	[[ $'\n'$output != *$'\n'"FAIL "* && $'\n'$output != *$'\n'"warn "* ]]
	[ "$(check_ids)" = "${COMMON_CHECKS%,resolver},module loop,module openvswitch,module geneve,module vhost_net,kvm,resolver" ]
	[ "${lines[-1]}" = "preflight: 0 failed, 0 warnings" ]
}

@test "without a role only the checks of every role run" {
	run preflight_run
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = "$COMMON_CHECKS" ]
	[[ $output != *module* && $output != *kvm* ]]
}

@test "an operating system other than Linux on x86_64 fails" {
	for os in "Darwin arm64" "Linux aarch64"; do
		probe_os() { echo "$os"; }
		run preflight_run management
		[ "$status" -eq 1 ]
		[[ $output == *"FAIL os: Linux on x86_64 required, found $os"* ]]
	done
}

@test "cgroup v1 fails" {
	probe_cgroup_fstype() { echo tmpfs; }
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL cgroup: cgroup v2 required, /sys/fs/cgroup is tmpfs"* ]]
}

@test "an unreachable Docker daemon fails with the first line of its error" {
	probe_docker_security() {
		echo null
		printf 'Cannot connect to the Docker daemon\nsecond line\n' >&2
		return 1
	}
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL docker: cannot reach the Docker daemon: Cannot connect to the Docker daemon"$'\n'* ]]
}

@test "a rootless Docker daemon fails" {
	probe_docker_security() { echo '["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]'; }
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL docker: rootful Docker required, the daemon runs rootless"* ]]
}

@test "too few inotify instances fail and 512 pass" {
	probe_inotify_instances() { echo 128; }
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL inotify: fs.inotify.max_user_instances is 128, 512 or more required"* ]]

	probe_inotify_instances() { echo 512; }
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *"ok inotify: 512"* ]]
}

@test "an unreadable inotify setting fails" {
	for answer in "" "max"; do
		probe_inotify_instances() { printf '%s' "$answer"; }
		run preflight_run management
		[ "$status" -eq 1 ]
		[[ $output == *"FAIL inotify: cannot read fs.inotify.max_user_instances"* ]]
	done
}

@test "a missing required tool fails for every role" {
	for missing in docker kind kubectl jq helm flux git yq; do
		probe_tool() { [ "$1" != "$missing" ] && tool_version "$1"; }
		for role in management storage compute; do
			run preflight_run "$role"
			[ "$status" -eq 1 ]
			[[ $output == *"FAIL tool $missing: not found in PATH"* ]]
		done
	done
}

@test "yq must be mikefarah yq v4.40.1 or newer" {
	probe_tool() {
		if [ "$1" = yq ]; then echo "yq (https://github.com/mikefarah/yq/) version v4.40.0"; else tool_version "$1"; fi
	}
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL tool yq: mikefarah yq v4.40.1 or newer required, found yq (https://github.com/mikefarah/yq/) version v4.40.0"* ]]

	probe_tool() {
		if [ "$1" = yq ]; then echo "yq 4.44.3"; else tool_version "$1"; fi
	}
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL tool yq: mikefarah yq v4.40.1 or newer required, found yq 4.44.3"* ]]

	probe_tool() {
		if [ "$1" = yq ]; then echo "yq (https://github.com/mikefarah/yq/) version v4.40.1"; else tool_version "$1"; fi
	}
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *"ok tool yq: yq (https://github.com/mikefarah/yq/) version v4.40.1"* ]]
}

@test "an unusable yq leaves the configuration and the resolver unchecked" {
	probe_tool() { [ "$1" != yq ] && tool_version "$1"; }
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL config: not checked, yq is unusable"* ]]
	[[ $output == *"warn resolver: not checked, the configuration is unusable"* ]]
}

@test "a missing openstack only warns and skips its plugins" {
	probe_tool() { [ "$1" != openstack ] && tool_version "$1"; }
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *"warn tool openstack: not found in PATH"* ]]
	[[ $output != *plugin* ]]
}

@test "a missing OpenStack CLI plugin only warns" {
	for missing in python-barbicanclient osc-placement; do
		probe_openstack_plugin() { [ "$1" != "$missing" ]; }
		run preflight_run management
		[ "$status" -eq 0 ]
		[[ $output == *"warn plugin $missing: OpenStack CLI plugin missing"* ]]
	done
}

@test "an invalid configuration fails with the message of config_load" {
	config_with '.network.subnet = "foo"'
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL config: config: network.subnet 'foo' is not an IPv4 CIDR"* ]]
	[[ $output == *"warn resolver: not checked, the configuration is unusable"* ]]
}

@test "a missing loop module fails storage and is not checked for the other roles" {
	probe_module() { [ "$1" != loop ]; }
	run preflight_run storage
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL module loop: neither loaded nor in the module tree of this kernel"* ]]

	run preflight_run management compute
	[ "$status" -eq 0 ]
	[[ $output != *"module loop"* ]]
}

@test "a missing network module fails compute and is not checked for the other roles" {
	for missing in openvswitch geneve vhost_net; do
		probe_module() { [ "$1" != "$missing" ]; }
		run preflight_run compute
		[ "$status" -eq 1 ]
		[[ $output == *"FAIL module $missing: neither loaded nor in the module tree of this kernel"* ]]

		run preflight_run management storage
		[ "$status" -eq 0 ]
		[[ $output != *"module $missing"* ]]
	done
}

# nfs_profile <modules of management>: points SANDBOX_PROFILE_FILE, as
# profile_load would, at a profile whose management cluster lists the
# modules, given as a YAML list.
nfs_profile() {
	export SANDBOX_PROFILE_FILE=$BATS_TEST_TMPDIR/nfs.yaml
	printf 'clusters: [management, storage]\nmodules:\n  management: %s\n  storage: [cinder-nfs]\n' "$1" >"$SANDBOX_PROFILE_FILE"
}

@test "a profile with cinder-nfs on management checks the modules nfs and nfsv4 after those of the roles" {
	nfs_profile '[crds, cinder-nfs]'
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"ok module nfs: available"$'\n'"ok module nfsv4: available"$'\n'* ]]
	[ "$(check_ids)" = "${COMMON_CHECKS%,resolver},module nfs,module nfsv4,resolver" ]

	run preflight_run management storage compute
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = "${COMMON_CHECKS%,resolver},module loop,module openvswitch,module geneve,module vhost_net,module nfs,module nfsv4,kvm,resolver" ]
}

@test "a missing module nfs or nfsv4 fails a profile with cinder-nfs" {
	nfs_profile '[cinder-nfs]'
	for missing in nfs nfsv4; do
		probe_module() { [ "$1" != "$missing" ]; }
		run preflight_run management
		[ "$status" -eq 1 ]
		[[ $output == *$'\n'"FAIL module $missing: neither loaded nor in the module tree of this kernel"$'\n'* ]]
		[ "${lines[-1]}" = "preflight: 1 failed, 0 warnings" ]
	done
}

@test "the modules nfs and nfsv4 are not checked without cinder-nfs on management or without a loaded profile" {
	probe_module() { [ "$1" != nfs ] && [ "$1" != nfsv4 ]; }
	nfs_profile '[crds, controllers]'
	run preflight_run management storage
	[ "$status" -eq 0 ]
	[[ $output != *"module nfs"* ]]

	export SANDBOX_PROFILE=identity
	profile_load
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output != *"module nfs"* ]]

	for value in unset empty; do
		if [ "$value" = unset ]; then unset SANDBOX_PROFILE_FILE; else export SANDBOX_PROFILE_FILE=; fi
		run preflight_run management
		[ "$status" -eq 0 ]
		[[ $output != *"module nfs"* ]]
	done
}

@test "profile_load of controlplane makes the host check test the modules nfs and nfsv4" {
	export SANDBOX_PROFILE=controlplane
	profile_load
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"ok module nfs: available"$'\n'"ok module nfsv4: available"$'\n'* ]]
}

# preflight_copy: copies scripts/ into the test's directory, with the probes
# of healthy_host in place of those of its scripts/lib/preflight.sh.
preflight_copy() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	declare -f tool_version probe_os probe_cgroup_fstype probe_docker_security probe_inotify_instances probe_tool \
		probe_openstack_plugin probe_module probe_kvm probe_resolve >>"$BATS_TEST_TMPDIR/scripts/lib/preflight.sh"
}

@test "scripts/preflight.sh loads no profile and does not check the modules nfs and nfsv4" {
	preflight_copy
	profile_with $'clusters: [management]\nmodules:\n  management: [cinder-nfs]'
	run "$BATS_TEST_TMPDIR/scripts/preflight.sh" management
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "preflight: 0 failed, 0 warnings" ]
	[[ $output != *"module nfs"* ]]
}

@test "scripts/preflight.sh does not check the modules nfs and nfsv4 when SANDBOX_PROFILE_FILE is set by hand" {
	preflight_copy
	# controlplane lists cinder-nfs on management.
	export SANDBOX_PROFILE_FILE=$SANDBOX_ROOT/profiles/controlplane.yaml
	run "$BATS_TEST_TMPDIR/scripts/preflight.sh" management
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "preflight: 0 failed, 0 warnings" ]
	[[ $output != *"command not found"* && $output != *"module nfs"* ]]
}

@test "scripts/preflight.sh fails a configuration without a switch of a service module" {
	preflight_copy
	for key in glance barbican horizon fake-compute cinder-backup; do
		config_with "del(.switches[\"$key\"])"
		run "$BATS_TEST_TMPDIR/scripts/preflight.sh" management
		[ "$status" -eq 1 ]
		[[ $output == *$'\n'"FAIL config: config: switches.$key is not set"$'\n'* ]]
	done
}

@test "a missing /dev/kvm only warns for compute and is not checked for management" {
	probe_kvm() { return 1; }
	run preflight_run compute
	[ "$status" -eq 0 ]
	[[ $output == *"warn kvm: /dev/kvm is missing, the compute pool falls back to virtType qemu"* ]]

	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output != *kvm* ]]
}

@test "a resolver that drops or changes the nip.io answer only warns" {
	probe_resolve() { :; }
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *"warn resolver: preflight.172-30-255-10.nip.io resolved to '', expected 172.30.255.10;"* ]]

	probe_resolve() { echo 10.0.0.1; }
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *"warn resolver: preflight.172-30-255-10.nip.io resolved to '10.0.0.1', expected 172.30.255.10;"* ]]
}

@test "the resolver warning names the switch, or that the fallback is on" {
	probe_resolve() { :; }
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"warn resolver: preflight.172-30-255-10.nip.io resolved to '', expected 172.30.255.10; a resolver with DNS rebinding protection drops private answers; set switches.resolver-fallback to true"$'\n'* ]]

	config_with '.switches["resolver-fallback"] = true'
	run preflight_run management
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"warn resolver: preflight.172-30-255-10.nip.io resolved to '', expected 172.30.255.10; a resolver with DNS rebinding protection drops private answers; the resolver fallback is on, make up prints the resolver settings"$'\n'* ]]
}

@test "every failed check prints its line and the summary counts them" {
	probe_os() { echo "Darwin arm64"; }
	probe_cgroup_fstype() { echo tmpfs; }
	run preflight_run management
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL os:"* && $output == *"FAIL cgroup:"* ]]
	[ "$(check_ids)" = "$COMMON_CHECKS" ]
	[ "${lines[-1]}" = "preflight: 2 failed, 0 warnings" ]
}

@test "scripts/preflight.sh rejects a word that is not a role" {
	run "$SANDBOX_ROOT/scripts/preflight.sh" network
	[ "$status" -eq 1 ]
	[ "$output" = "error: unknown cluster role 'network', expected management, storage or compute" ]
}
