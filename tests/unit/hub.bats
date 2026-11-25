#!/usr/bin/env bats
# scripts/lib/hub.sh: Flux on sandbox-management, with kubectl, helm, kind,
# docker and flux replaced by functions.

setup() {
	load helpers
	DIGEST=$(printf 'a%.0s' {1..64})
}

# registry_runs: replaces docker with a function that lists sandbox-registry
# as a running container at 172.30.0.2, and makes vendor/cobaltcore in the
# test's directory a checkout of upstream.
registry_runs() {
	vendor_checkout
	docker() {
		case $* in
		"ps -a --format {{.Names}}") echo sandbox-registry ;;
		"container inspect -f {{.State.Running}} sandbox-registry") echo true ;;
		"inspect -f "*" sandbox-registry") echo 172.30.0.2 ;;
		*) return 1 ;;
		esac
	}
}

# condition <status> <message> [<revision>]: prints an object whose Ready
# condition has the status and the message, at the revision.
condition() {
	jq -n --arg status "$1" --arg message "$2" --arg rev "${3:-}" \
		'{status: {conditions: [{type: "Ready", status: $status, message: $message}], artifact: {revision: $rev}}}'
}

# source_answers <json>: replaces hub_kubectl with a function that applies
# and annotates, and prints the JSON as the OCIRepository sandbox.
source_answers() {
	SOURCE=$1
	hub_kubectl() {
		case $* in
		"apply "*) cat >/dev/null ;;
		"-n flux-system annotate "*) ;;
		"-n flux-system get ocirepositories.source.toolkit.fluxcd.io sandbox -o json") printf '%s\n' "$SOURCE" ;;
		*) return 1 ;;
		esac
	}
}

@test "ensure_flux fails with the last line of helm's output" {
	config_load
	helm() {
		printf 'first line\nError: INSTALLATION FAILED: context deadline exceeded\n\n'
		return 1
	}
	run ensure_flux
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot install the chart flux-operator 0.63.1 on sandbox-management: Error: INSTALLATION FAILED: context deadline exceeded" ]
}

@test "ensure_flux installs the pinned chart into flux-system of sandbox-management" {
	config_load
	helm() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/helm.args"; }
	hub_kubectl() {
		if [ "$1" = apply ]; then cat >"$BATS_TEST_TMPDIR/applied.yaml"; fi
	}
	run ensure_flux
	[ "$status" -eq 0 ]
	[ "$(paste -sd ' ' "$BATS_TEST_TMPDIR/helm.args")" = "upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --version 0.63.1 --namespace flux-system --create-namespace --kubeconfig $SANDBOX_ROOT/.sandbox/kubeconfig/management.yaml --wait --timeout 5m" ]
	cmp "$BATS_TEST_TMPDIR/applied.yaml" "$SANDBOX_ROOT/flux/flux-instance.yaml"
}

@test "ensure_flux fails when the CRD of the FluxInstance is not established" {
	config_load
	helm() { :; }
	hub_kubectl() { return 1; }
	run ensure_flux
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: the CRD fluxinstances.fluxcd.controlplane.io is not established after 60 s" ]
}

@test "ensure_flux fails with the message of the Ready condition of the FluxInstance" {
	config_load
	helm() { :; }
	hub_kubectl() {
		case $* in
		"wait --for=condition=Established "*) ;;
		"apply "*) cat >/dev/null ;;
		"-n flux-system get fluxinstances.fluxcd.controlplane.io flux -o json") condition False $'Reconciliation failed\ndetails' ;;
		*) return 1 ;;
		esac
	}
	run ensure_flux
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: FluxInstance flux is not Ready after 300 s: Reconciliation failed" ]
}

@test "ensure_flux fails with the last line of kubectl when the FluxInstance cannot be applied" {
	config_load
	helm() { :; }
	hub_kubectl() {
		case $1 in
		wait) ;;
		apply) printf 'Warning: x\nerror: the server is unavailable\n' >&2; return 1 ;;
		esac
	}
	run ensure_flux
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot apply the FluxInstance flux on sandbox-management: error: the server is unavailable" ]
}

