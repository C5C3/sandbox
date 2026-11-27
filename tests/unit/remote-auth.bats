#!/usr/bin/env bats
# scripts/lib/remote-auth.sh: the API servers and CAs of the remote clusters
# in the ConfigMap flux-system/openbao-remote-auth and the copies of their
# OpenBao client certificates in flux-system, with kubectl, kind and jq
# replaced by functions that record each call in calls. The jq function runs
# the real jq.

setup() {
	load helpers
	KC=$(kubeconfig_path management)
	export CALLS=$BATS_TEST_TMPDIR/calls APPLIED=$BATS_TEST_TMPDIR/applied KC
	mkdir -- "$APPLIED"
	# The three keys of each client Secret as the API server serves them:
	# base64 of the PEM.
	for role in storage compute; do
		printf -v "CRT_${role^^}" '%s' "$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBclient%s\n-----END CERTIFICATE-----\n' "$role" | base64 -w 0)"
		printf -v "KEY_${role^^}" '%s' "$(printf -- '-----BEGIN PRIVATE KEY-----\nMIIEsecret%s\n-----END PRIVATE KEY-----\n' "$role" | base64 -w 0)"
		printf -v "API_CA_${role^^}" '%s' "$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBapi%s\n-----END CERTIFICATE-----\n' "$role" | base64 -w 0)"
	done
	OPENBAO_CA=$(printf -- '-----BEGIN CERTIFICATE-----\nMIIBopenbaoca\n-----END CERTIFICATE-----\n' | base64 -w 0)
	export CRT_STORAGE KEY_STORAGE API_CA_STORAGE CRT_COMPUTE KEY_COMPUTE API_CA_COMPUTE OPENBAO_CA
	export SECRET=complete
	unset READ_ERROR APPLY_ERROR APPLY_FAIL KIND_ERROR NO_CA DELETED DELETE_ERROR
}

# attached <modules of management> <attached roles>: loads a profile with
# all three clusters and the modules given for management, and attaches the
# roles given.
attached() {
	profile_with "clusters: [management, storage, compute]
modules:
  management: [$1]"
	profile_load
	export ATTACHED=$2
	attached_roles() { echo "$ATTACHED"; }
}

WITH_MODULE="crds, controllers, loadbalancer, pki, openbao, openbao-remote-auth"
WITHOUT_MODULE="crds, controllers, loadbalancer, pki, openbao"

# hub_answers: replaces kind, kubectl and jq with functions that record each
# call and answer those of ensure_remote_auth. kind prints the internal
# kubeconfig of storage or compute, with the admin's key; KIND_ERROR makes
# it fail, NO_CA leaves out certificate-authority-data. kubectl answers the
# delete by label with DELETED, or fails with DELETE_ERROR; it answers the
# read of shared-services/openbao-client-<role> after SECRET: complete,
# absent, empty-key or no-ca, or fails with READ_ERROR; and it writes each
# applied manifest to applied/<n>.json and fails with APPLY_ERROR when the
# manifest's kind/name is APPLY_FAIL.
hub_answers() {
	kind() {
		printf 'kind %s\n' "$*" >>"$CALLS"
		case $* in
		"get kubeconfig --internal --name sandbox-storage" | "get kubeconfig --internal --name sandbox-compute")
			[ -z "${KIND_ERROR:-}" ] || {
				echo "$KIND_ERROR" >&2
				return 1
			}
			local args="$*" role ca
			role=${args##*-}
			ca=API_CA_${role^^}
			printf 'apiVersion: v1\nkind: Config\nclusters:\n  - name: kind-sandbox-%s\n    cluster:\n      server: https://sandbox-%s-control-plane:6443\n' "$role" "$role"
			if [ -z "${NO_CA:-}" ]; then
				printf '      certificate-authority-data: %s\n' "${!ca}"
			fi
			printf 'users:\n  - name: kind-sandbox-%s\n    user:\n      client-key-data: QURNSU4tS0VZ\n' "$role"
			;;
		*) return 1 ;;
		esac
	}
	kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		local args="$*" role crt key
		case $args in
		"--kubeconfig $KC -n flux-system delete secret -l sandbox.c5c3.io/openbao-client --ignore-not-found -o name")
			if [ -n "${DELETE_ERROR:-}" ]; then
				printf 'E1127 memcache.go\n%s\n' "$DELETE_ERROR" >&2
				return 1
			fi
			printf '%s' "${DELETED:-}"
			;;
		"--kubeconfig $KC -n shared-services get secret openbao-client-"*" --ignore-not-found -o json")
			if [ -n "${READ_ERROR:-}" ]; then
				printf 'E1127 memcache.go\n%s\n' "$READ_ERROR" >&2
				return 1
			fi
			role=${args#*openbao-client-}
			role=${role%% *}
			crt=CRT_${role^^} key=KEY_${role^^}
			case $SECRET in
			complete) command jq -n --arg crt "${!crt}" --arg key "${!key}" --arg ca "$OPENBAO_CA" \
				'{apiVersion: "v1", kind: "Secret", type: "kubernetes.io/tls", data: {"tls.crt": $crt, "tls.key": $key, "ca.crt": $ca}}' ;;
			empty-key) command jq -n --arg crt "${!crt}" --arg ca "$OPENBAO_CA" \
				'{apiVersion: "v1", kind: "Secret", data: {"tls.crt": $crt, "tls.key": "", "ca.crt": $ca}}' ;;
			no-ca) command jq -n --arg crt "${!crt}" --arg key "${!key}" \
				'{apiVersion: "v1", kind: "Secret", data: {"tls.crt": $crt, "tls.key": $key}}' ;;
			absent) : ;;
			esac
			;;
		"--kubeconfig $KC apply --server-side --force-conflicts --field-manager=sandbox -f -")
			local file
			file=$APPLIED/$(($(find "$APPLIED" -type f | wc -l) + 1)).json
			cat >"$file"
			if [ -n "${APPLY_FAIL:-}" ] && [ "$(command jq -r '.kind + "/" + .metadata.name' "$file")" = "$APPLY_FAIL" ]; then
				printf 'Warning: x\n%s\n' "$APPLY_ERROR" >&2
				return 1
			fi
			echo "applied serverside"
			;;
		*) return 1 ;;
		esac
	}
	jq() {
		printf 'jq %s\n' "$*" >>"$CALLS"
		command jq "$@"
	}
}

