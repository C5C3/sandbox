#!/usr/bin/env bats
# scripts/lib/hub.sh: Flux on sandbox-management, with kubectl, helm, kind,
# docker and flux replaced by functions.

setup() {
	load helpers
	DIGEST=$(printf 'a%.0s' {1..64})
}

# registry_runs: replaces docker with a function that lists sandbox-registry
# as a running container at 172.30.0.2.
registry_runs() {
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