@test "push_artifact fails when flux is not in PATH" {
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	ln -s -- "$(command -v dirname)" "$BATS_TEST_TMPDIR/bin/dirname"
	run env -i PATH="$BATS_TEST_TMPDIR/bin" "$BASH" -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/hub.sh"; push_artifact' _ "$SANDBOX_ROOT"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: flux not found in PATH, see "Host requirements" in the README' ]
}

@test "push_artifact fails when the registry container is absent or stopped" {
	docker() { :; }
	run push_artifact
	[ "$status" -eq 1 ]
	[ "$output" = "error: container sandbox-registry does not run; run make up first" ]

	docker() {
		case $1 in
		ps) echo sandbox-registry ;;
		container) echo false ;;
		esac
	}
	run push_artifact
	[ "$status" -eq 1 ]
	[ "$output" = "error: container sandbox-registry does not run; run make up first" ]
}

@test "push_artifact fails without a checkout of upstream and does not push" {
	registry_runs
	SANDBOX_VENDOR_DIR=$BATS_TEST_TMPDIR/missing/cobaltcore
	flux() { touch "$BATS_TEST_TMPDIR/flux.called"; }
	run push_artifact
	[ "$status" -eq 1 ]
	[ "$output" = "error: $BATS_TEST_TMPDIR/missing/cobaltcore is not a checkout of upstream; run make vendor" ]
	[ ! -e "$BATS_TEST_TMPDIR/flux.called" ]
}

@test "push_artifact records the commit of the checkout and marks local changes" {
	registry_runs
	flux() { echo "{\"digest\": \"sha256:$DIGEST\"}"; }
	run push_artifact
	[ "$status" -eq 0 ]
	[[ $output == *": pushing the working tree to oci://172.30.0.2:5000/sandbox:latest, upstream at $UPSTREAM_FIRST" ]]
	push_artifact >/dev/null
	[ "$SANDBOX_UPSTREAM_RECORD" = "$UPSTREAM_FIRST" ]

	touch "$SANDBOX_VENDOR_DIR/deploy/new.tmp"
	push_artifact >/dev/null
	[ "$SANDBOX_UPSTREAM_RECORD" = "$UPSTREAM_FIRST-modified" ]
}

@test "push_artifact fails with the first line of flux's error" {
	registry_runs
	flux() {
		printf '✗ error setting up transport: connection refused\nsecond line\n' >&2
		return 1
	}
	run push_artifact
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot push the working tree to oci://172.30.0.2:5000/sandbox:latest: error setting up transport: connection refused" ]
}

@test "push_artifact fails when flux prints no digest" {
	registry_runs
	flux() { echo '{"tag": "latest"}'; }
	run push_artifact
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot read the digest of the pushed artifact from the output of flux" ]
}

@test "push_artifact pushes the working tree without .git and .sandbox and sets the revision" {
	registry_runs
	flux() {
		printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/flux.args"
		echo "{\"digest\": \"sha256:$DIGEST\"}"
	}
	push_artifact >/dev/null
	[ "$SANDBOX_REVISION" = "latest@sha256:$DIGEST" ]
	args=" $(paste -sd ' ' "$BATS_TEST_TMPDIR/flux.args") "
	[[ $args == " push artifact oci://172.30.0.2:5000/sandbox:latest "* ]]
	[[ $args == *" --path $SANDBOX_ROOT "* ]]
	[[ $args == *" --ignore-paths .git/,.sandbox/ "* ]]
	[[ $args == *" --insecure-registry "* ]]
	[[ $args =~ \ --revision\ [^@\ ]+@sha1:[0-9a-f]{40}\  ]]
}

@test "push_artifact outside a Git work tree pushes the revision worktree" {
	registry_runs
	flux() {
		printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/flux.args"
		echo "{\"digest\": \"sha256:$DIGEST\"}"
	}
	SANDBOX_ROOT=$BATS_TEST_TMPDIR/tree
	mkdir -- "$SANDBOX_ROOT"
	push_artifact >/dev/null
	[ "$(grep -A1 -x -- --revision "$BATS_TEST_TMPDIR/flux.args" | tail -n 1)" = worktree@sha1:0000000000000000000000000000000000000000 ]
}

