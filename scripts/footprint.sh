#!/usr/bin/env bash
# Usage: footprint.sh
#
# Reports the memory requests and the working set of each kind cluster of the
# sandbox, of the registry, and their total, in MiB. It reads no configuration
# and runs no host check.
#
# The working set of a container is memory.current minus inactive_file of its
# cgroup. The cgroup of a node container holds the kubelet, containerd and
# every pod, which is what counts against the memory of the host.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

errfile=$(mktemp)
trap 'rm -f -- "$errfile"' EXIT

# working_set <container>: prints the working set of the container in bytes.
working_set() {
	local out current inactive
	out=$(docker exec "$1" cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.stat 2>/dev/null) ||
		return 1
	current=${out%%$'\n'*}
	inactive=$(awk '$1 == "inactive_file" { print $2 }' <<<"$out")
	[[ $current =~ ^[0-9]+$ && $inactive =~ ^[0-9]+$ ]] || return 1
	if [ "$current" -gt "$inactive" ]; then
		echo $((current - inactive))
	else
		echo 0
	fi
}

# mib <bytes>: prints the bytes in MiB, rounded to the nearest.
mib() {
	echo $((($1 + 524288) / 1048576))
}

rows=()
total_requests=0
total_working_set=0

for role in "${SANDBOX_ROLES[@]}"; do
	if ! cluster_exists "$role"; then
		continue
	fi
	name=$(cluster_name "$role")
	restore_kubeconfig "$role"

	pods=$(kubectl --kubeconfig "$(kubeconfig_path "$role")" get pods --all-namespaces -o json 2>"$errfile") ||
		die "footprint: cannot list the pods of $name: $(grep -v '^[[:space:]]*$' "$errfile" | tail -n 1)"
	requests=$(jq -f "$SANDBOX_ROOT/scripts/lib/requests.jq" <<<"$pods" 2>"$errfile") ||
		die "footprint: cannot sum the requests of $name: $(head -n 1 "$errfile")"

	working_set_bytes=0
	nodes=$(kind get nodes --name "$name")
	for node in $nodes; do
		bytes=$(working_set "$node") || die "footprint: cannot read the memory of $node"
		working_set_bytes=$((working_set_bytes + bytes))
	done

	rows+=("$name" "$(mib "$requests")" "$(mib "$working_set_bytes")")
	total_requests=$((total_requests + requests))
	total_working_set=$((total_working_set + working_set_bytes))
done

if container_exists "$SANDBOX_REGISTRY" &&
	[ "$(docker container inspect -f '{{.State.Running}}' "$SANDBOX_REGISTRY")" = true ]; then
	bytes=$(working_set "$SANDBOX_REGISTRY") || die "footprint: cannot read the memory of $SANDBOX_REGISTRY"
	rows+=(registry - "$(mib "$bytes")")
	total_working_set=$((total_working_set + bytes))
fi

printf '%-20s %12s %15s\n' CLUSTER REQUESTS_MIB WORKING_SET_MIB "${rows[@]}" \
	total "$(mib "$total_requests")" "$(mib "$total_working_set")"
