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
# state from inside a node goes before the deletion of the clusters, while
# the node still exists, as step 1 does. Each step skips what is absent; a
# step that fails is recorded on stderr and the following steps still run.
# The check at the end reads the loop devices of the host from
# SANDBOX_SYS_BLOCK, by default /sys/block.
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

# 1. The loop devices of the storage node. kubelet holds each block volume
# through a loop device of its own over the OSD's device, so its devices are
# detached first. A device an OSD still holds is detached by the kernel when
# the node stops; a device of a node that no longer runs needs root on the
# host, and the check reports it. cluster_on_sandbox_network reports what it
# cannot tell in step 2.
node=$(cluster_name storage)-control-plane
if cluster_exists storage && cluster_on_sandbox_network storage 2>/dev/null &&
	[ "$(docker container inspect -f '{{.State.Running}}' "$node" 2>/dev/null)" = true ]; then
	if list=$(docker exec "$node" losetup --list --noheadings --output NAME,BACK-FILE 2>&1); then
		devices=()
		while read -r device file; do
			if [[ $file == *"/volumeDevices/$SANDBOX_OSD_VOLUME-"* ]]; then
				devices+=("$device")
			fi
		done <<<"$list"
		while read -r device file; do
			if [[ $file == "$SANDBOX_OSD_DIR/osd-"* ]]; then
				devices+=("$device")
			fi
		done <<<"$list"
		if [ "${#devices[@]}" -gt 0 ]; then
			log "detaching ${#devices[@]} loop devices of $(cluster_name storage)"
		fi
		for device in "${devices[@]}"; do
			out=$(docker exec "$node" losetup -d "$device" 2>&1) ||
				record "cannot detach the loop device $device of $node: $(_last_line "$out")"
		done
	else
		record "cannot list the loop devices of $node: $(_last_line "$list")"
	fi
fi

# 2. The kind clusters. --kubeconfig keeps kind from editing ~/.kube/config.
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

# 3. The registry, with its anonymous volume.
if container_exists "$SANDBOX_REGISTRY"; then
	if created_by_sandbox container "$SANDBOX_REGISTRY"; then
		log "removing container $SANDBOX_REGISTRY"
		docker rm -f -v "$SANDBOX_REGISTRY" >/dev/null ||
			record "cannot remove container $SANDBOX_REGISTRY"
	else
		record "container $SANDBOX_REGISTRY was not created by the sandbox"
	fi
fi

# 4. The Docker network.
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

# 5. The state directory with the kubeconfig files.
if [ -e "$SANDBOX_STATE_DIR" ]; then
	log "removing $SANDBOX_STATE_DIR"
	rm -rf -- "${SANDBOX_STATE_DIR:?}" || record "cannot remove $SANDBOX_STATE_DIR"
fi

# 6. The check. A loop device whose backing file is an OSD file or
# kubelet's path of an OSD volume is what a storage node deleted or stopped
# outside make down leaves, and make down runs no sudo.
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
for path in "${SANDBOX_SYS_BLOCK:-/sys/block}"/loop*/loop/backing_file; do
	[ -f "$path" ] || continue
	file=$(<"$path") || continue
	if [[ $file == "$SANDBOX_OSD_DIR/osd-"* || $file == *"/volumeDevices/$SANDBOX_OSD_VOLUME-"* ]]; then
		device=${path%/loop/backing_file}
		device=${device##*/}
		left+=("loop device /dev/$device on $file; detach it with sudo losetup -d /dev/$device")
	fi
done
if [ "${#left[@]}" -eq 0 ]; then
	log "nothing left"
	exit 0
fi
for item in "${left[@]}"; do
	printf 'error: left over: %s\n' "$item" >&2
done
exit 1