@test "flux/source.yaml follows the registry, the repository and the tag push_artifact pushes to" {
	local pushed
	registry_runs
	flux() {
		printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/flux.args"
		echo "{\"digest\": \"sha256:$DIGEST\"}"
	}
	push_artifact >/dev/null
	pushed=$(sed -n 3p "$BATS_TEST_TMPDIR/flux.args")
	[ "$(yq '.spec.url + ":" + .spec.ref.tag' "$SANDBOX_ROOT/flux/source.yaml")" = "oci://$SANDBOX_REGISTRY:${pushed#oci://172.30.0.2:}" ]
	[ "${SANDBOX_REVISION%@*}" = "$(yq '.spec.ref.tag' "$SANDBOX_ROOT/flux/source.yaml")" ]
}

@test "ensure_source fails with the message of the source when it is not Ready" {
	export SANDBOX_SOURCE_TIMEOUT=2
	push_artifact() { export SANDBOX_REVISION=latest@sha256:new; }
	source_answers "$(condition False $'failed to pull artifact: dial tcp: lookup sandbox-registry: no such host\nmore')"
	run ensure_source
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: source sandbox is not Ready at latest@sha256:new after 2 s: failed to pull artifact: dial tcp: lookup sandbox-registry: no such host; the pods of sandbox-management must resolve and reach sandbox-registry:5000" ]
}

@test "ensure_source does not take a source that is Ready at another revision" {
	export SANDBOX_SOURCE_TIMEOUT=2
	push_artifact() { export SANDBOX_REVISION=latest@sha256:new; }
	source_answers "$(condition True "stored artifact for digest 'latest@sha256:old'" latest@sha256:old)"
	run ensure_source
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: source sandbox is not Ready at latest@sha256:new after 2 s: stored artifact for digest 'latest@sha256:old'; the pods of sandbox-management must resolve and reach sandbox-registry:5000" ]
}

@test "ensure_source returns when the source is Ready at the pushed revision" {
	export SANDBOX_SOURCE_TIMEOUT=2
	push_artifact() { export SANDBOX_REVISION=latest@sha256:new; }
	source_answers "$(condition True "stored artifact for digest 'latest@sha256:new'" latest@sha256:new)"
	run ensure_source
	[ "$status" -eq 0 ]
}

@test "ensure_source names the error of kubectl when it cannot read the source" {
	export SANDBOX_SOURCE_TIMEOUT=2
	push_artifact() { export SANDBOX_REVISION=latest@sha256:new; }
	hub_kubectl() {
		case $1 in
		apply) cat >/dev/null ;;
		-n) [ "$3" = annotate ] || { echo 'error: the server could not find the requested resource' >&2; return 1; } ;;
		esac
	}
	run ensure_source
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "error: source sandbox is not Ready at latest@sha256:new after 2 s: cannot read it: error: the server could not find the requested resource;"* ]]
}

@test "ensure_source fails when Flux cannot be asked to fetch" {
	push_artifact() { export SANDBOX_REVISION=latest@sha256:new; }
	hub_kubectl() {
		case $1 in
		apply) cat >/dev/null ;;
		*) echo 'Error from server (NotFound): ocirepositories "sandbox" not found' >&2; return 1 ;;
		esac
	}
	run ensure_source
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'error: cannot ask Flux to fetch the artifact: Error from server (NotFound): ocirepositories "sandbox" not found' ]
}

@test "a timeout that is not a positive integer fails before anything is pushed" {
	push_artifact() { echo "unit test called push_artifact" >&2; return 1; }
	for value in 0 abc -1; do
		export SANDBOX_SOURCE_TIMEOUT=$value
		run ensure_source
		[ "$status" -eq 1 ]
		[ "$output" = "error: SANDBOX_SOURCE_TIMEOUT must be an integer of 1 or more, got '$value'" ]
	done
}

# kustomization <name> <status> <message> <revision> [<role>]: prints a Flux
# Kustomization with the Ready condition, the last applied revision and the
# label of the role.
kustomization() {
	jq -n --arg name "$1" --arg status "$2" --arg message "$3" --arg rev "$4" --arg role "${5:-}" '
		{kind: "Kustomization", metadata: ({name: $name} + if $role == "" then {} else {labels: {"sandbox.c5c3.io/cluster": $role}} end),
		 status: {conditions: [{type: "Ready", status: $status, message: $message}], lastAppliedRevision: $rev}}'
}

