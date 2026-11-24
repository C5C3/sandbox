#!/usr/bin/env bash
# Usage: push.sh
#
# Pushes the working tree to the registry of the sandbox and asks Flux on
# sandbox-management to fetch it, recording the commit of vendor/cobaltcore
# in the annotation sandbox.c5c3.io/upstream of the source. It reads no
# configuration and no profile, runs no host check and does not wait for the
# stages; make status shows them. A changed profile is applied by make up,
# not by a push.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/vendor.sh
. "$SANDBOX_ROOT/scripts/lib/vendor.sh"

push_artifact

follows=false
if sandbox_cluster management; then
	restore_kubeconfig management
	out=$(_hub_json get crd ocirepositories.source.toolkit.fluxcd.io --ignore-not-found) ||
		die "cannot ask Flux to fetch the artifact: $out"
	if [ -n "$out" ]; then
		out=$(_hub_json -n flux-system get ocirepositories.source.toolkit.fluxcd.io sandbox --ignore-not-found) ||
			die "cannot ask Flux to fetch the artifact: $out"
		if [ -n "$out" ]; then
			follows=true
		fi
	fi
fi

if $follows; then
	_request_fetch
	log "asked Flux on sandbox-management to fetch $SANDBOX_REVISION"
else
	log "nothing follows the tag yet, run make up"
fi
