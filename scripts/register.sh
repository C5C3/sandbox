#!/usr/bin/env bash
# Usage: register.sh <name> <kubeconfig-file> [<namespaces>]
#
# Registers a cluster the sandbox did not create with the CobaltCore
# operators of sandbox-management. Its owner installed the access chart with
# the namespaces given, by default openstack, and hands over the kubeconfig
# of the chart's ServiceAccount: the file, or stdin for -. The script writes
# it into the Secret c5c3-clusters/<name>, the cluster name a
# targetClusterRef names, with the namespaces as a comma-separated list.
# The Secret carries no label of a cluster role, so make up leaves it alone;
# "The registration of a compute cluster" in the README says how to read and
# remove it.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SANDBOX_ROOT/scripts/lib/profile.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/register.sh
. "$SANDBOX_ROOT/scripts/lib/register.sh"

usage() {
	echo "usage: scripts/register.sh <name> <kubeconfig-file> [<namespaces>]" >&2
	exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
name=$1 file=$2 namespaces=${3:-openstack}
# A pipe counts as a file, so <(...) hands a kubeconfig over without one.
if [ "$file" != - ] && { [ ! -e "$file" ] || [ -d "$file" ]; }; then
	die "register: $file not found"
fi
sandbox_cluster management || die "register: sandbox-management does not exist; run make up"
restore_kubeconfig management
if [ "$file" = - ]; then
	register_cluster "$name" "$namespaces"
else
	register_cluster "$name" "$namespaces" <"$file"
fi
log "registered $name in c5c3-clusters for the namespaces $namespaces"
