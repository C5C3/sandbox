#!/usr/bin/env bats
# config_load: the one configuration file of the sandbox.

setup() {
	load helpers
}

@test "config_load exports the values of the committed config.yaml" {
	config_load
	[ "$SANDBOX_SUBNET" = 172.30.0.0/16 ]
	[ "$SANDBOX_GATEWAY_ADDRESS" = 172.30.255.10 ]
	[ "$SANDBOX_ADDRESS_POOL" = 172.30.255.0/24 ]
	[ "$SANDBOX_DNS_ADDRESS" = 172.30.255.53 ]
	[ "$SANDBOX_RABBITMQ_ADDRESS" = 172.30.255.11 ]
	[ "$SANDBOX_OPENBAO_ADDRESS" = 172.30.255.12 ]
	[ "$SANDBOX_REGISTRY_IMAGE" = registry:3 ]
	[ "$SANDBOX_HYPERVISOR_NODES" = 1 ]
	[ "$SANDBOX_RESOLVER_FALLBACK" = false ]
	[ "$SANDBOX_SWITCH_GLANCE" = false ]
	[ "$SANDBOX_SWITCH_BARBICAN" = false ]
	[ "$SANDBOX_SWITCH_HORIZON" = false ]
	[ "$SANDBOX_SWITCH_FAKE_COMPUTE" = false ]
	[ "$SANDBOX_SWITCH_CINDER_BACKUP" = false ]
	[ "$SANDBOX_OSD_COUNT" = 1 ]
	[ "$SANDBOX_OSD_SIZE" = 10Gi ]
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
	for key in network.subnet addresses.gateway registry.image switches.hypervisor-nodes flux.operator upstream.cobaltcore \
		addresses.pool addresses.dns addresses.rabbitmq addresses.openbao switches.resolver-fallback \
		switches.glance switches.barbican switches.horizon switches.fake-compute switches.cinder-backup switches.osd-count \
		switches.osd-size; do
		config_with "del(.${key%%.*}[\"${key#*.}\"])"
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: $key is not set" ]
	done
}

@test "config_load treats an empty OSD count or size as not set" {
	for key in osd-count osd-size; do
		config_with ".switches[\"$key\"] = \"\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: switches.$key is not set" ]
	done
}

@test "config_load rejects an OSD count below 1 or not an integer" {
	for osds in 0 -1 1.5 '"three"'; do
		config_with ".switches[\"osd-count\"] = $osds"
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: switches.osd-count must be an integer of 1 or more, got '${osds//\"/}'" ]
	done
}

@test "config_load rejects an OSD size that is not a whole number of Gi" {
	for size in 10 10G 0Gi 1.5Gi 500Mi; do
		config_with ".switches[\"osd-size\"] = \"$size\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: switches.osd-size must be a whole number of Gi such as 10Gi, got '$size'" ]
	done
}

@test "config_load accepts three OSDs of 20Gi" {
	config_with '.switches["osd-count"] = 3 | .switches["osd-size"] = "20Gi"'
	config_load
	[ "$SANDBOX_OSD_COUNT" = 3 ]
	[ "$SANDBOX_OSD_SIZE" = 20Gi ]
}

@test "config_load treats a null pool, DNS address, RabbitMQ address, OpenBao address or switch as not set" {
	for key in addresses.pool addresses.dns addresses.rabbitmq addresses.openbao switches.resolver-fallback \
		switches.glance switches.barbican switches.horizon switches.fake-compute switches.cinder-backup; do
		config_with ".${key%%.*}[\"${key#*.}\"] = null"
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: $key is not set" ]
	done
}

@test "config_load reads false and true as values of the resolver switch" {
	for value in false true; do
		config_with ".switches[\"resolver-fallback\"] = $value"
		config_load
		[ "$SANDBOX_RESOLVER_FALLBACK" = "$value" ]
	done
}

@test "config_load rejects a resolver switch that is neither true nor false" {
	config_with '.switches["resolver-fallback"] = "maybe"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: switches.resolver-fallback must be true or false, got 'maybe'" ]
}

@test "config_load treats an empty switch of a service module as not set" {
	for key in glance barbican horizon fake-compute cinder-backup; do
		config_with ".switches[\"$key\"] = \"\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: switches.$key is not set" ]
	done
}

@test "config_load reads false and true as values of the switches of the service modules" {
	local key variable value
	for key in glance barbican horizon fake-compute cinder-backup; do
		variable=SANDBOX_SWITCH_${key^^}
		variable=${variable//-/_}
		for value in true false; do
			config_with ".switches[\"$key\"] = $value"
			config_load
			[ "${!variable}" = "$value" ]
		done
	done
}

@test "config_load rejects a switch of a service module that is neither true nor false" {
	for key in glance barbican horizon fake-compute cinder-backup; do
		config_with ".switches[\"$key\"] = \"yes\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: switches.$key must be true or false, got 'yes'" ]
	done
}

