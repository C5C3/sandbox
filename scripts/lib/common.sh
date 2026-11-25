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
# The paths that flux leaves out of the artifact of the working tree, which
# push_artifact pushes and scripts/validate.sh renders.
SANDBOX_ARTIFACT_IGNORE=".git/,.sandbox/"
# The form of upstream.cobaltcore: a full commit SHA in lower case.
SANDBOX_SHA_RE='^[0-9a-f]{40}$'

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

# _first_line <text>, _last_line <text>: print the first or the last line of
# the text that holds more than spaces.
_first_line() { grep -m 1 '[^[:space:]]' <<<"$1" || :; }
_last_line() { grep '[^[:space:]]' <<<"$1" | tail -n 1 || :; }

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
# Every node mounts kind/containerd-nofile.conf as a drop-in of its containerd
# unit, which limits the open files of every pod to 1048576.
kind_config() {
	local role=$1 file workers='' i
	require_roles "$role"
	file=$SANDBOX_ROOT/kind/$role.yaml
	if [ "$role" = compute ]; then
		[ -n "${SANDBOX_HYPERVISOR_NODES:-}" ] ||
			die "kind_config: SANDBOX_HYPERVISOR_NODES is not set"
		[[ $SANDBOX_HYPERVISOR_NODES =~ ^[1-9][0-9]*$ ]] ||
			die "kind_config: SANDBOX_HYPERVISOR_NODES must be an integer of 1 or more, got '$SANDBOX_HYPERVISOR_NODES'"
		for ((i = 0; i < SANDBOX_HYPERVISOR_NODES; i++)); do
			workers+=${workers:+, }'{"role": "worker"}'
		done
	fi
	DROPIN=$SANDBOX_ROOT/kind/containerd-nofile.conf yq ".nodes += [$workers] | .nodes[].extraMounts += [{
		\"hostPath\": strenv(DROPIN),
		\"containerPath\": \"/etc/systemd/system/containerd.service.d/sandbox-nofile.conf\",
		\"readOnly\": true}]" "$file"
}

# config_merged: prints the configuration file that SANDBOX_CONFIG names, by
# default config.yaml in the repository root. When SANDBOX_PROFILE_FILE names
# a profile with switches, each of them replaces the key of the same name
# under switches.
config_merged() {
	local path=${SANDBOX_CONFIG:-$SANDBOX_ROOT/config.yaml} out

	[ -f "$path" ] || die "config: $path not found"
	if ! out=$(yq '.' "$path" 2>&1); then
		out=${out%%$'\n'*}
		die "config: $path: ${out#Error: }"
	fi
	if [ -n "${SANDBOX_PROFILE_FILE:-}" ] && [ "$(yq '.switches | tag' "$SANDBOX_PROFILE_FILE")" = '!!map' ]; then
		# + of two maps replaces the keys of the left one with those of the
		# right one, key by key.
		out=$(yq '.switches = ((.switches // {}) + load(strenv(SANDBOX_PROFILE_FILE)).switches)' "$path") ||
			die "config: cannot apply the switches of $SANDBOX_PROFILE_FILE"
	fi
	printf '%s\n' "$out"
}

# _cidr_range <address or cidr>: prints the first and the last address of the
# range as integers; an address is a range of one. It fails for anything but
# four decimal octets of 0 to 255 with an optional prefix length of 0 to 32,
# written without a leading zero: MetalLB and Docker refuse 172.30.255.010,
# and one address must have one spelling for the comparisons of config_load.
_cidr_range() {
	local n='(0|[1-9][0-9]{0,2})' octet first=0 prefix=32 size
	[[ $1 =~ ^$n\.$n\.$n\.$n(/(0|[1-9][0-9]?))?$ ]] || return 1
	if [ -n "${BASH_REMATCH[6]}" ]; then
		prefix=${BASH_REMATCH[6]}
	fi
	((prefix <= 32)) || return 1
	for octet in "${BASH_REMATCH[@]:1:4}"; do
		((octet <= 255)) || return 1
		first=$((first * 256 + octet))
	done
	size=$((1 << (32 - prefix)))
	first=$((first / size * size))
	printf '%s %s\n' "$first" "$((first + size - 1))"
}

