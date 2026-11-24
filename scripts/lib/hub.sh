# shellcheck shell=bash
# Flux on sandbox-management, the hub that applies the stages of all three
# clusters. Source scripts/lib/common.sh and scripts/lib/profile.sh first.
#
# The command layer applies the FluxInstance, the source, cluster-vars, the
# kubeconfig Secrets and one root Kustomization per cluster. Each apply is a
# server-side apply with --force-conflicts: the command layer is the only
# source of these objects, so a second run changes nothing and a hand edit of
# a field it sets is taken back.

# The jq definition of ready: the status and the first line of the message of
# the Ready condition of the object on the input, or Unknown and "no Ready
# condition" for an object without one.
_HUB_READY='def ready:
  ([.status.conditions[]? | select(.type == "Ready")][0]) as $c
  | if $c == null then ["Unknown", "no Ready condition"]
    else [$c.status // "Unknown", ($c.message // "" | split("\n")[0] // "")] end;'

# _first_line <text>, _last_line <text>: print the first or the last line of
# the text that holds more than spaces.
_first_line() { grep -m 1 '[^[:space:]]' <<<"$1" || :; }
_last_line() { grep '[^[:space:]]' <<<"$1" | tail -n 1 || :; }

# _timeout <variable> <default>: prints the value of the variable, or the
# default when it is unset or empty, and fails when that is no integer of 1
# or more.
_timeout() {
	local value=${!1:-$2}
	[[ $value =~ ^[1-9][0-9]*$ ]] || die "$1 must be an integer of 1 or more, got '$value'"
	printf '%s\n' "$value"
}

# hub_kubectl <argument>...: runs kubectl against sandbox-management.
hub_kubectl() {
	kubectl --kubeconfig "$(kubeconfig_path management)" "$@"
}

# _hub_json <argument>...: runs hub_kubectl with the arguments and -o json and
# prints its output. When kubectl fails, it prints the last line of kubectl's
# error output instead and returns 1.
_hub_json() {
	local errfile out rc=0
	errfile=$(mktemp)
	out=$(hub_kubectl "$@" -o json 2>"$errfile") || rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '%s\n' "$out"
	else
		_last_line "$(<"$errfile")"
	fi
	rm -f -- "$errfile"
	return "$rc"
}

# _hub_apply <message>: applies the manifest on stdin to sandbox-management
# and fails with the message and the last line of kubectl's output.
_hub_apply() {
	local out
	out=$(hub_kubectl apply --server-side --force-conflicts --field-manager=sandbox -f - 2>&1) ||
		die "$1: $(_last_line "$out")"
}

# _request_fetch: asks Flux to fetch the tag of the OCIRepository sandbox now
# rather than at its next interval.
_request_fetch() {
	local out
	out=$(hub_kubectl -n flux-system annotate --overwrite ocirepositories.source.toolkit.fluxcd.io sandbox \
		"reconcile.fluxcd.io/requestedAt=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" 2>&1) ||
		die "cannot ask Flux to fetch the artifact: $(_last_line "$out")"
}

# ensure_flux: installs the chart flux-operator at
# SANDBOX_FLUX_OPERATOR_VERSION on sandbox-management, applies
# flux/flux-instance.yaml and waits until the FluxInstance flux is Ready. A
# failed step leaves the cluster as it is, and a second run repeats all three.
ensure_flux() {
	local out
	log "installing the chart flux-operator $SANDBOX_FLUX_OPERATOR_VERSION on sandbox-management"
	out=$(helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
		--version "$SANDBOX_FLUX_OPERATOR_VERSION" --namespace flux-system --create-namespace \
		--kubeconfig "$(kubeconfig_path management)" --wait --timeout 5m 2>&1) ||
		die "cannot install the chart flux-operator $SANDBOX_FLUX_OPERATOR_VERSION on sandbox-management: $(_last_line "$out")"
	hub_kubectl wait --for=condition=Established crd/fluxinstances.fluxcd.controlplane.io --timeout=60s >/dev/null 2>&1 ||
		die "the CRD fluxinstances.fluxcd.controlplane.io is not established after 60 s"

	log "applying the FluxInstance flux and waiting for it to be Ready"
	_hub_apply "cannot apply the FluxInstance flux on sandbox-management" <"$SANDBOX_ROOT/flux/flux-instance.yaml"
	if ! hub_kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=300s >/dev/null 2>&1; then
		if out=$(_hub_json -n flux-system get fluxinstances.fluxcd.controlplane.io flux); then
			out=$(jq -r "$_HUB_READY"' ready[1]' <<<"$out")
		else
			out="cannot read it: $out"
		fi
		die "FluxInstance flux is not Ready after 300 s: $out"
	fi
}

# push_artifact: pushes the working tree, without .git/ and .sandbox/, to
# oci://<address of sandbox-registry>:5000/sandbox:latest and sets
# SANDBOX_REVISION to latest@sha256:<digest> of what it pushed.
push_artifact() {
	local address url revision commit branch out errfile digest
	command -v flux >/dev/null || die 'flux not found in PATH, see "Host requirements" in the README'
	if ! container_exists "$SANDBOX_REGISTRY" ||
		[ "$(docker container inspect -f '{{.State.Running}}' "$SANDBOX_REGISTRY")" != true ]; then
		die "container $SANDBOX_REGISTRY does not run; run make up first"
	fi
	# The host reaches the registry at its address on the Docker network; the
	# registry publishes no port.
	address=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$SANDBOX_NETWORK\").IPAddress}}" "$SANDBOX_REGISTRY") ||
		die "cannot read the address of $SANDBOX_REGISTRY on $SANDBOX_NETWORK"
	url=oci://$address:$SANDBOX_REGISTRY_PORT/sandbox:latest

	revision=worktree@sha1:0000000000000000000000000000000000000000
	if commit=$(git -C "$SANDBOX_ROOT" rev-parse --verify --quiet HEAD 2>/dev/null) &&
		branch=$(git -C "$SANDBOX_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null); then
		revision=$branch@sha1:$commit
	fi

	# --ignore-paths replaces the default list of flux, so it names .git/
	# again. .sandbox/ holds the cluster-admin kubeconfigs of all three
	# clusters, and the registry serves plain HTTP without authentication to
	# everything on the Docker network. Git's ignore rules do not apply:
	# vendor/ is ignored by Git and travels in the artifact.
	log "pushing the working tree to $url"
	errfile=$(mktemp)
	if ! out=$(flux push artifact "$url" --path "$SANDBOX_ROOT" --source "$SANDBOX_ROOT" --revision "$revision" \
		--ignore-paths ".git/,.sandbox/" --insecure-registry --output json 2>"$errfile"); then
		out=$(_first_line "$(<"$errfile")")
		rm -f -- "$errfile"
		die "cannot push the working tree to $url: ${out#✗ }"
	fi
	rm -f -- "$errfile"
	digest=$(jq -r '.digest // empty' <<<"$out" 2>/dev/null) || digest=
	[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
		die "cannot read the digest of the pushed artifact from the output of flux"
	export SANDBOX_REVISION=latest@$digest
}

# ensure_source: pushes the working tree, applies flux/source.yaml, asks Flux
# to fetch the artifact and polls every 2 s until the OCIRepository sandbox
# is Ready at SANDBOX_REVISION, for at most SANDBOX_SOURCE_TIMEOUT seconds, by
# default 120.
ensure_source() {
	local timeout start out ready message
	timeout=$(_timeout SANDBOX_SOURCE_TIMEOUT 120) || exit 1
	push_artifact
	log "applying the OCIRepository sandbox and waiting for $SANDBOX_REVISION"
	_hub_apply "cannot apply the OCIRepository sandbox on sandbox-management" <"$SANDBOX_ROOT/flux/source.yaml"
	_request_fetch

	start=$SECONDS
	while :; do
		if out=$(_hub_json -n flux-system get ocirepositories.source.toolkit.fluxcd.io sandbox); then
			out=$(jq -r --arg rev "$SANDBOX_REVISION" "$_HUB_READY"'
				ready as [$status, $message]
				| [$status == "True" and .status.artifact.revision == $rev, $message] | @tsv' <<<"$out")
			ready=${out%%$'\t'*} message=${out#*$'\t'}
			if [ "$ready" = true ]; then
				return 0
			fi
		else
			message="cannot read it: $out"
		fi
		[ $((SECONDS - start)) -lt "$timeout" ] || break
		sleep 2
	done
	die "source sandbox is not Ready at $SANDBOX_REVISION after $timeout s: $message; the pods of sandbox-management must resolve and reach $SANDBOX_REGISTRY:$SANDBOX_REGISTRY_PORT"
}