# stages_answer <object>...: replaces hub_kubectl with a function that lists
# the objects as the Kustomizations of flux-system.
stages_answer() {
	jq -s '{items: .}' <<<"$*" >"$BATS_TEST_TMPDIR/stages.json"
	hub_kubectl() {
		[ "$*" = "-n flux-system get kustomizations.kustomize.toolkit.fluxcd.io -o json" ] || return 1
		cat "$BATS_TEST_TMPDIR/stages.json"
	}
}

# ready_stages [<name>...]: prints a Ready Kustomization at the revision for
# each root and stage of scaffold whose name is not given.
ready_stages() {
	local name
	for name in cluster-management management-test cluster-storage storage-test cluster-compute compute-test; do
		if [[ " $* " != *" $name "* ]]; then
			kustomization "$name" True "Applied revision: latest@sha256:new" latest@sha256:new
		fi
	done
}

# scaffold_attached: loads scaffold with all three clusters attached and the
# timeout of the stages at 2 s.
scaffold_attached() {
	profile_load
	attached_roles() { echo "management storage compute"; }
	export SANDBOX_REVISION=latest@sha256:new SANDBOX_STAGE_TIMEOUT=2
}

@test "cluster_vars prints every key of the configuration as a string in cluster-vars" {
	local pin
	# scripts/pin.sh moves the pin, so the test reads it.
	pin=$(yq '.upstream.cobaltcore' "$SANDBOX_ROOT/config.yaml")
	run cluster_vars
	[ "$status" -eq 0 ]
	[ "$(yq '[.apiVersion, .kind, .metadata.name, .metadata.namespace] | join(" ")' - <<<"$output")" = "v1 ConfigMap cluster-vars flux-system" ]
	[ "$(yq -o=json -I=0 '.metadata.labels' - <<<"$output")" = '{"reconcile.fluxcd.io/watch":"Enabled"}' ]
	[ "$(yq -o=json -I=0 '.data' - <<<"$output")" = '{"NETWORK_SUBNET":"172.30.0.0/16","ADDRESSES_GATEWAY":"172.30.255.10","ADDRESSES_POOL":"172.30.255.0/24","ADDRESSES_DNS":"172.30.255.53","REGISTRY_IMAGE":"registry:3","SWITCHES_HYPERVISOR_NODES":"1","SWITCHES_RESOLVER_FALLBACK":"false","UPSTREAM_COBALTCORE":"'"$pin"'","FLUX_OPERATOR":"0.63.1"}' ]
	[ "$(yq '[.data[] | tag] | unique | join(" ")' - <<<"$output")" = '!!str' ]
}

@test "cluster_vars leaves out null and empty keys and keeps false" {
	config_with '.registry.mirror = null | .addresses.extra = "" | .switches.ui = false'
	run cluster_vars
	[ "$status" -eq 0 ]
	[ "$(yq '.data | has("REGISTRY_MIRROR") or has("ADDRESSES_EXTRA")' - <<<"$output")" = false ]
	[ "$(yq -o=json '.data.SWITCHES_UI' - <<<"$output")" = '"false"' ]
}

@test "cluster_vars fails for a key that cannot be a Flux variable" {
	config_with '.addresses["my key"] = "x"'
	run cluster_vars
	[ "$status" -eq 1 ]
	[ "$output" = 'error: config: addresses.my key cannot be a Flux variable, ADDRESSES_MY KEY does not match ^[A-Z_][A-Z0-9_]*$' ]
}

@test "cluster_vars fails for two keys that become the same Flux variable" {
	profile_with $'clusters: [management]\nswitches:\n  hypervisor_nodes: 2'
	profile_load
	run cluster_vars
	[ "$status" -eq 1 ]
	[ "$output" = 'error: config: switches.hypervisor-nodes and switches.hypervisor_nodes become the same Flux variable SWITCHES_HYPERVISOR_NODES' ]
}

