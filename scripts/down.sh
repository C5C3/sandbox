#!/usr/bin/env bash
# Usage: down.sh
#
# Removes every object of the sandbox and checks that nothing is left. It
# reads no configuration and runs no host check, so it also works on a host
# and with a configuration that up.sh refuses. Objects of the same name that
# do not carry the label of the sandbox, and kind clusters on another Docker
# network, stay in place.
#
# The order of the steps is part of the interface. A step that removes host
# state from inside a node goes before step 1, while the node still exists.
# Each step skips what is absent; a step that fails is recorded on stderr and
# the following steps still run.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# record <message>: reports a failed step and lets the next one run.
record() {
	printf 'error: %s\n' "$*" >&2
}

# nodes_stopped <cluster>: waits until no node container of the kind cluster
# runs, polling every 2 s for at most 120 s, and fails when one still runs
# then.
nodes_stopped() {
	local i node nodes running
	log "waiting up to 120 s for the nodes of $1 to stop"
	for ((i = 0; ; i++)); do
		running=''
		nodes=$(kind get nodes --name "$1" 2>/dev/null) || nodes=''
		for node in $nodes; do
			if [ "$(docker container inspect -f '{{.State.Running}}' "$node" 2>/dev/null)" = true ]; then
				running=$node
			fi
		done
		[ -n "$running" ] || return 0
		[ "$i" -lt 60 ] || return 1
		sleep 2
	done
}

out=$(docker info 2>&1 >/dev/null) || die "cannot reach the Docker daemon: ${out%%$'\n'*}"

# 1. The kind clusters. --kubeconfig keeps kind from editing ~/.kube/config.
# Docker gives a node 12 s to exit after it kills it. A node can take longer:
# one that mounts an NFS export served from a pod of its own cluster, as with
# the module cinder-nfs, waits for the kernel's NFS client, whose server
# stopped with the node, and on a busy host any node may. kind then fails and
# leaves the node, which Docker goes on stopping, so the cluster is deleted
# once more after its nodes stopped.
for role in compute storage management; do
	if cluster_exists "$role"; then
		name=$(cluster_name "$role")
		rc=0
		cluster_on_sandbox_network "$role" || rc=$?
		if [ "$rc" -eq 2 ]; then
			record "cannot check the Docker network of kind cluster $name"
			continue
		elif [ "$rc" -ne 0 ]; then
			record "kind cluster $name is not on Docker network $SANDBOX_NETWORK and was not created by the sandbox"
			continue
		fi
		prepare_kubeconfig_dir
		log "deleting kind cluster $name"
		if ! kind delete cluster --name "$name" --kubeconfig "$(kubeconfig_path "$role")"; then
			if nodes_stopped "$name"; then
				log "deleting kind cluster $name again"
				kind delete cluster --name "$name" --kubeconfig "$(kubeconfig_path "$role")" ||
					record "kind could not delete $name"
			else
				record "kind could not delete $name, a node still runs after 120 s"
			fi
		fi
	fi
done

# 2. The registry, with its anonymous volume.
if container_exists "$SANDBOX_REGISTRY"; then
	if created_by_sandbox container "$SANDBOX_REGISTRY"; then
		log "removing container $SANDBOX_REGISTRY"
		docker rm -f -v "$SANDBOX_REGISTRY" >/dev/null ||
			record "cannot remove container $SANDBOX_REGISTRY"
	else
		record "container $SANDBOX_REGISTRY was not created by the sandbox"
	fi
fi

# 3. The Docker network.
if network_exists "$SANDBOX_NETWORK"; then
	if created_by_sandbox network "$SANDBOX_NETWORK"; then
		log "removing Docker network $SANDBOX_NETWORK"
		if ! out=$(docker network rm "$SANDBOX_NETWORK" 2>&1); then
			attached=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$SANDBOX_NETWORK") || attached=
			if [ -n "$attached" ]; then
				record "cannot remove Docker network $SANDBOX_NETWORK, containers still attached: ${attached% }"
			else
				record "cannot remove Docker network $SANDBOX_NETWORK: ${out%%$'\n'*}"
			fi
		fi
	else
		record "Docker network $SANDBOX_NETWORK was not created by the sandbox"
	fi
fi

# 4. The state directory with the kubeconfig files.
if [ -e "$SANDBOX_STATE_DIR" ]; then
	log "removing $SANDBOX_STATE_DIR"
	rm -rf -- "${SANDBOX_STATE_DIR:?}" || record "cannot remove $SANDBOX_STATE_DIR"
fi

# 5. The check.
left=()
for role in "${SANDBOX_ROLES[@]}"; do
	if cluster_exists "$role"; then
		left+=("kind cluster $(cluster_name "$role")")
	fi
done
if container_exists "$SANDBOX_REGISTRY"; then
	left+=("container $SANDBOX_REGISTRY")
fi
if network_exists "$SANDBOX_NETWORK"; then
	left+=("Docker network $SANDBOX_NETWORK")
fi
if [ -e "$SANDBOX_STATE_DIR" ]; then
	left+=("directory $SANDBOX_STATE_DIR")
fi
if [ "${#left[@]}" -eq 0 ]; then
	log "nothing left"
	exit 0
fi
for item in "${left[@]}"; do
	printf 'error: left over: %s\n' "$item" >&2
done
exit 1
