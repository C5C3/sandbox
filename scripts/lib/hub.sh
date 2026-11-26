# shellcheck shell=bash
# Flux on sandbox-management, the hub that applies the stages of all three
# clusters. Source scripts/lib/common.sh first, scripts/lib/profile.sh for
# the functions that read the profile, scripts/lib/vendor.sh for
# push_artifact, scripts/lib/register.sh for ensure_registrations,
# scripts/lib/nodes.sh for ensure_node_prep, scripts/lib/trust.sh for
# ensure_trust, and scripts/lib/storage.sh for ensure_block_devices.
#
# The command layer applies the FluxInstance, the source, cluster-vars, the
# kubeconfig Secrets and one root Kustomization per cluster. Each apply is a
# server-side apply with --force-conflicts: the command layer is the only
# source of these objects, so a second run changes nothing and a hand edit of
# a field it sets is taken back.

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
# rather than at its next interval, and records SANDBOX_UPSTREAM_RECORD, the
# checkout of upstream in what push_artifact pushed, in the annotation
# sandbox.c5c3.io/upstream. The apply of flux/source.yaml leaves the
# annotation alone, because it does not set it.
_request_fetch() {
	local out
	out=$(hub_kubectl -n flux-system annotate --overwrite ocirepositories.source.toolkit.fluxcd.io sandbox \
		"reconcile.fluxcd.io/requestedAt=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
		"sandbox.c5c3.io/upstream=$SANDBOX_UPSTREAM_RECORD" 2>&1) ||
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
			out=$(jq -r -L "$SANDBOX_ROOT/scripts/lib" 'include "ready"; ready[1]' <<<"$out")
		else
			out="cannot read it: $out"
		fi
		die "FluxInstance flux is not Ready after 300 s: $out"
	fi
}

