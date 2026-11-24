#!/usr/bin/env bats
# kind_config: the kind configuration of each cluster.

setup() {
	load helpers
}

# node_roles: prints the roles of the nodes in $output, comma-separated.
node_roles() {
	yq '[.nodes[].role] | join(",")' - <<<"$output"
}

@test "kind_config gives management and storage one control-plane node with the API server on 127.0.0.1" {
	for role in management storage; do
		run kind_config "$role"
		[ "$status" -eq 0 ]
		[ "$(node_roles)" = control-plane ]
		[ "$(yq '.networking.apiServerAddress' - <<<"$output")" = 127.0.0.1 ]
		[[ $output != *extraPortMappings* ]]
	done
}

@test "kind_config adds one worker to compute for one hypervisor node" {
	export SANDBOX_HYPERVISOR_NODES=1
	run kind_config compute
	[ "$status" -eq 0 ]
	[ "$(node_roles)" = control-plane,worker ]
	[ "$(yq '.networking.apiServerAddress' - <<<"$output")" = 127.0.0.1 ]
}

@test "kind_config adds three workers to compute for three hypervisor nodes" {
	export SANDBOX_HYPERVISOR_NODES=3
	run kind_config compute
	[ "$status" -eq 0 ]
	[ "$(node_roles)" = control-plane,worker,worker,worker ]
}

@test "kind_config compute fails when SANDBOX_HYPERVISOR_NODES is unset or empty" {
	run kind_config compute
	[ "$status" -eq 1 ]
	[ "$output" = "error: kind_config: SANDBOX_HYPERVISOR_NODES is not set" ]

	export SANDBOX_HYPERVISOR_NODES=
	run kind_config compute
	[ "$status" -eq 1 ]
	[ "$output" = "error: kind_config: SANDBOX_HYPERVISOR_NODES is not set" ]
}

@test "kind_config compute fails when SANDBOX_HYPERVISOR_NODES is not a positive integer" {
	export SANDBOX_HYPERVISOR_NODES=two
	run kind_config compute
	[ "$status" -eq 1 ]
	[ "$output" = "error: kind_config: SANDBOX_HYPERVISOR_NODES must be an integer of 1 or more, got 'two'" ]
}

@test "kind_config fails for a word that is not a role" {
	run kind_config network
	[ "$status" -eq 1 ]
	[ "$output" = "error: unknown cluster role 'network', expected management, storage or compute" ]
}