@test "config_load checks that the switches are set before it checks their values" {
	config_with '.switches.glance = "yes" | del(.switches["fake-compute"])'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: switches.fake-compute is not set" ]

	config_with '.switches["resolver-fallback"] = "maybe" | .switches.horizon = "yes"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: switches.resolver-fallback must be true or false, got 'maybe'" ]
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
	for subnet in 172.30.0.0 foo/16 172.30.0.0/33 172.300.0.0/16 172.030.0.0/16; do
		config_with ".network.subnet = \"$subnet\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: network.subnet '$subnet' is not an IPv4 CIDR" ]
	done
}

@test "config_load rejects a Gateway address that is not an IPv4 address" {
	for gateway in 172.30.255 172.30.255.256 172.30.255.10/32 172.30.255.010; do
		config_with ".addresses.gateway = \"$gateway\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.gateway '$gateway' is not an IPv4 address" ]
	done
}

@test "config_load rejects a pool that is not an IPv4 CIDR" {
	for pool in 172.30.255.0 172.30.256.0/24 172.30.255.0/33 172.30.255.000/24 172.30.255.0/024; do
		config_with ".addresses.pool = \"$pool\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.pool '$pool' is not an IPv4 CIDR" ]
	done
}

@test "config_load rejects a DNS address that is not an IPv4 address" {
	for dns in 172.30.255 172.30.255.300 172.30.255.53/32 172.30.255.053; do
		config_with ".addresses.dns = \"$dns\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.dns '$dns' is not an IPv4 address" ]
	done
}

@test "config_load rejects a pool outside the subnet" {
	config_with '.addresses.pool = "172.31.255.0/24"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.pool 172.31.255.0/24 is not inside network.subnet 172.30.0.0/16" ]
}

@test "config_load rejects a Gateway or DNS address outside the pool" {
	config_with '.addresses.gateway = "172.30.254.10"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.gateway 172.30.254.10 is not inside addresses.pool 172.30.255.0/24" ]

	config_with '.addresses.dns = "172.30.254.53"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.dns 172.30.254.53 is not inside addresses.pool 172.30.255.0/24" ]
}

@test "config_load rejects one address for the DNS fallback and the Gateway" {
	config_with '.addresses.dns = "172.30.255.10"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.dns and addresses.gateway are both 172.30.255.10" ]
}

@test "config_load treats an empty RabbitMQ address as not set" {
	config_with '.addresses.rabbitmq = ""'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.rabbitmq is not set" ]
}

@test "config_load rejects a RabbitMQ address that is not an IPv4 address" {
	for rabbitmq in 172.30.255 172.30.255.256 172.30.255.11/32 172.30.255.011; do
		config_with ".addresses.rabbitmq = \"$rabbitmq\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.rabbitmq '$rabbitmq' is not an IPv4 address" ]
	done
}

@test "config_load rejects a RabbitMQ address outside the pool" {
	config_with '.addresses.rabbitmq = "172.30.254.11"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.rabbitmq 172.30.254.11 is not inside addresses.pool 172.30.255.0/24" ]
}

@test "config_load rejects a RabbitMQ address that is the Gateway or the DNS address" {
	config_with '.addresses.rabbitmq = "172.30.255.10"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.rabbitmq and addresses.gateway are both 172.30.255.10" ]

	config_with '.addresses.rabbitmq = "172.30.255.53"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.rabbitmq and addresses.dns are both 172.30.255.53" ]
}

@test "config_load treats an empty OpenBao address as not set" {
	config_with '.addresses.openbao = ""'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.openbao is not set" ]
}

@test "config_load rejects an OpenBao address that is not an IPv4 address" {
	for openbao in 172.30.255 172.30.255.256 172.30.255.12/32 172.30.255.012; do
		config_with ".addresses.openbao = \"$openbao\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.openbao '$openbao' is not an IPv4 address" ]
	done
}

@test "config_load rejects an OpenBao address outside the pool" {
	config_with '.addresses.openbao = "172.30.254.12"'
	run config_load
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: addresses.openbao 172.30.254.12 is not inside addresses.pool 172.30.255.0/24" ]
}

@test "config_load rejects an OpenBao address that is the Gateway, the DNS or the RabbitMQ address" {
	local key value
	while read -r key value; do
		config_with ".addresses.openbao = \"$value\""
		run config_load
		[ "$status" -eq 1 ]
		[ "$output" = "error: config: addresses.openbao and addresses.$key are both $value" ]
	done <<'EOF'
gateway 172.30.255.10
dns 172.30.255.53
rabbitmq 172.30.255.11
EOF
}

@test "config_load accepts a pool that is the whole subnet" {
	config_with '.addresses.pool = "172.30.0.0/16"'
	config_load
	[ "$SANDBOX_ADDRESS_POOL" = 172.30.0.0/16 ]
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
