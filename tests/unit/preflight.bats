#!/usr/bin/env bats
# preflight_run: the host check, on a simulated host.

setup() {
	load helpers
	healthy_host
}

COMMON_CHECKS="os,cgroup,docker,inotify,tool docker,tool kind,tool kubectl,tool jq,tool helm,tool flux,tool yq,tool openstack,plugin osc-placement,plugin python-barbicanclient,config,resolver"

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
	for missing in docker kind kubectl jq helm flux yq; do
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
