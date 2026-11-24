#!/usr/bin/env bats
# make status: scripts/lib/status.jq on lists written here, and
# scripts/status.sh with docker, kind and kubectl replaced by exported
# functions. The script runs from a copy of scripts/, so the .sandbox it
# reads is the copy's and not the repository's.

setup() {
	load helpers
}

# rows_of <list> <clusters>: runs status.jq on the list with the existing
# clusters.
rows_of() {
	run jq -r --arg clusters "$2" -f "$SANDBOX_ROOT/scripts/lib/status.jq" <<<"$1"
}

# object <kind> <name> <status> <message> [<role>]: prints a Flux object
# with the Ready condition and the label of the role.
object() {
	jq -n --arg kind "$1" --arg name "$2" --arg status "$3" --arg message "$4" --arg role "${5:-}" '
		{kind: $kind, metadata: ({name: $name} + if $role == "" then {} else {labels: {"sandbox.c5c3.io/cluster": $role}} end),
		 status: {conditions: [{type: "Reconciling", status: "False", message: "other"}, {type: "Ready", status: $status, message: $message}]}}'
}

# hub_objects: prints the FluxInstance, the OCIRepository, three roots and
# three stages, out of order.
hub_objects() {
	object Kustomization storage-test True "Applied revision: s" storage
	object Kustomization cluster-compute True "Applied revision: c" compute
	object OCIRepository sandbox True "stored artifact"
	object Kustomization management-test True "Applied revision: m" management
	object Kustomization cluster-management True "Applied revision: m" management
	object Kustomization compute-test True "Applied revision: c" compute
	object FluxInstance flux True "Reconciliation finished"
	object Kustomization cluster-storage True "Applied revision: s" storage
}

@test "status.jq prints the FluxInstance and the source, then the root and the stages of each cluster" {
	rows_of "$(hub_objects | jq -s '{items: .}')" "management storage compute"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\t%s\t%s\t%s\n' \
		management FluxInstance/flux True "Reconciliation finished" \
		management OCIRepository/sandbox True "stored artifact" \
		management Kustomization/cluster-management True "Applied revision: m" \
		management Kustomization/management-test True "Applied revision: m" \
		storage Kustomization/cluster-storage True "Applied revision: s" \
		storage Kustomization/storage-test True "Applied revision: s" \
		compute Kustomization/cluster-compute True "Applied revision: c" \
		compute Kustomization/compute-test True "Applied revision: c")" ]
}

@test "status.jq prints no row for an empty list" {
	rows_of '{"items": []}' ""
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "status.jq prints Unknown for an object without a Ready condition and the first line of a message" {
	rows_of "{\"items\": [{\"kind\": \"FluxInstance\", \"metadata\": {\"name\": \"flux\"}}, $(object OCIRepository sandbox False $'failed to pull\nsecond line')]}" ""
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf 'management\tFluxInstance/flux\tUnknown\tno Ready condition\nmanagement\tOCIRepository/sandbox\tFalse\tfailed to pull')" ]
}

@test "status.jq keeps the quotes and backslashes of a message and turns a tab into a space" {
	rows_of "{\"items\": [$(object OCIRepository sandbox False $'json: cannot unmarshal \\"value\\"\tinto struct')]}" ""
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf 'management\tOCIRepository/sandbox\tFalse\t%s' 'json: cannot unmarshal \"value\" into struct')" ]
}

@test "status.jq prints an existing cluster without a root as not attached" {
	rows_of "$(object Kustomization cluster-management True ok management | jq -s '{items: .}')" "management compute"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf 'management\tKustomization/cluster-management\tTrue\tok\ncompute\t-\t-\tnot attached to the hub, run make up-compute')" ]
}

@test "status.jq prints a Kustomization of no cluster last" {
	rows_of "$( (object Kustomization extra False broken; object Kustomization cluster-storage True ok storage) | jq -s '{items: .}')" "storage"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf 'storage\tKustomization/cluster-storage\tTrue\tok\n-\tKustomization/extra\tFalse\tbroken')" ]
}

# A copy of scripts/ with a kubeconfig file for management, and docker and
# kind answering for a sandbox-management on the sandbox network. Each test
# exports a kubectl.
status_host() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig"
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	kind() {
		case $* in
		"get clusters") echo sandbox-management ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		*) return 1 ;;
		esac
	}
	docker() { echo 'cobaltcore-sandbox '; }
	export -f kind docker
}

@test "status.sh reports a missing management cluster and exits 0" {
	status_host
	kind() { [ "$*" = "get clusters" ]; }
	export -f kind
	run "$BATS_TEST_TMPDIR/scripts/status.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "status: sandbox-management does not exist" ]
}

@test "status.sh exits 1 with the last line of kubectl when it cannot read the hub" {
	status_host
	kubectl() {
		printf 'E1124 memcache.go\nThe connection to the server 127.0.0.1:40001 was refused\n' >&2
		return 1
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/status.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "error: status: cannot read the Flux objects of sandbox-management: The connection to the server 127.0.0.1:40001 was refused" ]
}

@test "status.sh reports Flux as not installed when a CRD of Flux is missing" {
	status_host
	for crds in "" "customresourcedefinition.apiextensions.k8s.io/fluxinstances.fluxcd.controlplane.io"; do
		export CRDS=$crds
		kubectl() { [ -z "$CRDS" ] || echo "$CRDS"; }
		export -f kubectl
		run "$BATS_TEST_TMPDIR/scripts/status.sh"
		[ "$status" -eq 0 ]
		[ "$output" = "status: Flux is not installed on sandbox-management, run make up-management" ]
	done
}

@test "status.sh prints a row per object and counts the ready ones" {
	status_host
	(object FluxInstance flux True done; object OCIRepository sandbox True stored
		object Kustomization cluster-management False "kustomize build failed" management) |
		jq -s '{kind: "List", items: .}' >"$BATS_TEST_TMPDIR/objects.json"
	kubectl() {
		case $* in
		*" get crd "*) printf 'customresourcedefinition.apiextensions.k8s.io/%s\n' a b c ;;
		*" -n flux-system get "*) cat "$BATS_TEST_TMPDIR/objects.json" ;;
		*) return 1 ;;
		esac
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/status.sh"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "${lines[@]}" | tr -s ' ')" = "CLUSTER OBJECT READY MESSAGE
management FluxInstance/flux True done
management OCIRepository/sandbox True stored
management Kustomization/cluster-management False kustomize build failed
status: 2 of 3 ready" ]
}

@test "status.sh counts no row of a cluster that is not attached" {
	status_host
	echo '{"kind": "List", "items": []}' >"$BATS_TEST_TMPDIR/objects.json"
	kubectl() {
		case $* in
		*" get crd "*) printf 'customresourcedefinition.apiextensions.k8s.io/%s\n' a b c ;;
		*" -n flux-system get "*) cat "$BATS_TEST_TMPDIR/objects.json" ;;
		*) return 1 ;;
		esac
	}
	export -f kubectl
	run "$BATS_TEST_TMPDIR/scripts/status.sh"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "${lines[@]}" | tr -s ' ')" = "CLUSTER OBJECT READY MESSAGE
management - - not attached to the hub, run make up-management
status: 0 of 0 ready" ]
}