# _cidr_contains <cidr> <address or cidr>: succeeds when every address of the
# second argument lies inside the first, compared as integers.
_cidr_contains() {
	local outer inner
	outer=$(_cidr_range "$1") && inner=$(_cidr_range "$2") || return 1
	((${inner% *} >= ${outer% *} && ${inner#* } <= ${outer#* }))
}

# config_load: reads the output of config_merged and exports SANDBOX_SUBNET,
# SANDBOX_GATEWAY_ADDRESS, SANDBOX_ADDRESS_POOL, SANDBOX_DNS_ADDRESS,
# SANDBOX_RABBITMQ_ADDRESS, SANDBOX_REGISTRY_IMAGE, SANDBOX_HYPERVISOR_NODES,
# SANDBOX_RESOLVER_FALLBACK, SANDBOX_FLUX_OPERATOR_VERSION and
# SANDBOX_UPSTREAM_COMMIT. A missing key is an error; no script carries a
# default for these ten. The pool lies inside the subnet, and the Gateway,
# DNS and RabbitMQ addresses, three different ones, inside the pool: MetalLB
# gives a Service no address outside its pool.
config_load() {
	local merged key value subnet gateway pool dns rabbitmq nodes fallback operator upstream
	local -A values=()

	merged=$(config_merged) || exit 1
	for key in network.subnet addresses.gateway registry.image switches.hypervisor-nodes flux.operator upstream.cobaltcore \
		addresses.pool addresses.dns addresses.rabbitmq; do
		# The bracket form reads a key with a hyphen, such as hypervisor-nodes.
		value=$(yq ".${key%%.*}[\"${key#*.}\"] // \"\"" - <<<"$merged")
		[ -n "$value" ] || die "config: $key is not set"
		values[$key]=$value
	done
	# Read outside the loop: its // "" would turn the value false into the
	# empty string.
	fallback=$(yq '.switches["resolver-fallback"] | select(. != null)' - <<<"$merged")
	[ -n "$fallback" ] || die "config: switches.resolver-fallback is not set"
	subnet=${values[network.subnet]} gateway=${values[addresses.gateway]} nodes=${values[switches.hypervisor-nodes]}
	operator=${values[flux.operator]} upstream=${values[upstream.cobaltcore]}
	pool=${values[addresses.pool]} dns=${values[addresses.dns]} rabbitmq=${values[addresses.rabbitmq]}

	[[ $subnet == */* ]] && _cidr_range "$subnet" >/dev/null ||
		die "config: network.subnet '$subnet' is not an IPv4 CIDR"
	[[ $gateway != */* ]] && _cidr_range "$gateway" >/dev/null ||
		die "config: addresses.gateway '$gateway' is not an IPv4 address"
	[[ $nodes =~ ^[1-9][0-9]*$ ]] ||
		die "config: switches.hypervisor-nodes must be an integer of 1 or more, got '$nodes'"
	[[ $operator =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
		die "config: flux.operator '$operator' is not a version"
	[[ $upstream =~ $SANDBOX_SHA_RE ]] ||
		die "config: upstream.cobaltcore '$upstream' is not a commit SHA of 40 hex characters"
	[[ $pool == */* ]] && _cidr_range "$pool" >/dev/null ||
		die "config: addresses.pool '$pool' is not an IPv4 CIDR"
	[[ $dns != */* ]] && _cidr_range "$dns" >/dev/null ||
		die "config: addresses.dns '$dns' is not an IPv4 address"
	[[ $rabbitmq != */* ]] && _cidr_range "$rabbitmq" >/dev/null ||
		die "config: addresses.rabbitmq '$rabbitmq' is not an IPv4 address"
	[[ $fallback == true || $fallback == false ]] ||
		die "config: switches.resolver-fallback must be true or false, got '$fallback'"
	_cidr_contains "$subnet" "$pool" ||
		die "config: addresses.pool $pool is not inside network.subnet $subnet"
	_cidr_contains "$pool" "$gateway" ||
		die "config: addresses.gateway $gateway is not inside addresses.pool $pool"
	_cidr_contains "$pool" "$dns" ||
		die "config: addresses.dns $dns is not inside addresses.pool $pool"
	[ "$dns" != "$gateway" ] ||
		die "config: addresses.dns and addresses.gateway are both $dns"
	_cidr_contains "$pool" "$rabbitmq" ||
		die "config: addresses.rabbitmq $rabbitmq is not inside addresses.pool $pool"
	[ "$rabbitmq" != "$gateway" ] ||
		die "config: addresses.rabbitmq and addresses.gateway are both $rabbitmq"
	[ "$rabbitmq" != "$dns" ] ||
		die "config: addresses.rabbitmq and addresses.dns are both $rabbitmq"

	export SANDBOX_SUBNET=$subnet
	export SANDBOX_GATEWAY_ADDRESS=$gateway
	export SANDBOX_ADDRESS_POOL=$pool
	export SANDBOX_DNS_ADDRESS=$dns
	export SANDBOX_RABBITMQ_ADDRESS=$rabbitmq
	export SANDBOX_REGISTRY_IMAGE=${values[registry.image]}
	export SANDBOX_HYPERVISOR_NODES=$nodes
	export SANDBOX_RESOLVER_FALLBACK=$fallback
	export SANDBOX_FLUX_OPERATOR_VERSION=$operator
	export SANDBOX_UPSTREAM_COMMIT=$upstream
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