# push_artifact: pushes the working tree, without .git/ and .sandbox/, to
# oci://<address of sandbox-registry>:5000/sandbox:latest and sets
# SANDBOX_REVISION to latest@sha256:<digest> of what it pushed and
# SANDBOX_UPSTREAM_RECORD to the record of vendor/cobaltcore in it.
push_artifact() {
	local address url revision commit branch out errfile digest
	command -v flux >/dev/null || die 'flux not found in PATH, see "Host requirements" in the README'
	if ! container_exists "$SANDBOX_REGISTRY" ||
		[ "$(docker container inspect -f '{{.State.Running}}' "$SANDBOX_REGISTRY")" != true ]; then
		die "container $SANDBOX_REGISTRY does not run; run make up first"
	fi
	SANDBOX_UPSTREAM_RECORD=$(vendor_record) ||
		die "$SANDBOX_VENDOR_DIR is not a checkout of upstream; run make vendor"
	export SANDBOX_UPSTREAM_RECORD
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
	# again, which also leaves out vendor/cobaltcore/.git. .sandbox/ holds
	# the cluster-admin kubeconfigs of all three clusters, and the registry
	# serves plain HTTP without authentication to everything on the Docker
	# network. Git's ignore rules do not apply: vendor/ is ignored by Git and
	# travels in the artifact.
	log "pushing the working tree to $url, upstream at $SANDBOX_UPSTREAM_RECORD"
	errfile=$(mktemp)
	if ! out=$(flux push artifact "$url" --path "$SANDBOX_ROOT" --source "$SANDBOX_ROOT" --revision "$revision" \
		--ignore-paths "$SANDBOX_ARTIFACT_IGNORE" --insecure-registry --output json 2>"$errfile"); then
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
			out=$(jq -r --arg rev "$SANDBOX_REVISION" -L "$SANDBOX_ROOT/scripts/lib" 'include "ready";
				ready as [$status, $message]
				| "\($status == "True" and .status.artifact.revision == $rev)\t\($message)"' <<<"$out")
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

# sandbox_cluster <role>: succeeds when the role's cluster exists and has a
# node on SANDBOX_NETWORK. When that cannot be told, the script ends with
# status 1.
sandbox_cluster() {
	local rc=0
	cluster_exists "$1" || return 1
	cluster_on_sandbox_network "$1" || rc=$?
	# Status 2: the function printed why it cannot tell.
	[ "$rc" -ne 2 ] || exit 1
	[ "$rc" -eq 0 ]
}

# attached_roles: prints the roles of SANDBOX_PROFILE_CLUSTERS whose cluster
# is one of the sandbox, separated by spaces. A kind cluster of the same name
# on another Docker network is never given Flux.
attached_roles() {
	local role attached=''
	for role in $SANDBOX_PROFILE_CLUSTERS; do
		if sandbox_cluster "$role"; then
			attached+=${attached:+ }$role
		fi
	done
	printf '%s\n' "$attached"
}

# host_virt_type: prints kvm when /dev/kvm is a character device on the
# host, and qemu otherwise. A kind node sees /dev/kvm exactly when the host
# has it.
host_virt_type() {
	if [ -c /dev/kvm ]; then
		echo kvm
	else
		echo qemu
	fi
}

# cluster_vars: prints the ConfigMap flux-system/cluster-vars. Its data holds
# every scalar leaf of config_merged that is neither null nor empty, as a
# string named by the path joined with _, in upper case, with - replaced by
# _: network.subnet becomes NETWORK_SUBNET. It also holds two variables no
# key of the configuration carries, which the checks below treat like keys
# under the paths given: COMPUTE_VIRT_TYPE, the output of host_virt_type,
# under "the host's /dev/kvm", and STORAGE_POOL_SIZE, the replicas of the
# pools of the module ceph-cluster, under "the pool size of
# switches.osd-count": "2" when switches.osd-count is an integer of 2 or
# more, "1" otherwise, an absent key included. A stage cannot compute it from
# the count. The label reconcile.fluxcd.io/watch makes Flux reconcile the
# stages that read it as soon as a value changes.
cluster_vars() {
	local merged entries bad same virt
	merged=$(config_merged) || exit 1
	virt=$(host_virt_type)
	entries=$(yq -o=json '.' - <<<"$merged" | jq -c --arg virt "$virt" --arg kvm "the host's /dev/kvm" \
		--arg pool "the pool size of switches.osd-count" '
		(.switches["osd-count"]? | tostring) as $osds
		| [paths(type != "object" and type != "array") as $p
		 | getpath($p) as $value
		 | select($value != null and $value != "")
		 | {path: ($p | map(tostring) | join(".")),
		    name: ($p | map(tostring) | join("_") | ascii_upcase | gsub("-"; "_")),
		    value: ($value | tostring)}]
		+ [{path: $kvm, name: "COMPUTE_VIRT_TYPE", value: $virt},
		   {path: $pool, name: "STORAGE_POOL_SIZE",
		    value: (if ($osds | test("^[1-9][0-9]*$")) and ($osds | tonumber) >= 2 then "2" else "1" end)}]')
	bad=$(jq -r 'map(select(.name | test("^[A-Z_][A-Z0-9_]*$") | not))[0] // empty | "\(.path)\t\(.name)"' <<<"$entries")
	[ -z "$bad" ] ||
		die "config: ${bad%%$'\t'*} cannot be a Flux variable, ${bad#*$'\t'} does not match ^[A-Z_][A-Z0-9_]*\$"
	same=$(jq -r 'group_by(.name) | map(select(length > 1))[0] // empty | "\(map(.path) | join(" and ")) become the same Flux variable \(.[0].name)"' <<<"$entries")
	[ -z "$same" ] || die "config: $same"
	jq '{apiVersion: "v1", kind: "ConfigMap",
	     metadata: {name: "cluster-vars", namespace: "flux-system", labels: {"reconcile.fluxcd.io/watch": "Enabled"}},
	     data: (map({key: .name, value}) | from_entries)}' <<<"$entries"
}

# ensure_cluster_vars: applies the output of cluster_vars.
ensure_cluster_vars() {
	local manifest
	manifest=$(cluster_vars) || exit 1
	log "applying the ConfigMap flux-system/cluster-vars"
	_hub_apply "cannot apply the ConfigMap flux-system/cluster-vars on sandbox-management" <<<"$manifest"
}

# ensure_kubeconfig_secret <role>: writes the kubeconfig kind gives for the
# inside of the Docker network into the Secret flux-system/kubeconfig-<role>,
# key value, through which the stages of the role reach its cluster. The
# kubeconfig is never written to a file.
ensure_kubeconfig_secret() {
	local role=$1 name kubeconfig manifest
	name=$(cluster_name "$role")
	kubeconfig=$(kind get kubeconfig --internal --name "$name" 2>/dev/null) ||
		die "cannot read the internal kubeconfig of $name"
	log "writing the Secret flux-system/kubeconfig-$role"
	manifest=$(printf '%s\n' "$kubeconfig" | _hub_json -n flux-system create secret generic "kubeconfig-$role" \
		--from-file=value=/dev/stdin --dry-run=client) ||
		die "cannot write the Secret flux-system/kubeconfig-$role on sandbox-management: $manifest"
	manifest=$(printf '%s\n' "$manifest" | jq '.metadata.labels["reconcile.fluxcd.io/watch"] = "Enabled"')
	printf '%s\n' "$manifest" |
		_hub_apply "cannot write the Secret flux-system/kubeconfig-$role on sandbox-management" || exit 1
}

# root_manifest <role>: prints the root Kustomization cluster-<role>. It
# applies clusters/<role>/ with the modules cluster_modules prints for the
# role that have a stage as components, which puts their stages on
# sandbox-management, and labels the stages with the role. After all modules
# it lists <module>/patches for each of them that has
# clusters/<role>/<module>/patches/kustomization.yaml, a Component whose
# patches change the stages of other modules; a module without a stage is
# that Component alone. Every stage exists before the first of them runs,
# and a patch whose stage the profile does not list changes nothing. With
# prune, a module taken off the list loses its stage, and the stage removes
# what it applied on its cluster.
root_manifest() {
	local role=$1 modules module
	require_roles "$role"
	modules=$(cluster_modules "$role") || exit 1
	cat <<EOT
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-$role
  namespace: flux-system
  labels:
    sandbox.c5c3.io/cluster: $role
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 2m
  path: ./clusters/$role
  prune: true
  sourceRef:
    kind: OCIRepository
    name: sandbox
EOT
	if [ -n "$modules" ]; then
		echo '  components:'
		for module in $modules; do
			if module_has_stage "$role" "$module"; then
				printf '    - %s\n' "$module"
			fi
		done
		for module in $modules; do
			if [ -f "$SANDBOX_ROOT/clusters/$role/$module/patches/kustomization.yaml" ]; then
				printf '    - %s/patches\n' "$module"
			fi
		done
	fi
	cat <<EOT
  commonMetadata:
    labels:
      sandbox.c5c3.io/cluster: $role
EOT
}

# ensure_root <role>: applies the output of root_manifest.
ensure_root() {
	local manifest
	manifest=$(root_manifest "$1") || exit 1
	log "applying the root cluster-$1"
	_hub_apply "cannot apply the root cluster-$1 on sandbox-management" <<<"$manifest"
}

# wait_stages: polls the Kustomizations of sandbox-management every 2 s until
# the root and every stage of the cluster_stages of each attached role is
# Ready with SANDBOX_REVISION as its last applied revision, for at most
# SANDBOX_STAGE_TIMEOUT seconds, by default 600. A stage that is Ready at an
# older revision is not ready.
wait_stages() {
	local timeout attached role module modules start out pending='' failed='' name message
	local -a names=()
	timeout=$(_timeout SANDBOX_STAGE_TIMEOUT 600) || exit 1
	attached=$(attached_roles) || exit 1
	for role in $attached; do
		names+=("cluster-$role")
		modules=$(cluster_stages "$role") || exit 1
		for module in $modules; do
			names+=("$role-$module")
		done
	done

	log "waiting for ${#names[@]} roots and stages to be Ready at $SANDBOX_REVISION"
	start=$SECONDS
	while :; do
		if out=$(_hub_json -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io); then
			failed=''
			pending=$(jq -r --arg names "${names[*]}" --arg rev "$SANDBOX_REVISION" -L "$SANDBOX_ROOT/scripts/lib" 'include "ready";
				(.items // []) as $items
				| ($names | split(" "))[] as $name
				| [$items[] | select(.metadata.name == $name)][0] as $k
				| if $k == null then [$name, "not found"]
				  else ($k | ready) as [$status, $message]
				  | select($status != "True" or $k.status.lastAppliedRevision != $rev)
				  | [$name, $message] end
				| join("\t")' <<<"$out")
			if [ -z "$pending" ]; then
				return 0
			fi
		else
			failed=$out
		fi
		[ $((SECONDS - start)) -lt "$timeout" ] || break
		sleep 2
	done

	[ -z "$failed" ] || die "cannot read the stages of sandbox-management: $failed"
	while IFS=$'\t' read -r name message; do
		printf 'error: stage %s: %s\n' "$name" "$message" >&2
	done <<<"$pending"
	die "$(grep -c '' <<<"$pending") of ${#names[@]} stages are not Ready at $SANDBOX_REVISION after $timeout s; make status shows them"
}

# resolver_hint: with SANDBOX_RESOLVER_FALLBACK true, prints how to send the
# host's lookups of nip.io names to SANDBOX_DNS_ADDRESS, where the CoreDNS of
# sandbox-management answers them, over the bridge of SANDBOX_NETWORK. It runs
# none of the printed commands. With the switch off it prints nothing.
resolver_hint() {
	local out bridge
	[ "${SANDBOX_RESOLVER_FALLBACK:-false}" = true ] || return 0
	# with prints nothing for a missing option, where index alone can print
	# "<no value>".
	out=$(docker network inspect -f '{{with index .Options "com.docker.network.bridge.name"}}{{.}}{{end}} {{.Id}}' "$SANDBOX_NETWORK" 2>/dev/null) ||
		die "cannot read the bridge of Docker network $SANDBOX_NETWORK"
	bridge=${out%% *}
	if [ -z "$bridge" ]; then
		# Docker names the bridge of a network without the option br- and
		# the first 12 characters of the network's ID.
		bridge=${out#* }
		bridge=br-${bridge:0:12}
	fi
	log "the resolver fallback answers nip.io names on $SANDBOX_DNS_ADDRESS; route the host's lookups to it:"
	printf "  sudo resolvectl dns %s %s && sudo resolvectl domain %s '~nip.io'   # systemd-resolved\n" \
		"$bridge" "$SANDBOX_DNS_ADDRESS" "$bridge"
	printf '  server=/nip.io/%s   # dnsmasq\n' "$SANDBOX_DNS_ADDRESS"
}

# hub_sync: installs Flux on sandbox-management, gives the storage node its
# loop devices and their volumes (ensure_block_devices), which comes before
# cluster-vars, so a count the node cannot follow stops the run before the
# ConfigMap carries it to the stages, makes Flux apply the
# cluster_modules of every attached cluster, registers each attached cluster
# whose modules list access with the CobaltCore operators and removes the
# registration of one that no longer lists it (ensure_registrations),
# prepares the worker nodes of sandbox-compute (ensure_node_prep), copies the
# sandbox CA into the ConfigMap flux-system/sandbox-trust when a cluster
# lists trust (ensure_trust), then waits for their stages and logs how many
# stages, those of cluster_stages, are Ready. The registration comes before
# the wait: the stage <role>-access fills the token it needs, and a stage
# that needs the registration would otherwise be waited for before it
# exists. The node preparation runs while Flux applies the stages, whose
# pods wait for the bus and the labels, and so does the copy of the CA,
# which the stage management-pki creates and the stage compute-trust
# substitutes, retrying until the ConfigMap exists. It
# stops before the first step when a stage depends on a stage of a cluster
# that is not attached, because no root would create that stage. Every step
# is safe to repeat; a failed step stops the run and leaves what the steps
# before it applied.
hub_sync() {
	local attached role modules module dep stages=0
	attached=$(attached_roles) || exit 1
	for role in $attached; do
		modules=$(cluster_stages "$role") || exit 1
		for module in $modules; do
			# profile_load has read the stage.yaml of every listed
			# module; make validate renders those of resolver and of
			# the modules the switches add, with every module of the
			# tree.
			for dep in $(yq '.spec.dependsOn // [] | .[].name' "$SANDBOX_ROOT/clusters/$role/$module/stage.yaml"); do
				[[ " $attached " == *" ${dep%%-*} "* ]] ||
					die "the stage $role-$module depends on $dep, but $(cluster_name "${dep%%-*}") is not part of the sandbox; run make up-${dep%%-*} first"
			done
		done
	done
	ensure_flux
	ensure_block_devices
	ensure_cluster_vars
	for role in $attached; do
		if [ "$role" != management ]; then
			ensure_kubeconfig_secret "$role"
		fi
	done
	ensure_source
	for role in $attached; do
		ensure_root "$role"
	done
	ensure_registrations
	ensure_node_prep
	ensure_trust
	wait_stages
	for role in $attached; do
		modules=$(cluster_stages "$role") || exit 1
		stages=$((stages + $(wc -w <<<"$modules")))
	done
	log "$stages stages Ready on $(wc -w <<<"$attached") clusters at $SANDBOX_REVISION"
}