@test "up.sh stops before it calls kind or Docker when two keys become the same Flux variable" {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	# The host check passes.
	echo 'preflight_run() { :; }' >"$BATS_TEST_TMPDIR/scripts/lib/preflight.sh"
	export SANDBOX_CONFIG=$SANDBOX_ROOT/config.yaml
	profile_with $'clusters: [management]\nswitches:\n  hypervisor_nodes: 2'
	export -f docker kind
	run "$BATS_TEST_TMPDIR/scripts/up.sh"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: config: switches.hypervisor-nodes and switches.hypervisor_nodes become the same Flux variable SWITCHES_HYPERVISOR_NODES' ]
}

@test "up.sh stops before it calls kind or Docker when the resolver switch is on and the profile lists no loadbalancer" {
	cp -R -- "$SANDBOX_ROOT/scripts" "$SANDBOX_ROOT/profiles" "$SANDBOX_ROOT/clusters" "$BATS_TEST_TMPDIR/"
	# The host check passes.
	echo 'preflight_run() { :; }' >"$BATS_TEST_TMPDIR/scripts/lib/preflight.sh"
	config_with '.switches["resolver-fallback"] = true'
	export -f docker kind
	run "$BATS_TEST_TMPDIR/scripts/up.sh"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: switches.resolver-fallback needs the module loadbalancer on sandbox-management, the profile scaffold does not list it' ]
}

@test "up.sh stops at a failed fetch of upstream before it calls kind or Docker" {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	# The host check passes.
	echo 'preflight_run() { :; }' >"$BATS_TEST_TMPDIR/scripts/lib/preflight.sh"
	export SANDBOX_CONFIG=$SANDBOX_ROOT/config.yaml SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/missing
	profile_with 'clusters: [management, storage, compute]'
	export -f docker kind
	run "$BATS_TEST_TMPDIR/scripts/up.sh"
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "error: vendor: cannot fetch $(yq '.upstream.cobaltcore' "$SANDBOX_CONFIG") from file://$BATS_TEST_TMPDIR/missing: "?* ]]
	[[ $output != *"unit test called"* ]]
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox" ]
}

@test "cluster_vars carries the switches of the profile" {
	profile_with $'clusters: [management]\nswitches:\n  hypervisor-nodes: 2'
	profile_load
	run cluster_vars
	[ "$status" -eq 0 ]
	[ "$(yq -o=json '.data.SWITCHES_HYPERVISOR_NODES' - <<<"$output")" = '"2"' ]
}

@test "cluster_vars fails with the message of config_load for a missing configuration" {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/missing.yaml
	run cluster_vars
	[ "$status" -eq 1 ]
	[ "$output" = "error: config: $SANDBOX_CONFIG not found" ]
}

@test "root_manifest prints the root of storage with the modules of scaffold as components" {
	profile_load
	run root_manifest storage
	[ "$status" -eq 0 ]
	[ "$(yq '[.apiVersion, .kind, .metadata.name, .metadata.namespace] | join(" ")' - <<<"$output")" = "kustomize.toolkit.fluxcd.io/v1 Kustomization cluster-storage flux-system" ]
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.prune, .spec.components, .spec.sourceRef]' - <<<"$output")" = \
		'["./clusters/storage",true,["test"],{"kind":"OCIRepository","name":"sandbox"}]' ]
	[ "$(yq '.metadata.labels["sandbox.c5c3.io/cluster"] + " " + .spec.commonMetadata.labels["sandbox.c5c3.io/cluster"]' - <<<"$output")" = "storage storage" ]
	[ "$(yq '.spec | has("kubeConfig")' - <<<"$output")" = false ]
}

@test "root_manifest prints no components for a cluster without modules" {
	profile_with $'clusters: [management, storage]\nmodules:\n  management: [test]'
	profile_load
	run root_manifest storage
	[ "$status" -eq 0 ]
	[ "$(yq '.spec | has("components")' - <<<"$output")" = false ]
	[ "$(yq '.spec.path' - <<<"$output")" = ./clusters/storage ]
}

@test "root_manifest fails for a word that is not a role" {
	profile_load
	run root_manifest network
	[ "$status" -eq 1 ]
	[ "$output" = "error: unknown cluster role 'network', expected management, storage or compute" ]
}

