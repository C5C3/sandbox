#!/usr/bin/env bats
# The profile controlplane against a real Docker: the eight services of
# upstream's Quick Start (ControlPlane) with a fake compute and Cinder on
# upstream's NFS export, on the managed message bus, on sandbox-management,
# with the orders of the module orders. It checks the nine service
# operators, the ControlPlane and its bus, the seven example orders and their
# Secrets, the admission of the service sets of the profiles storage and full
# (point 11), make verify twice and what it leaves, a second make up, make
# footprint and make down. It needs a host that passes the host check for the management
# role with the kernel modules nfs and nfsv4, and has curl and the OpenStack
# CLI with osc-placement and python-barbicanclient; it refuses to start while
# a sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The tests that rely on the host's resolver skip when the host
# check warns about it. No test prints a password.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
SERVICE_OPERATORS=(keystone horizon glance placement barbican ovn neutron cinder nova)
STORAGE=$BATS_TEST_DIRNAME/fixtures/controlplane-storage.yaml
FULL=$BATS_TEST_DIRNAME/fixtures/controlplane-full.yaml
CHECKS="keystone-token keystone-catalog glance-catalog glance-image placement-catalog placement-classes barbican-catalog barbican-secret neutron-catalog neutron-network cinder-catalog cinder-volume nova-catalog nova-services nova-server horizon-login orders-ready orders-secrets orders-converge orders-rotation orders-teardown"
ORDERS=keystoneusers.c5c3.io,keystoneprojects.c5c3.io,keystoneroleassignments.c5c3.io,keystonecatalogentries.c5c3.io,keystoneapplicationcredentials.c5c3.io,mariadbdatabases.c5c3.io,rabbitmqvhosts.c5c3.io

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

# kc <role> <argument>...: runs kubectl against the role's cluster.
kc() {
	kubectl --kubeconfig "$KUBECONFIG_DIR/$1.yaml" "${@:2}"
}

# skip_without_resolver: skips the test, with the line of the host check as
# the reason, when the host's resolver does not answer the nip.io name of the
# Gateway.
skip_without_resolver() {
	local line
	line=$("$ROOT/scripts/preflight.sh" management | grep '^warn resolver: ' || :)
	if [ -n "$line" ]; then
		skip "$line"
	fi
}

# dry_run <yq expression> <file>: applies the file, changed by the
# expression, to sandbox-management with --dry-run=server.
dry_run() {
	yq "$1" "$2" | kc management apply --dry-run=server -f -
}

# uid <kind> <name>: prints the uid of the object in openstack.
uid() {
	kc management -n openstack get "$1" "$2" -o jsonpath='{.metadata.uid}'
}

# secret_has_keys <name> <key>...: succeeds when the Secret in workflow holds a
# value for each key.
secret_has_keys() {
	local secret key
	secret=$(kc management -n workflow get secret "$1" -o json) || return 1
	for key in "${@:2}"; do
		[ -n "$(jq -r --arg key "$key" '.data[$key] // empty' <<<"$secret")" ] || return 1
	done
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

@test "make up PROFILE=controlplane checks the NFS modules and brings thirteen stages Ready on the management cluster alone" {
	SANDBOX_STAGE_TIMEOUT=3600 run sb_make up PROFILE=controlplane
	[ "$status" -eq 0 ]
	[[ $output == *$'\nok module nfs: available\n'* ]]
	[[ $output == *$'\nok module nfsv4: available\n'* ]]
	[[ ${lines[-2]} =~ ^up:\ 13\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-1]} == "export KUBECONFIG="* ]]
	[ "$(kind get clusters 2>/dev/null | grep -cxE 'sandbox-(storage|compute)')" = 0 ]
}

