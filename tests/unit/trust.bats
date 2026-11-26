#!/usr/bin/env bats
# scripts/lib/trust.sh: the copy of the sandbox CA into the ConfigMap
# flux-system/sandbox-trust, with kubectl replaced by a function that records
# each call in calls.

setup() {
	load helpers
	KC=$(kubeconfig_path management)
	export CALLS=$BATS_TEST_TMPDIR/calls KC
	# tls.crt as the API server serves it: base64 of the PEM.
	CA_B64=$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBsandbox\n-----END CERTIFICATE-----\n' | base64 -w 0)
	export CA_B64
}

# attached <modules of compute>: loads a profile with the management and the
# compute cluster and the modules given for compute, both attached.
attached() {
	profile_with "clusters: [management, compute]
modules:
  management: [crds, controllers, pki]
  compute: [$1]"
	profile_load
	attached_roles() { echo "management compute"; }
}

# hub_answers: replaces kubectl with a function that answers the calls of
# ensure_trust on sandbox-management and writes each applied manifest to
# applied.json. SECRET says what the Secret cert-manager/sandbox-ca holds:
# ca, the CA in tls.crt; empty, an empty tls.crt; absent, nothing.
# READ_ERROR makes the read fail with that line, APPLY_ERROR the apply.
hub_answers() {
	kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		case $* in
		"--kubeconfig $KC -n cert-manager get secret sandbox-ca --ignore-not-found -o json")
			if [ -n "${READ_ERROR:-}" ]; then
				printf 'E1126 memcache.go\n%s\n' "$READ_ERROR" >&2
				return 1
			fi
			case $SECRET in
			ca) jq -n --arg ca "$CA_B64" '{apiVersion: "v1", kind: "Secret", data: {"tls.crt": $ca, "tls.key": "a2V5"}}' ;;
			empty) jq -n '{apiVersion: "v1", kind: "Secret", data: {"tls.crt": ""}}' ;;
			absent) : ;;
			esac
			;;
		"--kubeconfig $KC apply --server-side --force-conflicts --field-manager=sandbox -f -")
			cat >"$BATS_TEST_TMPDIR/applied.json"
			if [ -n "${APPLY_ERROR:-}" ]; then
				printf 'Warning: x\n%s\n' "$APPLY_ERROR" >&2
				return 1
			fi
			echo 'configmap/sandbox-trust serverside-applied'
			;;
		*) return 1 ;;
		esac
	}
}

@test "ensure_trust calls no kubectl for a profile without trust, or while sandbox-compute is not attached" {
	hub_answers
	export SECRET=ca
	attached access
	run ensure_trust
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$CALLS" ]

	attached "access, trust"
	attached_roles() { echo management; }
	run ensure_trust
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$CALLS" ]
}

@test "ensure_trust applies the ConfigMap flux-system/sandbox-trust with the label of the watch and the tls.crt of the sandbox CA" {
	hub_answers
	export SECRET=ca
	attached "access, trust"
	run ensure_trust
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
	[[ ${lines[0]} == *": waiting for the sandbox CA of sandbox-management" ]]
	[[ ${lines[1]} == *": writing the ConfigMap flux-system/sandbox-trust" ]]
	[ "$(grep -c ' apply ' "$CALLS")" -eq 1 ]
	[ "$(jq -c '[.apiVersion, .kind, .metadata]' "$BATS_TEST_TMPDIR/applied.json")" = \
		'["v1","ConfigMap",{"name":"sandbox-trust","namespace":"flux-system","labels":{"reconcile.fluxcd.io/watch":"Enabled"}}]' ]
	[ "$(jq -c '.data | keys' "$BATS_TEST_TMPDIR/applied.json")" = '["SANDBOX_CA_B64"]' ]
	[ "$(jq -r '.data.SANDBOX_CA_B64' "$BATS_TEST_TMPDIR/applied.json")" = "$CA_B64" ]
}

@test "ensure_trust gives up after SANDBOX_STAGE_TIMEOUT when the Secret is absent or its tls.crt empty, and applies nothing" {
	local secret
	hub_answers
	attached "access, trust"
	export SANDBOX_STAGE_TIMEOUT=1
	for secret in absent empty; do
		export SECRET=$secret
		run ensure_trust
		echo "$secret: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "error: trust: the Secret cert-manager/sandbox-ca on sandbox-management holds no tls.crt after 1 s; make status shows the stage management-pki" ]
		! grep -q ' apply ' "$CALLS"
	done
}

@test "ensure_trust names the last line of kubectl when the last read of the Secret failed" {
	hub_answers
	attached "access, trust"
	export SANDBOX_STAGE_TIMEOUT=1 SECRET=ca READ_ERROR='Unable to connect to the server: dial tcp 127.0.0.1:41234: connect: connection refused'
	run ensure_trust
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: trust: the Secret cert-manager/sandbox-ca on sandbox-management holds no tls.crt after 1 s; make status shows the stage management-pki; kubectl: Unable to connect to the server: dial tcp 127.0.0.1:41234: connect: connection refused" ]
}

@test "ensure_trust names the last line of kubectl when it cannot write the ConfigMap" {
	hub_answers
	attached "access, trust"
	export SECRET=ca APPLY_ERROR='Error from server (Forbidden): configmaps "sandbox-trust" is forbidden'
	run ensure_trust
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot write the ConfigMap flux-system/sandbox-trust on sandbox-management: Error from server (Forbidden): configmaps \"sandbox-trust\" is forbidden" ]
}

@test "ensure_trust refuses a SANDBOX_STAGE_TIMEOUT below 1 before it calls kubectl" {
	hub_answers
	attached "access, trust"
	export SECRET=ca SANDBOX_STAGE_TIMEOUT=0
	run ensure_trust
	[ "$status" -eq 1 ]
	[ "$output" = "error: SANDBOX_STAGE_TIMEOUT must be an integer of 1 or more, got '0'" ]
	[ ! -e "$CALLS" ]
}