@test "wait_stages returns when every root and stage is Ready at the revision" {
	scaffold_attached
	stages_answer "$(ready_stages)"
	run wait_stages
	[ "$status" -eq 0 ]
}

@test "wait_stages names a stage that is not Ready and counts the roots and stages" {
	scaffold_attached
	stages_answer "$(ready_stages storage-test)" "$(kustomization storage-test False $'Secret "kubeconfig-storage" not found\ndetails' latest@sha256:old)"
	run wait_stages
	[ "$status" -eq 1 ]
	[ "${lines[-2]}" = 'error: stage storage-test: Secret "kubeconfig-storage" not found' ]
	[ "${lines[-1]}" = "error: 1 of 6 stages are not Ready at latest@sha256:new after 2 s; make status shows them" ]
}

@test "wait_stages names a stage that does not exist or has no Ready condition" {
	scaffold_attached
	stages_answer "$(ready_stages storage-test compute-test)" '{"metadata": {"name": "compute-test"}}'
	run wait_stages
	[ "$status" -eq 1 ]
	[ "${lines[-3]}" = "error: stage storage-test: not found" ]
	[ "${lines[-2]}" = "error: stage compute-test: no Ready condition" ]
	[ "${lines[-1]}" = "error: 2 of 6 stages are not Ready at latest@sha256:new after 2 s; make status shows them" ]
}

@test "wait_stages does not take a stage that is Ready at another revision" {
	scaffold_attached
	stages_answer "$(ready_stages compute-test)" "$(kustomization compute-test True "Applied revision: latest@sha256:old" latest@sha256:old)"
	run wait_stages
	[ "$status" -eq 1 ]
	[ "${lines[-2]}" = "error: stage compute-test: Applied revision: latest@sha256:old" ]
	[[ ${lines[-1]} == "error: 1 of 6 stages are not Ready"* ]]
}

@test "wait_stages fails with the last line of kubectl when it cannot read the stages" {
	scaffold_attached
	hub_kubectl() {
		printf 'E1124 memcache.go\nThe connection to the server 127.0.0.1:40001 was refused\n' >&2
		return 1
	}
	run wait_stages
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot read the stages of sandbox-management: The connection to the server 127.0.0.1:40001 was refused" ]
}

@test "wait_stages waits only for the attached clusters" {
	scaffold_attached
	attached_roles() { echo management; }
	stages_answer "$(kustomization cluster-management True ok latest@sha256:new)" "$(kustomization management-test True ok latest@sha256:new)"
	run wait_stages
	[ "$status" -eq 0 ]
}

@test "ensure_kubeconfig_secret fails when kind cannot read the internal kubeconfig" {
	run ensure_kubeconfig_secret storage
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot read the internal kubeconfig of sandbox-storage" ]
}

@test "ensure_kubeconfig_secret writes the internal kubeconfig into a watched Secret" {
	kind() {
		[ "$*" = "get kubeconfig --internal --name sandbox-storage" ] || return 1
		printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://sandbox-storage-control-plane:6443\n'
	}
	hub_kubectl() {
		case $* in
		"-n flux-system create secret generic kubeconfig-storage --from-file=value=/dev/stdin --dry-run=client -o json")
			jq -n --arg value "$(base64 -w0)" '{apiVersion: "v1", kind: "Secret", metadata: {name: "kubeconfig-storage", namespace: "flux-system"}, data: {value: $value}}' ;;
		"apply --server-side --force-conflicts --field-manager=sandbox -f -") cat >"$BATS_TEST_TMPDIR/applied.json" ;;
		*) return 1 ;;
		esac
	}
	run ensure_kubeconfig_secret storage
	[ "$status" -eq 0 ]
	[ "$(jq -r '.metadata.labels["reconcile.fluxcd.io/watch"]' "$BATS_TEST_TMPDIR/applied.json")" = Enabled ]
	[ "$(jq -r '.data.value | @base64d' "$BATS_TEST_TMPDIR/applied.json")" = "$(kind get kubeconfig --internal --name sandbox-storage)" ]
}

