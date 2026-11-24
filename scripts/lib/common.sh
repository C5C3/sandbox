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

# cluster_exists <role>: succeeds when kind lists the role's cluster.
cluster_exists() {
	local out
	out=$(kind get clusters 2>&1) || die "cannot list kind clusters: ${out%%$'\n'*}"
	grep -qxF -- "$(cluster_name "$1")" <<<"$out"
}

# network_exists <name>: succeeds when Docker has a network of that name.
network_exists() {
	local out
	out=$(docker network ls --format '{{.Name}}' 2>&1) || die "cannot list Docker networks: ${out%%$'\n'*}"
	grep -qxF -- "$1" <<<"$out"
}

# container_exists <name>: succeeds when Docker has a container of that name,
# running or not.
container_exists() {
	local out
	out=$(docker ps -a --format '{{.Names}}' 2>&1) || die "cannot list Docker containers: ${out%%$'\n'*}"
	grep -qxF -- "$1" <<<"$out"
}

# created_by_sandbox <network|container> <name>: succeeds when the existing
# object carries the label SANDBOX_LABEL.
created_by_sandbox() {
	local labels=.Labels value
	if [ "$1" = container ]; then
		labels=.Config.Labels
	fi
	value=$(docker "$1" inspect -f "{{index $labels \"${SANDBOX_LABEL%%=*}\"}}" "$2") ||
		die "cannot inspect Docker $1 $2"
	[ "$value" = "${SANDBOX_LABEL#*=}" ]
}

# cluster_on_sandbox_network <role>: returns 0 when a node of the role's
# cluster is attached to SANDBOX_NETWORK and 1 when none is. up.sh creates
# every cluster there, so a cluster of the same name with no node on it is not
# one of the sandbox. Any node counts, because an interrupted kind create or
# delete can leave the workers without the control-plane node. When kind
# cannot list the nodes or Docker cannot inspect one, it prints an error and
# returns 2, so a caller can record the error and go on.
cluster_on_sandbox_network() {
	local name out node networks
	name=$(cluster_name "$1")
	if ! out=$(kind get nodes --name "$name"); then
		printf 'error: cannot list the nodes of kind cluster %s\n' "$name" >&2
		return 2
	fi
	for node in $out; do
		if ! networks=$(docker container inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$node"); then
			printf 'error: cannot inspect Docker container %s\n' "$node" >&2
			return 2
		fi
		if [[ " $networks" == *" $SANDBOX_NETWORK "* ]]; then
			return 0
		fi
	done
	return 1
}

# prepare_kubeconfig_dir: creates the directory of the kubeconfig files, which
# hold cluster-admin credentials, with mode 700.
prepare_kubeconfig_dir() {
	mkdir -p -- "$SANDBOX_STATE_DIR/kubeconfig"
	chmod 700 -- "$SANDBOX_STATE_DIR/kubeconfig"
}

# restore_kubeconfig <role>: writes the kubeconfig file of an existing cluster
# when it is missing.
restore_kubeconfig() {
	local path
	path=$(kubeconfig_path "$1")
	if [ -f "$path" ]; then
		return 0
	fi
	prepare_kubeconfig_dir
	log "restoring $path"
	kind export kubeconfig --name "$(cluster_name "$1")" --kubeconfig "$path" ||
		die "kind could not export the kubeconfig of $(cluster_name "$1")"
	chmod 600 -- "$path"
}