# applied <n>: prints the manifest of the nth apply.
applied() {
	cat -- "$APPLIED/$1.json"
}

@test "with storage and compute attached ensure_remote_auth applies the ConfigMap with the API server and CA of each, then the two client Secrets, and logs five lines in order" {
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	run ensure_remote_auth
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 5 ]
	[[ ${lines[0]} == *": writing the ConfigMap flux-system/openbao-remote-auth for sandbox-storage and sandbox-compute" ]]
	[[ ${lines[1]} == *": waiting for the OpenBao client certificate of sandbox-storage" ]]
	[[ ${lines[2]} == *": writing the Secret flux-system/openbao-client-storage" ]]
	[[ ${lines[3]} == *": waiting for the OpenBao client certificate of sandbox-compute" ]]
	[[ ${lines[4]} == *": writing the Secret flux-system/openbao-client-compute" ]]
	[ "$(find "$APPLIED" -type f | wc -l)" -eq 3 ]
	[ "$(applied 1 | command jq -c '[.apiVersion, .kind, .metadata]')" = \
		'["v1","ConfigMap",{"name":"openbao-remote-auth","namespace":"flux-system","labels":{"reconcile.fluxcd.io/watch":"Enabled"}}]' ]
	[ "$(applied 1 | command jq -c '.data')" = \
		"{\"STORAGE_API_SERVER\":\"https://sandbox-storage-control-plane:6443\",\"STORAGE_API_CA_B64\":\"$API_CA_STORAGE\",\"COMPUTE_API_SERVER\":\"https://sandbox-compute-control-plane:6443\",\"COMPUTE_API_CA_B64\":\"$API_CA_COMPUTE\"}" ]
	for n in 2 3; do
		role=$( ((n == 2)) && echo storage || echo compute)
		crt=CRT_${role^^} key=KEY_${role^^}
		[ "$(applied "$n" | command jq -c '[.apiVersion, .kind, .metadata, (.stringData | keys), has("data")]')" = \
			"[\"v1\",\"Secret\",{\"name\":\"openbao-client-$role\",\"namespace\":\"flux-system\",\"labels\":{\"reconcile.fluxcd.io/watch\":\"Enabled\",\"sandbox.c5c3.io/openbao-client\":\"$role\"}},[\"OPENBAO_CA_B64\",\"OPENBAO_CLIENT_CRT_B64\",\"OPENBAO_CLIENT_KEY_B64\"],false]" ]
		[ "$(applied "$n" | command jq -r '.stringData.OPENBAO_CLIENT_CRT_B64')" = "${!crt}" ]
		[ "$(applied "$n" | command jq -r '.stringData.OPENBAO_CLIENT_KEY_B64')" = "${!key}" ]
		[ "$(applied "$n" | command jq -r '.stringData.OPENBAO_CA_B64')" = "$OPENBAO_CA" ]
	done
}

@test "the client key reaches no argument of kubectl, kind or jq" {
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	run ensure_remote_auth
	[ "$status" -eq 0 ]
	grep -q '^jq ' "$CALLS"
	grep -q '^kind ' "$CALLS"
	! grep -qF -e "$KEY_STORAGE" -e "$KEY_COMPUTE" -e MIIEsecret -e QURNSU4tS0VZ "$CALLS"
}

@test "with only management attached ensure_remote_auth applies the ConfigMap without data and reads and applies no Secret" {
	hub_answers
	attached "$WITH_MODULE" management
	run ensure_remote_auth
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": writing the ConfigMap flux-system/openbao-remote-auth for no remote cluster" ]]
	[ "$(find "$APPLIED" -type f | wc -l)" -eq 1 ]
	[ "$(applied 1 | command jq -c '[.kind, .metadata.name, .data]')" = '["ConfigMap","openbao-remote-auth",{}]' ]
	! grep -q ' get secret ' "$CALLS"
	! grep -q '^kind ' "$CALLS"
}