@test "ensure_kubeconfig_secret hands a kubeconfig larger than a pipe buffer to no file" {
	kind() {
		printf 'apiVersion: v1\n# '
		head -c 200000 /dev/zero | tr '\0' a
		echo
	}
	# A command whose stdin is a regular file notes its name in files.
	jq() {
		[ ! -f /dev/stdin ] || echo jq >>"$BATS_TEST_TMPDIR/files"
		command jq "$@"
	}
	hub_kubectl() {
		[ ! -f /dev/stdin ] || echo "kubectl $1" >>"$BATS_TEST_TMPDIR/files"
		case $* in
		"-n flux-system create secret generic kubeconfig-storage --from-file=value=/dev/stdin --dry-run=client -o json")
			base64 -w0 | command jq -R '{apiVersion: "v1", kind: "Secret", metadata: {name: "kubeconfig-storage", namespace: "flux-system"}, data: {value: .}}' ;;
		"apply --server-side --force-conflicts --field-manager=sandbox -f -") cat >"$BATS_TEST_TMPDIR/applied.json" ;;
		*) return 1 ;;
		esac
	}
	run ensure_kubeconfig_secret storage
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/files" ]
	[ "$(jq -r '.data.value | @base64d' "$BATS_TEST_TMPDIR/applied.json")" = "$(kind)" ]
}

@test "ensure_kubeconfig_secret fails with the last line of kubectl when it cannot write the Secret" {
	kind() { echo 'apiVersion: v1'; }
	hub_kubectl() {
		case $1 in
		-n) echo '{"kind": "Secret"}' ;;
		apply) printf 'Warning: x\nError from server (Forbidden): secrets is forbidden\n' >&2; return 1 ;;
		esac
	}
	run ensure_kubeconfig_secret storage
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot write the Secret flux-system/kubeconfig-storage on sandbox-management: Error from server (Forbidden): secrets is forbidden" ]
}

@test "attached_roles leaves out a missing cluster and one on another Docker network" {
	export SANDBOX_PROFILE_CLUSTERS="management storage compute"
	kind() {
		case $* in
		"get clusters") printf '%s\n' sandbox-management sandbox-storage other ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		"get nodes --name sandbox-storage") echo sandbox-storage-control-plane ;;
		*) return 1 ;;
		esac
	}
	docker() {
		case ${!#} in
		sandbox-management-control-plane) echo 'cobaltcore-sandbox ' ;;
		sandbox-storage-control-plane) echo 'kind ' ;;
		*) return 1 ;;
		esac
	}
	run attached_roles
	[ "$status" -eq 0 ]
	[ "$output" = management ]
}

@test "sandbox_cluster ends the script when it cannot tell the network of a cluster" {
	kind() {
		case $* in
		"get clusters") echo sandbox-storage ;;
		*) return 1 ;;
		esac
	}
	run sandbox_cluster storage
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot list the nodes of kind cluster sandbox-storage" ]
}

