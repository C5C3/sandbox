#!/usr/bin/env bash
# Usage: status.sh
#
# Lists the FluxInstance, the source, the root of each cluster and the stages
# on sandbox-management with the status and the message of their Ready
# condition, per cluster. It reads no configuration and no profile and runs
# no host check. It exits 0 whenever it could read the hub: a stage that is
# not ready is a row, not an exit status.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"

errfile=$(mktemp)
trap 'rm -f -- "$errfile"' EXIT

if ! sandbox_cluster management; then
	echo "status: sandbox-management does not exist"
	exit 0
fi
restore_kubeconfig management

crds=$(hub_kubectl get crd fluxinstances.fluxcd.controlplane.io ocirepositories.source.toolkit.fluxcd.io \
	kustomizations.kustomize.toolkit.fluxcd.io --ignore-not-found -o name 2>"$errfile") ||
	die "status: cannot read the Flux objects of sandbox-management: $(_last_line "$(<"$errfile")")"
if [ "$(grep -c . <<<"$crds")" -lt 3 ]; then
	echo "status: Flux is not installed on sandbox-management, run make up-management"
	exit 0
fi
objects=$(hub_kubectl -n flux-system get fluxinstances.fluxcd.controlplane.io,ocirepositories.source.toolkit.fluxcd.io,kustomizations.kustomize.toolkit.fluxcd.io \
	-o json 2>"$errfile") ||
	die "status: cannot read the Flux objects of sandbox-management: $(_last_line "$(<"$errfile")")"

clusters=$(SANDBOX_PROFILE_CLUSTERS="${SANDBOX_ROLES[*]}" attached_roles)
rows=$(jq -r --arg clusters "$clusters" -f "$SANDBOX_ROOT/scripts/lib/status.jq" <<<"$objects")

total=0
ready=0
printf '%-12s %-40s %-8s %s\n' CLUSTER OBJECT READY MESSAGE
while IFS=$'\t' read -r cluster object state message; do
	if [ -z "$cluster" ]; then
		continue
	fi
	printf '%-12s %-40s %-8s %s\n' "$cluster" "$object" "$state" "$message"
	if [ "$object" != - ]; then
		total=$((total + 1))
		if [ "$state" = True ]; then
			ready=$((ready + 1))
		fi
	fi
done <<<"$rows"
printf 'status: %d of %d ready\n' "$ready" "$total"