@test "without the module ensure_remote_auth makes exactly one call, the delete by label in flux-system, and logs only a removal" {
	hub_answers
	attached "$WITHOUT_MODULE" "management storage compute"
	export DELETED=$'secret/openbao-client-storage\nsecret/openbao-client-compute\n'
	run ensure_remote_auth
	[ "$status" -eq 0 ]
	[[ $output == *": removed the OpenBao client certificates of the hub" ]]
	[ "${#lines[@]}" -eq 1 ]
	[ "$(<"$CALLS")" = "kubectl --kubeconfig $KC -n flux-system delete secret -l sandbox.c5c3.io/openbao-client --ignore-not-found -o name" ]

	rm -f -- "$CALLS"
	export DELETED=''
	run ensure_remote_auth
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(grep -c '' "$CALLS")" -eq 1 ]
}

@test "without the module a failed delete names the last line of kubectl" {
	hub_answers
	attached "$WITHOUT_MODULE" "management storage compute"
	export DELETE_ERROR='Error from server (Forbidden): secrets is forbidden'
	run ensure_remote_auth
	[ "$status" -eq 1 ]
	[ "$output" = "error: openbao-remote-auth: cannot remove the OpenBao client certificates of the hub: Error from server (Forbidden): secrets is forbidden" ]
}

@test "ensure_remote_auth gives up after SANDBOX_STAGE_TIMEOUT on an absent Secret, an empty tls.key or a missing ca.crt, names the first missing key and applies no Secret" {
	local secret key
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	export SANDBOX_STAGE_TIMEOUT=1
	while read -r secret key; do
		rm -f -- "$APPLIED"/*.json
		export SECRET=$secret
		run ensure_remote_auth
		echo "$secret: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "error: openbao-remote-auth: the Secret shared-services/openbao-client-storage on sandbox-management holds no $key after 1 s; make status shows the stage management-openbao-remote-auth" ]
		[ "$(find "$APPLIED" -type f | wc -l)" -eq 1 ]
		[ "$(applied 1 | command jq -r '.kind')" = ConfigMap ]
	done <<'EOF'
absent tls.crt
empty-key tls.key
no-ca ca.crt
EOF
}

@test "ensure_remote_auth names the last line of kubectl when the last read of the Secret failed" {
	hub_answers
	attached "$WITH_MODULE" "management storage"
	export SANDBOX_STAGE_TIMEOUT=1 READ_ERROR='Unable to connect to the server: dial tcp 127.0.0.1:41234: connect: connection refused'
	run ensure_remote_auth
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: openbao-remote-auth: the Secret shared-services/openbao-client-storage on sandbox-management holds no tls.crt after 1 s; make status shows the stage management-openbao-remote-auth; kubectl: Unable to connect to the server: dial tcp 127.0.0.1:41234: connect: connection refused" ]
}

@test "a failing kind and a kubeconfig without a CA stop ensure_remote_auth before any apply" {
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	export KIND_ERROR='ERROR: could not locate any control plane nodes for cluster named sandbox-storage'
	run ensure_remote_auth
	[ "$status" -eq 1 ]
	[ "$output" = "error: openbao-remote-auth: cannot read the internal kubeconfig of sandbox-storage" ]
	[ "$(find "$APPLIED" -type f | wc -l)" -eq 0 ]

	unset KIND_ERROR
	export NO_CA=1
	run ensure_remote_auth
	[ "$status" -eq 1 ]
	[ "$output" = "error: openbao-remote-auth: the internal kubeconfig of sandbox-storage names no server or no CA" ]
	[ "$(find "$APPLIED" -type f | wc -l)" -eq 0 ]
}

@test "ensure_remote_auth names the last line of kubectl when it cannot write the ConfigMap or a Secret" {
	local fail message
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	export APPLY_ERROR='Error from server (Forbidden): the object is forbidden'
	while read -r fail message; do
		rm -f -- "$APPLIED"/*.json
		export APPLY_FAIL=$fail
		run ensure_remote_auth
		echo "$fail: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "error: cannot write the $message on sandbox-management: $APPLY_ERROR" ]
	done <<'EOF'
ConfigMap/openbao-remote-auth ConfigMap flux-system/openbao-remote-auth
Secret/openbao-client-compute Secret flux-system/openbao-client-compute
EOF
}

@test "ensure_remote_auth refuses a SANDBOX_STAGE_TIMEOUT below 1 before any call" {
	hub_answers
	attached "$WITH_MODULE" "management storage compute"
	export SANDBOX_STAGE_TIMEOUT=0
	run ensure_remote_auth
	[ "$status" -eq 1 ]
	[ "$output" = "error: SANDBOX_STAGE_TIMEOUT must be an integer of 1 or more, got '0'" ]
	[ ! -e "$CALLS" ]
}
