#!/usr/bin/env bats
# profile_load, profile_modules and config_merged: the profiles of the sandbox
# and their switches.

setup() {
	load helpers
}

# profile_fails_with <message>: profile_load exits 1 with the message.
profile_fails_with() {
	run profile_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: $1" ]
}

@test "without SANDBOX_PROFILE profile_load loads scaffold with the three clusters and the module test" {
	profile_load
	[ "$SANDBOX_PROFILE" = scaffold ]
	[ "$SANDBOX_PROFILE_FILE" = "$SANDBOX_ROOT/profiles/scaffold.yaml" ]
	[ "$SANDBOX_PROFILE_CLUSTERS" = "management storage compute" ]
	run profile_modules storage
	[ "$status" -eq 0 ]
	[ "$output" = test ]
}

@test "profile_load loads gateway with the five modules on management and none elsewhere" {
	export SANDBOX_PROFILE=gateway
	profile_load
	[ "$SANDBOX_PROFILE_CLUSTERS" = "management storage compute" ]
	[ "$(profile_modules management)" = $'crds\ncontrollers\nloadbalancer\npki\ngateway' ]
	[ "$(profile_modules storage)" = "" ]
	[ "$(profile_modules compute)" = "" ]
}

@test "profile_load loads platform with the management cluster alone and its nine modules" {
	export SANDBOX_PROFILE=platform
	profile_load
	[ "$SANDBOX_PROFILE_CLUSTERS" = management ]
	run cluster_modules management
	[ "$status" -eq 0 ]
	[ "$output" = $'crds\ncontrollers\nloadbalancer\npki\ngateway\nopenbao\nobjectstore\nplatform\nsizing' ]
}

@test "cluster_modules gives storage the module resolver of gateway only with the switch on" {
	export SANDBOX_PROFILE=gateway
	profile_load
	run cluster_modules storage
	[ "$status" -eq 0 ]
	[ "$output" = "" ]

	export SANDBOX_RESOLVER_FALLBACK=true
	run cluster_modules storage
	[ "$status" -eq 0 ]
	[ "$output" = resolver ]
}

@test "an empty SANDBOX_PROFILE loads scaffold" {
	export SANDBOX_PROFILE=
	profile_load
	[ "$SANDBOX_PROFILE" = scaffold ]
}

@test "a name that is not a profile name fails before any file is read" {
	yq() {
		echo "unit test called yq $*" >&2
		return 1
	}
	for name in ../x Scaffold -x 'a b'; do
		export SANDBOX_PROFILE=$name
		profile_fails_with "profile: '$name' is not a profile name"
	done
}

@test "a profile without a file fails with its path" {
	export SANDBOX_PROFILE=nothere
	profile_fails_with "profile: $SANDBOX_ROOT/profiles/nothere.yaml not found"
}

@test "a profile that is not YAML fails with the message of yq" {
	profile_with 'clusters: ['
	run profile_load
	[ "$status" -eq 1 ]
	[[ $output == "error: profile: $BATS_TEST_TMPDIR/profiles/case.yaml: "?* ]]
}

@test "a zero-length file, a file without clusters and an empty list fail at clusters" {
	profile_with ''
	: >"$BATS_TEST_TMPDIR/profiles/case.yaml"
	profile_fails_with "profile case: clusters is not set"

	for text in 'modules: {}' 'clusters: []' 'clusters:' 'clusters: management'; do
		profile_with "$text"
		profile_fails_with "profile case: clusters is not set"
	done
}

@test "a cluster that is not a role fails" {
	profile_with 'clusters: [management, network]'
	profile_fails_with "profile case: unknown cluster 'network', expected management, storage or compute"
}

@test "a profile without management fails" {
	profile_with 'clusters: [storage]'
	profile_fails_with "profile case: clusters must list management, Flux runs there"
}

@test "modules of a cluster the profile does not list fail" {
	profile_with $'clusters: [management]\nmodules:\n  compute: [test]'
	profile_fails_with "profile case: modules names the cluster 'compute', which clusters does not list"

	profile_with $'clusters: [management]\nmodules:\n  network: [test]'
	profile_fails_with "profile case: modules names the cluster 'network', which clusters does not list"
}

@test "modules, switches and a module list of another type fail" {
	profile_with $'clusters: [management]\nmodules: [test]'
	profile_fails_with "profile case: modules must be a map"

	profile_with $'clusters: [management]\nswitches: 2'
	profile_fails_with "profile case: switches must be a map"

	profile_with $'clusters: [management]\nmodules:\n  management: test'
	profile_fails_with "profile case: modules.management must be a list"
}

@test "a module listed twice for a cluster fails" {
	profile_with $'clusters: [management]\nmodules:\n  management: [test, test]'
	profile_fails_with "profile case: modules.management lists 'test' twice"
}

@test "a module that is not a module name fails" {
	profile_with $'clusters: [management]\nmodules:\n  management: [Bad_Name]'
	profile_fails_with "profile case: 'Bad_Name' is not a module name"
}

@test "a module without a stage fails with the path it expects" {
	profile_with $'clusters: [management]\nmodules:\n  management: [nothere]'
	profile_fails_with "profile case: module management/nothere does not exist, expected clusters/management/nothere/stage.yaml"
}

@test "the checks run over the whole file, so a bad name fails before a missing stage" {
	profile_with $'clusters: [management, storage]\nmodules:\n  management: [nothere]\n  storage: [Bad_Name]'
	profile_fails_with "profile case: 'Bad_Name' is not a module name"
}