@test "hub_sync writes no Secret for management and counts the module stages of the attached clusters" {
	scaffold_attached
	attached_roles() { echo "management storage"; }
	ensure_flux() { echo ensure_flux >>"$BATS_TEST_TMPDIR/steps"; }
	ensure_cluster_vars() { echo ensure_cluster_vars >>"$BATS_TEST_TMPDIR/steps"; }
	ensure_kubeconfig_secret() { echo "ensure_kubeconfig_secret $1" >>"$BATS_TEST_TMPDIR/steps"; }
	ensure_source() { echo ensure_source >>"$BATS_TEST_TMPDIR/steps"; }
	ensure_root() { echo "ensure_root $1" >>"$BATS_TEST_TMPDIR/steps"; }
	wait_stages() { echo wait_stages >>"$BATS_TEST_TMPDIR/steps"; }
	run hub_sync
	[ "$status" -eq 0 ]
	[ "$(<"$BATS_TEST_TMPDIR/steps")" = "ensure_flux
ensure_cluster_vars
ensure_kubeconfig_secret storage
ensure_source
ensure_root management
ensure_root storage
wait_stages" ]
	[[ ${lines[-1]} == *": 2 stages Ready on 2 clusters at latest@sha256:new" ]]
}

@test "hub_sync stops before Flux when a stage depends on a stage of a cluster that is not attached" {
	mkdir -- "$BATS_TEST_TMPDIR/tree"
	cp -R -- "$SANDBOX_ROOT/clusters" "$SANDBOX_ROOT/profiles" "$BATS_TEST_TMPDIR/tree/"
	SANDBOX_ROOT=$BATS_TEST_TMPDIR/tree
	yq -i '.spec.dependsOn = [{"name": "storage-test"}]' "$SANDBOX_ROOT/clusters/compute/test/stage.yaml"
	scaffold_attached
	attached_roles() { echo "management compute"; }
	ensure_flux() { echo "unit test called ensure_flux" >&2; return 1; }
	run hub_sync
	[ "$status" -eq 1 ]
	[ "$output" = "error: the stage compute-test depends on storage-test, but sandbox-storage is not part of the sandbox; run make up-storage first" ]
}

# push_host <kind clusters>: copies scripts/ into the test's directory with a
# kubeconfig file for management and a checkout of upstream, and exports
# docker, kind and flux for a running registry at 172.30.0.2, the kind
# clusters given, every node on the sandbox network and a push that answers
# with a digest.
push_host() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	vendor_checkout
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig"
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	export CLUSTERS=$1 DIGEST
	docker() {
		case $* in
		"ps -a --format {{.Names}}") echo sandbox-registry ;;
		"container inspect -f {{.State.Running}} sandbox-registry") echo true ;;
		"inspect -f "*" sandbox-registry") echo 172.30.0.2 ;;
		*) echo 'cobaltcore-sandbox ' ;;
		esac
	}
	kind() {
		case $* in
		"get clusters") [ -z "$CLUSTERS" ] || echo "$CLUSTERS" ;;
		"get nodes --name "*) echo "$4-control-plane" ;;
		*) return 1 ;;
		esac
	}
	flux() { echo "{\"digest\": \"sha256:$DIGEST\"}"; }
	export -f docker kind flux
}

@test "push.sh without a management cluster pushes and says that nothing follows the tag" {
	push_host ""
	run "$BATS_TEST_TMPDIR/scripts/push.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "push: nothing follows the tag yet, run make up" ]
}

@test "push.sh without the Flux CRDs on sandbox-management says that nothing follows the tag" {
	push_host sandbox-management
	kubectl() { :; }
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/push.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "push: nothing follows the tag yet, run make up" ]
}

@test "push.sh without the source on sandbox-management says that nothing follows the tag" {
	push_host sandbox-management
	kubectl() {
		case $* in
		*" get crd ocirepositories.source.toolkit.fluxcd.io "*) echo '{"kind": "CustomResourceDefinition"}' ;;
		*" -n flux-system get ocirepositories.source.toolkit.fluxcd.io sandbox "*) ;;
		*) return 1 ;;
		esac
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/push.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "push: nothing follows the tag yet, run make up" ]
}

@test "push.sh asks Flux on sandbox-management to fetch the pushed revision and records upstream" {
	push_host sandbox-management
	export ANNOTATE=$BATS_TEST_TMPDIR/annotate
	kubectl() {
		case $* in
		*" annotate --overwrite ocirepositories.source.toolkit.fluxcd.io sandbox reconcile.fluxcd.io/requestedAt="*) printf '%s\n' "$*" >"$ANNOTATE" ;;
		*" get "*) echo '{"kind": "found"}' ;;
		*) return 1 ;;
		esac
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/push.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "push: asked Flux on sandbox-management to fetch latest@sha256:$DIGEST" ]
	[[ $(<"$ANNOTATE") == *" -n flux-system annotate --overwrite ocirepositories.source.toolkit.fluxcd.io sandbox reconcile.fluxcd.io/requestedAt="?*" sandbox.c5c3.io/upstream=$UPSTREAM_FIRST" ]]
}

@test "push.sh fails with the last line of kubectl when it cannot reach sandbox-management" {
	push_host sandbox-management
	kubectl() {
		printf 'E1124 memcache.go\nThe connection to the server 127.0.0.1:40001 was refused\n' >&2
		return 1
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/push.sh"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot ask Flux to fetch the artifact: The connection to the server 127.0.0.1:40001 was refused" ]
}
