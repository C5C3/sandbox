#!/usr/bin/env bats
# The profile platform against a real Docker: the shared OpenBao, initialised,
# unsealed and configured by the Job openbao-bootstrap, the ClusterSecretStore
# and the ExternalSecrets that read it, Garage, the c5c3-operator and the
# SizingProfile sandbox on sandbox-management, and the recovery after a
# restart of the OpenBao pod that the README names. It needs a host that
# passes the host check for the management role, refuses to start while a
# sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
SERVICE_OPERATORS=(keystone horizon glance placement barbican ovn neutron cinder nova)

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# sandbox_exists: succeeds when any object of a sandbox exists on the host.
sandbox_exists() {
	docker network inspect cobaltcore-sandbox >/dev/null 2>&1 ||
		[ -n "$(docker ps -aq --filter label=cobaltcore-sandbox=true)" ] ||
		kind get clusters | grep -qxE 'sandbox-(management|storage|compute)' ||
		[ -e "$ROOT/.sandbox" ]
}

# eventually <seconds> <command>...: runs the command every 2 s until it
# succeeds, for at most the seconds given.
eventually() {
	local deadline=$((SECONDS + $1))
	shift
	until "$@"; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			return 1
		fi
		sleep 2
	done
}

# kc <role> <argument>...: runs kubectl against the role's cluster.
kc() {
	kubectl --kubeconfig "$KUBECONFIG_DIR/$1.yaml" "${@:2}"
}

# bao_status: prints the JSON of bao status in openbao-0, run with the
# environment the Job openbao-bootstrap uses. A sealed server exits 2, which
# counts as an answer.
bao_status() {
	kc management -n shared-services exec openbao-0 -- env BAO_ADDR=https://127.0.0.1:8200 \
		VAULT_CACERT=/openbao/tls/ca.crt VAULT_CLIENT_CERT=/openbao/client-tls/tls.crt \
		VAULT_CLIENT_KEY=/openbao/client-tls/tls.key bao status -format=json 2>/dev/null || [ "$?" -eq 2 ]
}

# sealed <true|false>: succeeds when bao status reports sealed as the value.
sealed() {
	local out
	out=$(bao_status) || return 1
	[ "$(jq -r .sealed <<<"$out")" = "$1" ]
}

# store_ready: prints the status of the condition Ready of the
# ClusterSecretStore openbao-cluster-store.
store_ready() {
	kc management get clustersecretstores.external-secrets.io openbao-cluster-store \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# bootstrapped: the Job openbao-bootstrap has succeeded, OpenBao is unsealed
# and the store is Ready.
bootstrapped() {
	[ "$(kc management -n shared-services get job openbao-bootstrap -o jsonpath='{.status.succeeded}' 2>/dev/null)" = 1 ] &&
		sealed false &&
		[ "$(store_ready)" = True ]
}

# dry_run <profile>: applies the fixture ControlPlane with --dry-run=server,
# with sizing.profileRef.name set to the profile.
dry_run() {
	PROFILE=$1 yq '.spec.sizing.profileRef.name = strenv(PROFILE)' "$BATS_TEST_DIRNAME/fixtures/controlplane-dry-run.yaml" |
		kc management apply --dry-run=server -f -
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=platform brings nine stages Ready on the management cluster alone" {
	SANDBOX_STAGE_TIMEOUT=1800 run sb_make up PROFILE=platform
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 9\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-1]} == "export KUBECONFIG="* ]]
	[ "$(kind get clusters 2>/dev/null | grep -cxE 'sandbox-(storage|compute)')" = 0 ]
}

@test "OpenBao runs one replica, initialised and unsealed by the Job, and keeps its init output" {
	[ "$(bao_status | jq -c '[.initialized, .sealed]')" = '[true,false]' ]
	[ "$(kc management -n shared-services get statefulset openbao -o jsonpath='{.spec.replicas}')" = 1 ]
	[ "$(kc management -n shared-services get job openbao-bootstrap -o jsonpath='{.status.succeeded}')" = 1 ]
	kc management -n shared-services get secret openbao-init-keys -o json | jq -e '.data["init-output"] | length > 0' >/dev/null
}

@test "the ClusterSecretStore openbao-cluster-store is Ready" {
	[ "$(store_ready)" = True ]
}