@test "a stage whose dependency the profile does not list fails" {
	profile_with $'clusters: [management, storage]\nmodules:\n  storage: [test]'
	profile_fails_with "profile case: storage/test depends on the stage management-test, which the profile does not list"
}

@test "a dependency listed after the stage that needs it is found" {
	profile_with $'clusters: [compute, management]\nmodules:\n  compute: [test]\n  management: [test]'
	profile_load
	[ "$SANDBOX_PROFILE_CLUSTERS" = "management compute" ]
}

@test "a cluster listed twice is exported once, in the order of the roles" {
	profile_with 'clusters: [compute, management, compute, storage]'
	profile_load
	[ "$SANDBOX_PROFILE_CLUSTERS" = "management storage compute" ]
}

@test "a listed cluster without modules or with an empty list has no modules" {
	profile_with $'clusters: [management, storage, compute]\nmodules:\n  storage: []'
	profile_load
	for role in management storage compute; do
		run profile_modules "$role"
		[ "$status" -eq 0 ]
		[ "$output" = "" ]
	done

	profile_with $'clusters: [management]\nmodules:\n  management:'
	profile_load
	run profile_modules management
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "config_merged without a profile prints the configuration" {
	run config_merged
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '.' - <<<"$output")" = "$(yq -o=json -I=0 '.' "$SANDBOX_ROOT/config.yaml")" ]
}

@test "config_merged keeps the checks for a missing and an unparsable file" {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/missing.yaml
	run config_merged
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: $SANDBOX_CONFIG not found" ]

	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/broken.yaml
	printf 'network: [\n' >"$SANDBOX_CONFIG"
	profile_with 'clusters: [management]'
	profile_load
	run config_merged
	[ "$status" -eq 1 ]
	[[ $output == "error: config: $SANDBOX_CONFIG: "?* ]]
}

@test "the switches of a profile replace those of the configuration key by key" {
	profile_with $'clusters: [management]\nswitches:\n  hypervisor-nodes: 2\n  osd-count: 3'
	profile_load
	run config_merged
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '.switches' - <<<"$output")" = '{"hypervisor-nodes":2,"resolver-fallback":false,"osd-count":3}' ]
	[ "$(yq '.network.subnet' - <<<"$output")" = 172.30.0.0/16 ]

	config_load
	[ "$SANDBOX_HYPERVISOR_NODES" = 2 ]
}

@test "a profile without switches leaves the configuration's" {
	profile_load
	config_load
	[ "$SANDBOX_HYPERVISOR_NODES" = 1 ]

	profile_with $'clusters: [management]\nswitches:'
	profile_load
	config_load
	[ "$SANDBOX_HYPERVISOR_NODES" = 1 ]
}

@test "a switch of a profile adds switches to a configuration without them" {
	config_with 'del(.switches)'
	profile_with $'clusters: [management]\nswitches:\n  hypervisor-nodes: 3\n  resolver-fallback: true'
	profile_load
	config_load
	[ "$SANDBOX_HYPERVISOR_NODES" = 3 ]
	[ "$SANDBOX_RESOLVER_FALLBACK" = true ]
}

@test "an invalid switch of a profile fails with the message of config_load" {
	profile_with $'clusters: [management]\nswitches:\n  hypervisor-nodes: 0'
	profile_load
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: switches.hypervisor-nodes must be an integer of 1 or more, got '0'" ]
}

# modules_file <yaml>: writes the text as a profile into the test's directory
# and points SANDBOX_PROFILE_FILE at it, as profile_load would.
modules_file() {
	export SANDBOX_PROFILE_FILE=$BATS_TEST_TMPDIR/modules.yaml
	printf '%s\n' "$1" >"$SANDBOX_PROFILE_FILE"
}

@test "cluster_modules prints what profile_modules prints with the resolver switch off or unset" {
	local role
	modules_file $'clusters: [management, storage, compute]\nmodules:\n  management: [b, a]\n  storage: []'
	for value in unset false; do
		if [ "$value" = unset ]; then unset SANDBOX_RESOLVER_FALLBACK; else export SANDBOX_RESOLVER_FALLBACK=$value; fi
		for role in management storage compute; do
			[ "$(cluster_modules "$role")" = "$(profile_modules "$role")" ]
		done
	done
	[ "$(cluster_modules management)" = $'b\na' ]
}

@test "with the resolver switch on cluster_modules adds resolver once to every role" {
	export SANDBOX_RESOLVER_FALLBACK=true
	modules_file $'clusters: [management, storage, compute]\nmodules:\n  management: [b, a]\n  storage: []'
	run cluster_modules management
	[ "$status" -eq 0 ]
	[ "$output" = $'b\na\nresolver' ]
	for role in storage compute; do
		run cluster_modules "$role"
		[ "$status" -eq 0 ]
		[ "$output" = resolver ]
	done

	modules_file $'clusters: [management]\nmodules:\n  management: [resolver, a]'
	run cluster_modules management
	[ "$status" -eq 0 ]
	[ "$output" = $'resolver\na' ]
}

@test "cluster_modules prints nothing and fails when profile_modules fails" {
	local out rc=0
	export SANDBOX_RESOLVER_FALLBACK=true SANDBOX_PROFILE_FILE=$BATS_TEST_TMPDIR/missing.yaml
	# yq names the missing file on stderr; stdout stays empty.
	out=$(cluster_modules management 2>/dev/null) || rc=$?
	[ "$rc" -ne 0 ]
	[ "$out" = "" ]
}