@test "the nine service operators run resumed on one replica and are Ready" {
	local json
	json=$(kc management get helmreleases.helm.toolkit.fluxcd.io -A -o json)
	[ "$(jq -r --arg names "$(printf '%s-operator ' "${SERVICE_OPERATORS[@]}")" '
		($names | split(" ") | map(select(. != ""))) as $wanted
		| [.items[] | select(.metadata.name as $n | $wanted | index($n))
		   | "\(.metadata.name) \(.spec.suspend) \(.spec.values.replicas) \([.status.conditions[]? | select(.type == "Ready")][0].status)"]
		| sort | join("\n")' <<<"$json")" = \
		"$(printf '%s-operator false 1 True\n' "${SERVICE_OPERATORS[@]}" | sort)" ]
	[ "$(jq '[.items[] | select(.spec.suspend == true)] | length' <<<"$json")" = 0 ]
}

@test "the ControlPlane is Ready with the eight services on the managed bus openstack-rabbitmq" {
	local controlplane
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json)
	[ "$(jq -r '[.status.conditions[] | select(.type == "Ready")][0].status' <<<"$controlplane")" = True ]
	[ "$(jq -c '.spec.services | keys' <<<"$controlplane")" = \
		'["barbican","cinder","glance","horizon","keystone","neutron","nova","placement"]' ]
	[ "$(jq -r '.spec.infrastructure.messaging.clusterRef.name' <<<"$controlplane")" = openstack-rabbitmq ]
	[ "$(kc management -n openstack get rabbitmqclusters.rabbitmq.com -o name)" = "rabbitmqcluster.rabbitmq.com/openstack-rabbitmq" ]
}

@test "the seven orders of workflow are Ready with their four Secrets, and the ControlPlane reports NamespaceAssignmentsReady" {
	local controlplane orders
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json)
	[ "$(jq -c '.spec.namespaceAssignments' <<<"$controlplane")" = \
		'[{"namespace":"workflow","allowedRoles":["member"],"allowCatalogEntries":true}]' ]
	[ "$(jq -r '[.status.conditions[] | select(.type == "NamespaceAssignmentsReady")][0].status' <<<"$controlplane")" = True ]
	orders=$(kc management -n workflow get "$ORDERS" -o json)
	[ "$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name] | sort | join(" ")' <<<"$orders")" = \
		"workflow workflow-appcred workflow-bus workflow-db workflow-dns workflow-member workflow-project" ]
	secret_has_keys workflow-credentials clouds.yaml password
	secret_has_keys workflow-appcred-credentials clouds.yaml application_credential_id application_credential_secret
	secret_has_keys workflow-db-credentials host port database username password
	secret_has_keys workflow-bus-credentials transport_url host port username password vhost
}

@test "the service sets of storage and full are admitted, and the webhook refuses Nova without Glance and Cinder without a bus" {
	run dry_run . "$STORAGE"
	echo "$output"
	[ "$status" -eq 0 ]
	run dry_run . "$FULL"
	echo "$output"
	[ "$status" -eq 0 ]
	run dry_run 'del(.spec.services.glance)' "$FULL"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"is required when services.nova is set"* ]]
	run dry_run 'del(.spec.infrastructure.messaging)' "$STORAGE"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"is required when services.cinder is set"* ]]
	[ "$(kc management get controlplanes.c5c3.io -A -o name)" = "controlplane.c5c3.io/controlplane" ]
}

@test "make verify passes the twenty-one checks in their order" {
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(grep -oE '^(ok|FAIL) [^:]+' <<<"$output" | paste -sd ' ')" = "$(printf 'ok %s ' $CHECKS | sed 's/ $//')" ]
	[ "${lines[-1]}" = "verify: 21 of 21 checks passed" ]
}

@test "a second make verify passes and leaves no sandbox-verify resource" {
	local list
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 21 of 21 checks passed" ]
	for list in "image list" "volume list" "network list" "server list" "flavor list" "secret list" "user list" "project list" "service list"; do
		run bash -c 'eval "$(make --no-print-directory -C "$1" env)" && openstack $2 -f value' _ "$ROOT" "$list"
		echo "$list: $output"
		[ "$status" -eq 0 ]
		[[ $output != *sandbox-verify* ]]
	done
}

@test "a second make up PROFILE=controlplane keeps the Job and the ControlPlane" {
	local job controlplane
	job=$(uid job controlplane-database-tenant)
	controlplane=$(uid controlplanes.c5c3.io controlplane)
	[ -n "$job" ]
	[ -n "$controlplane" ]
	run sb_make up PROFILE=controlplane
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 13\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(uid job controlplane-database-tenant)" = "$job" ]
	[ "$(uid controlplanes.c5c3.io controlplane)" = "$controlplane" ]
}

@test "make footprint reports the management cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *sandbox-management* ]]
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
