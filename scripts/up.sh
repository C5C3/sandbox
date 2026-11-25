#!/usr/bin/env bash
# Usage: up.sh [<role>...]
#
# Loads the profile that SANDBOX_PROFILE names, checks the host and checks
# out vendor/cobaltcore at the pin of the configuration, then creates the
# Docker network, the registry and the kind clusters of the given roles, or
# of the profile's clusters when none is given. When the management cluster
# exists, it installs Flux there, pushes the working tree and has Flux apply
# the profile's modules to every cluster of the sandbox. With
# switches.resolver-fallback on, it then prints the host's resolver settings.
#
# Each step creates its object or checks that the existing one matches the
# configuration, so a second run continues where a failed one stopped. A
# mismatch is not repaired: the sandbox is rebuilt with make down.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$SANDBOX_ROOT/scripts/lib/preflight.sh"
# shellcheck source=lib/profile.sh
. "$SANDBOX_ROOT/scripts/lib/profile.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/vendor.sh
. "$SANDBOX_ROOT/scripts/lib/vendor.sh"

ensure_network() {
	local out subnet
	if ! network_exists "$SANDBOX_NETWORK"; then
		log "creating Docker network $SANDBOX_NETWORK with subnet $SANDBOX_SUBNET"
		out=$(docker network create --driver bridge --subnet "$SANDBOX_SUBNET" \
			--label "$SANDBOX_LABEL" "$SANDBOX_NETWORK" 2>&1) ||
			die "cannot create Docker network $SANDBOX_NETWORK with subnet $SANDBOX_SUBNET: ${out%%$'\n'*}; set network.subnet in the configuration to a range no other Docker network uses"
		return
	fi
	created_by_sandbox network "$SANDBOX_NETWORK" ||
		die "Docker network $SANDBOX_NETWORK exists and was not created by the sandbox"
	subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$SANDBOX_NETWORK")
	[ "$subnet" = "$SANDBOX_SUBNET" ] ||
		die "Docker network $SANDBOX_NETWORK has subnet $subnet, the configuration says $SANDBOX_SUBNET; run make down first"
	log "Docker network $SANDBOX_NETWORK exists"
}

ensure_registry() {
	local running image address i
	if ! container_exists "$SANDBOX_REGISTRY"; then
		log "creating container $SANDBOX_REGISTRY from $SANDBOX_REGISTRY_IMAGE"
		docker run -d --name "$SANDBOX_REGISTRY" --network "$SANDBOX_NETWORK" \
			--label "$SANDBOX_LABEL" "$SANDBOX_REGISTRY_IMAGE" >/dev/null ||
			die "cannot start container $SANDBOX_REGISTRY from $SANDBOX_REGISTRY_IMAGE"
	else
		created_by_sandbox container "$SANDBOX_REGISTRY" ||
			die "container $SANDBOX_REGISTRY exists and was not created by the sandbox"
		image=$(docker container inspect -f '{{.Config.Image}}' "$SANDBOX_REGISTRY")
		[ "$image" = "$SANDBOX_REGISTRY_IMAGE" ] ||
			die "container $SANDBOX_REGISTRY runs $image, the configuration says $SANDBOX_REGISTRY_IMAGE; run make down first"
		running=$(docker container inspect -f '{{.State.Running}}' "$SANDBOX_REGISTRY")
		[ "$running" = true ] ||
			die "container $SANDBOX_REGISTRY exists but is not running; run make down first"
		log "container $SANDBOX_REGISTRY exists"
	fi

	address=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$SANDBOX_NETWORK\").IPAddress}}" "$SANDBOX_REGISTRY")
	log "waiting for $SANDBOX_REGISTRY on $address:$SANDBOX_REGISTRY_PORT"
	for ((i = 1; i <= 30; i++)); do
		if timeout 2 bash -c '</dev/tcp/"$1"/"$2"' _ "$address" "$SANDBOX_REGISTRY_PORT" 2>/dev/null; then
			return
		fi
		sleep 1
	done
	die "registry $SANDBOX_REGISTRY does not answer on $address:$SANDBOX_REGISTRY_PORT from the host after 30 s; the host must reach the Docker network directly"
}