@test "the three ExternalSecrets of Garage have synced from OpenBao" {
	local object
	for object in shared-services/garage-admin-token shared-services/garage-s3-credentials openstack/garage-s3-credentials; do
		[ "$(kc management -n "${object%/*}" get externalsecrets.external-secrets.io "${object#*/}" \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}')" = \
			"True SecretSynced" ]
	done
	kc management -n shared-services get secret garage-admin-token -o json | jq -e '.data.token | length > 0' >/dev/null
	for object in shared-services openstack; do
		[[ $(kc management -n "$object" get secret garage-s3-credentials -o jsonpath='{.data.access-key-id}' | base64 -d) == GK* ]]
	done
}

@test "Garage runs one storage node, and the bucket glance-images and the key glance-s3 are Ready" {
	[ "$(kc management -n shared-services get garageclusters.garage.rajsingh.info garage -o jsonpath='{.status.phase} {.spec.storage.replicas}')" = \
		"Running 1" ]
	[ "$(kc management -n shared-services get garagebuckets.garage.rajsingh.info glance-images -o jsonpath='{.status.phase}')" = Ready ]
	[ "$(kc management -n shared-services get garagekeys.garage.rajsingh.info glance-s3 -o jsonpath='{.status.phase}')" = Ready ]
}

@test "the c5c3-operator runs one Ready pod without the keystone-operator, and the service operators stay suspended" {
	local release json
	release=$(kc management -n c5c3-system get helmreleases.helm.toolkit.fluxcd.io c5c3-operator -o json)
	[ "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' <<<"$release")" = True ]
	[ "$(jq '.spec.dependsOn | length' <<<"$release")" -gt 0 ]
	[ "$(jq '[.spec.dependsOn[] | select(.name == "keystone-operator")] | length' <<<"$release")" = 0 ]
	[ "$(kc management -n c5c3-system get pods -o json |
		jq -r '[.items[] | [.status.conditions[]? | select(.type == "Ready")][0].status] | join(" ")')" = True ]

	json=$(kc management get helmreleases.helm.toolkit.fluxcd.io -A -o json)
	[ "$(jq -r '[.items[] | select(.spec.suspend == true) | .metadata.name] | sort | join(" ")' <<<"$json")" = \
		"$(printf '%s-operator\n' "${SERVICE_OPERATORS[@]}" | sort | paste -sd ' ')" ]
	[ -z "$(kc management -n keystone-system get pods -o name)" ]
}

@test "the SizingProfile sandbox has the base Minimal" {
	[ "$(kc management get sizingprofiles.c5c3.io sandbox -o jsonpath='{.spec.base}')" = Minimal ]
}

@test "a ControlPlane that names the SizingProfile sandbox is admitted, one that names none is rejected" {
	run dry_run sandbox
	echo "$output"
	[ "$status" -eq 0 ]
	run dry_run nothere
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *'spec.sizing.profileRef.name: Not found: "nothere"'* ]]
	[ -z "$(kc management get controlplanes.c5c3.io -A -o name)" ]
}

@test "a second make up PROFILE=platform keeps the Job openbao-bootstrap" {
	local uid
	uid=$(kc management -n shared-services get job openbao-bootstrap -o jsonpath='{.metadata.uid}')
	[ -n "$uid" ]
	run sb_make up PROFILE=platform
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 9\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(kc management -n shared-services get job openbao-bootstrap -o jsonpath='{.metadata.uid}')" = "$uid" ]
}

@test "after a restart of openbao-0, deleting the Job and reconciling the stage unseal OpenBao from the kept Secret" {
	local secret pid
	secret=$(kc management -n shared-services get secret openbao-init-keys -o jsonpath='{.metadata.uid}')
	[ -n "$secret" ]
	kc management -n shared-services delete pod openbao-0 >/dev/null
	eventually 300 sealed true

	kc management -n shared-services delete job openbao-bootstrap >/dev/null
	# flux reconcile waits up to 5 minutes for the stage, so the test polls
	# for the outcome instead of reading its exit status. flux runs in the
	# background itself, not in a function's subshell, so that kill stops it.
	flux --kubeconfig "$KUBECONFIG_DIR/management.yaml" -n flux-system reconcile kustomization management-openbao \
		>"$BATS_FILE_TMPDIR/reconcile.log" 2>&1 3>&- &
	pid=$!
	run eventually 300 bootstrapped
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$status" -eq 0 ]
	[ "$(kc management -n shared-services get secret openbao-init-keys -o jsonpath='{.metadata.uid}')" = "$secret" ]
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
