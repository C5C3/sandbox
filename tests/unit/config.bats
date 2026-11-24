#!/usr/bin/env bats
# config_load: the one configuration file of the sandbox.

setup() {
	load helpers
}

@test "config_load exports the values of the committed config.yaml" {
	config_load
	[ "$SANDBOX_SUBNET" = 172.30.0.0/16 ]
	[ "$SANDBOX_GATEWAY_ADDRESS" = 172.30.255.10 ]
	[ "$SANDBOX_REGISTRY_IMAGE" = registry:3 ]
	[ "$SANDBOX_HYPERVISOR_NODES" = 1 ]
	[ "$SANDBOX_FLUX_OPERATOR_VERSION" = 0.63.1 ]
	# The pin moves with upstream, so the test reads it.
	[ "$SANDBOX_UPSTREAM_COMMIT" = "$(yq '.upstream.cobaltcore' "$SANDBOX_ROOT/config.yaml")" ]
}

@test "config_load fails on a zero-length file at network.subnet" {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/empty.yaml
	: >"$SANDBOX_CONFIG"
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: network.subnet is not set" ]
}

@test "config_load fails for each key that is absent" {
	for key in network.subnet addresses.gateway registry.image switches.hypervisor-nodes flux.operator upstream.cobaltcore; do
		config_with "del(.${key%%.*}[\"${key#*.}\"])"
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: $key is not set" ]
	done
}

@test "config_load treats an empty registry image as not set" {
	config_with '.registry.image = ""'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: registry.image is not set" ]
}

@test "config_load fails when the file does not exist" {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/missing.yaml
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: $SANDBOX_CONFIG not found" ]
}

@test "config_load fails with the message of yq when the file is not YAML" {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/broken.yaml
	printf 'network: [\n' >"$SANDBOX_CONFIG"
	run config_load
	[ "$status" -eq 1 ]
	[[ $output == "error: config: $SANDBOX_CONFIG: "?* ]]
}

@test "config_load rejects a subnet that is not an IPv4 CIDR" {
	for subnet in 172.30.0.0 foo/16; do
		config_with ".network.subnet = \"$subnet\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: network.subnet '$subnet' is not an IPv4 CIDR" ]
	done
}

@test "config_load rejects a Gateway address that is not an IPv4 address" {
	config_with '.addresses.gateway = "172.30.255"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.gateway '172.30.255' is not an IPv4 address" ]
}

@test "config_load rejects a hypervisor node count below 1 or not an integer" {
	for nodes in 0 -1 1.5 '"two"'; do
		config_with ".switches[\"hypervisor-nodes\"] = $nodes"
		run config_load
		[ "$status" -eq 1 ]
		[[ $output == "error: config: switches.hypervisor-nodes must be an integer of 1 or more, got '"* ]]
	done
}

@test "config_load accepts two hypervisor nodes" {
	config_with '.switches["hypervisor-nodes"] = 2'
	config_load
	[ "$SANDBOX_HYPERVISOR_NODES" = 2 ]
}

@test "config_load rejects a flux-operator version that is not three numbers" {
	for operator in latest 0.63 v0.63.1; do
		config_with ".flux.operator = \"$operator\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: flux.operator '$operator' is not a version" ]
	done
}

@test "config_load treats an empty flux-operator version as not set" {
	config_with '.flux.operator = ""'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: flux.operator is not set" ]
}

@test "config_load treats an empty upstream commit as not set" {
	config_with '.upstream.cobaltcore = ""'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: upstream.cobaltcore is not set" ]
}

@test "config_load rejects an upstream commit that is not a full SHA in lower case" {
	for commit in 15a0323e 15A0323E243C7F53B91200F193A58B5B41D41F6A; do
		config_with ".upstream.cobaltcore = \"$commit\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: upstream.cobaltcore '$commit' is not a commit SHA of 40 hex characters" ]
	done
}
