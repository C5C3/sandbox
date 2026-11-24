# shellcheck shell=bash
# Constants and helpers that every script of the sandbox shares.
#
# Sourcing this file defines them and runs nothing else. It sets no shell
# option, so a test can source it; the entry scripts set -euo pipefail.

SANDBOX_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX_NETWORK=cobaltcore-sandbox
SANDBOX_REGISTRY=sandbox-registry
SANDBOX_REGISTRY_PORT=5000
SANDBOX_LABEL=cobaltcore-sandbox=true
SANDBOX_ROLES=(management storage compute)
SANDBOX_STATE_DIR=$SANDBOX_ROOT/.sandbox

# log <message>: prints one step, prefixed with the name of the script.
log() {
	local name=${0##*/}
	printf '%s: %s\n' "${name%.sh}" "$*"
}

# die <message>: prints the message to stderr and exits 1.
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# require_roles <word>...: fails for the first word that is not a role.
require_roles() {
	local word
	for word in "$@"; do
		case $word in
		management | storage | compute) ;;
		*) die "unknown cluster role '$word', expected management, storage or compute" ;;
		esac
	done
}

# cluster_name <role>: prints the name of the kind cluster of the role.
cluster_name() {
	printf 'sandbox-%s\n' "$1"
}

# kubeconfig_path <role>: prints the kubeconfig file of the role's cluster.
kubeconfig_path() {
	printf '%s/kubeconfig/%s.yaml\n' "$SANDBOX_STATE_DIR" "$1"
}

# kind_config <role>: prints the kind configuration of the role. For compute
# it adds SANDBOX_HYPERVISOR_NODES worker nodes to the control-plane node.
kind_config() {
	local role=$1 file workers='' i
	require_roles "$role"
	file=$SANDBOX_ROOT/kind/$role.yaml
	if [ "$role" != compute ]; then
		cat -- "$file"
		return
	fi
	[ -n "${SANDBOX_HYPERVISOR_NODES:-}" ] ||
		die "kind_config: SANDBOX_HYPERVISOR_NODES is not set"
	[[ $SANDBOX_HYPERVISOR_NODES =~ ^[1-9][0-9]*$ ]] ||
		die "kind_config: SANDBOX_HYPERVISOR_NODES must be an integer of 1 or more, got '$SANDBOX_HYPERVISOR_NODES'"
	for ((i = 0; i < SANDBOX_HYPERVISOR_NODES; i++)); do
		workers+=${workers:+, }'{"role": "worker"}'
	done
	yq ".nodes += [$workers]" "$file"
}

# config_load: reads the configuration file that SANDBOX_CONFIG names, by
# default config.yaml in the repository root, and exports SANDBOX_SUBNET,
# SANDBOX_GATEWAY_ADDRESS, SANDBOX_REGISTRY_IMAGE and SANDBOX_HYPERVISOR_NODES.
# A missing key is an error; no script carries a default for these four.
config_load() {
	local path=${SANDBOX_CONFIG:-$SANDBOX_ROOT/config.yaml}
	local key value subnet gateway nodes
	local -A values=()

	[ -f "$path" ] || die "config: $path not found"
	for key in network.subnet addresses.gateway registry.image switches.hypervisor-nodes; do
		# The bracket form reads a key with a hyphen, such as hypervisor-nodes.
		if ! value=$(yq ".${key%%.*}[\"${key#*.}\"] // \"\"" "$path" 2>&1); then
			value=${value%%$'\n'*}
			die "config: $path: ${value#Error: }"
		fi
		[ -n "$value" ] || die "config: $key is not set"
		values[$key]=$value
	done
	subnet=${values[network.subnet]} gateway=${values[addresses.gateway]} nodes=${values[switches.hypervisor-nodes]}

	[[ $subnet =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
		die "config: network.subnet '$subnet' is not an IPv4 CIDR"
	[[ $gateway =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
		die "config: addresses.gateway '$gateway' is not an IPv4 address"
	[[ $nodes =~ ^[1-9][0-9]*$ ]] ||
		die "config: switches.hypervisor-nodes must be an integer of 1 or more, got '$nodes'"

	export SANDBOX_SUBNET=$subnet
	export SANDBOX_GATEWAY_ADDRESS=$gateway
	export SANDBOX_REGISTRY_IMAGE=${values[registry.image]}
	export SANDBOX_HYPERVISOR_NODES=$nodes
}