ensure_cluster() {
	local role=$1 name kubeconfig config out rc
	local -a nodes
	name=$(cluster_name "$role")
	kubeconfig=$(kubeconfig_path "$role")

	if ! cluster_exists "$role"; then
		prepare_kubeconfig_dir
		config=$(kind_config "$role")
		log "creating kind cluster $name"
		printf '%s\n' "$config" |
			KIND_EXPERIMENTAL_DOCKER_NETWORK=$SANDBOX_NETWORK kind create cluster \
				--name "$name" --config - --kubeconfig "$kubeconfig" --wait 5m ||
			die "kind could not create $name"
		chmod 600 -- "$kubeconfig"
	else
		rc=0
		cluster_on_sandbox_network "$role" || rc=$?
		# Status 2: the function printed why it cannot tell.
		[ "$rc" -ne 2 ] || exit 1
		[ "$rc" -eq 0 ] ||
			die "$name exists on another Docker network and was not created by the sandbox; remove or rename it"
		out=$(kind get nodes --name "$name") || die "cannot list the nodes of kind cluster $name"
		grep -qxF -- "$name-control-plane" <<<"$out" ||
			die "$name has no control-plane node; run make down first"
		if [ "$role" = compute ]; then
			mapfile -t nodes <<<"$out"
			[ $((${#nodes[@]} - 1)) -eq "$SANDBOX_HYPERVISOR_NODES" ] ||
				die "$name has $((${#nodes[@]} - 1)) worker nodes, the configuration says $SANDBOX_HYPERVISOR_NODES; run make down first"
		fi
		restore_kubeconfig "$role"
		log "kind cluster $name exists"
	fi

	log "waiting for the nodes of $name to be Ready"
	kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready nodes --all --timeout=300s >/dev/null ||
		die "nodes of $name are not Ready after 300 s"
}

profile_load
if [ "$#" -gt 0 ]; then
	require_roles "$@"
	for role in "$@"; do
		[[ " $SANDBOX_PROFILE_CLUSTERS " == *" $role "* ]] ||
			die "the profile $SANDBOX_PROFILE does not list the cluster $role"
	done
else
	read -ra roles <<<"$SANDBOX_PROFILE_CLUSTERS"
	set -- "${roles[@]}"
fi
preflight_run "$@" || die "host check failed, nothing was created"
config_load
# cluster_vars fails for a key of the configuration that cannot be a Flux
# variable or that becomes the same Flux variable as another key, so the run
# stops before anything is created.
cluster_vars >/dev/null
# The resolver switch adds the module resolver, whose stage on
# sandbox-management depends on the stage of loadbalancer; profile_load did
# not see the added module, so the stage would wait until its timeout.
modules=$(cluster_modules management) || exit 1
if [ "$SANDBOX_RESOLVER_FALLBACK" = true ] && ! grep -qxF loadbalancer <<<"$modules"; then
	die "switches.resolver-fallback needs the module loadbalancer on sandbox-management, the profile $SANDBOX_PROFILE does not list it"
fi
for role in "${SANDBOX_ROLES[@]}"; do
	if [[ " $SANDBOX_PROFILE_CLUSTERS " != *" $role "* ]] && sandbox_cluster "$role"; then
		die "$(cluster_name "$role") exists, the profile $SANDBOX_PROFILE does not list it; run make down first"
	fi
done
# A checkout with local changes at another commit stops the run here, before
# anything is created; so does a failed fetch.
ensure_vendor
ensure_network
ensure_registry
for role in "$@"; do
	ensure_cluster "$role"
done
attached=$(attached_roles)
if [[ " $attached " == *" management "* ]]; then
	hub_sync
	resolver_hint
else
	log "sandbox-management does not exist, Flux applies nothing until make up-management has run"
fi
for role in "$@"; do
	printf 'export KUBECONFIG=%s  # %s\n' "$(kubeconfig_path "$role")" "$(cluster_name "$role")"
done
