#!/usr/bin/env bats
# The eight services of the profile controlplane on the TLS message bus of the
# module messaging-tls, against a real Docker: point 4 for the bus consumers
# Neutron, Cinder and Nova. It runs the scratch profile identity-bare, the
# modules of identity without orders, and grows that sandbox into the scratch
# profile controlplane-tls, the modules of the profile controlplane with
# messaging-tls and the same switches. Both live outside the tree in the
# test's directory. It checks that the ControlPlane stays while it gains the
# namespace assignment of orders and the tenant Job runs again, the bus of
# the ControlPlane, make verify, the queues and connections of the broker
# after it, and make down. It needs what
# tests/host/controlplane.bats needs, refuses to start while a sandbox exists
# and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The tests that rely on the host's resolver skip when the host
# check warns about it. No test prints a transport URL or a password.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig

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

# uid <kind> <name>: prints the uid of the object in openstack.
uid() {
	kc management -n openstack get "$1" "$2" -o jsonpath='{.metadata.uid}'
}

# rabbitmqctl <argument>...: runs rabbitmqctl in the broker of messaging-tls.
rabbitmqctl() {
	kc management -n openstack exec shared-rabbitmq-server-0 -c rabbitmq -- rabbitmqctl "$@"
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
	mkdir -p -- "$BATS_FILE_TMPDIR/profiles"
	cat >"$BATS_FILE_TMPDIR/profiles/identity-bare.yaml" <<'EOF'
clusters: [management]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, platform, sizing, messaging-tls, controlplane]
EOF
	cat >"$BATS_FILE_TMPDIR/profiles/controlplane-tls.yaml" <<'EOF'
clusters: [management]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, cinder, cinder-nfs, nova, orders]
switches:
  glance: true
  barbican: true
  horizon: true
  fake-compute: true
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=identity-bare brings ten stages Ready" {
	SANDBOX_STAGE_TIMEOUT=3600 SANDBOX_PROFILE_DIR=$BATS_FILE_TMPDIR/profiles run sb_make up PROFILE=identity-bare
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 10\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ $output != *"module nfs"* ]]
	uid controlplanes.c5c3.io controlplane >"$BATS_FILE_TMPDIR/controlplane.uid"
	uid job controlplane-database-tenant >"$BATS_FILE_TMPDIR/job.uid"
	[ -s "$BATS_FILE_TMPDIR/controlplane.uid" ]
	[ -s "$BATS_FILE_TMPDIR/job.uid" ]
}

@test "identity-bare grows into controlplane-tls with fourteen stages, the same ControlPlane and a new run of the tenant Job" {
	SANDBOX_STAGE_TIMEOUT=3600 SANDBOX_PROFILE_DIR=$BATS_FILE_TMPDIR/profiles run sb_make up PROFILE=controlplane-tls
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 14\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(uid controlplanes.c5c3.io controlplane)" = "$(<"$BATS_FILE_TMPDIR/controlplane.uid")" ]
	[ "$(uid job controlplane-database-tenant)" != "$(<"$BATS_FILE_TMPDIR/job.uid")" ]
	[ "$(kc management -n openstack get job controlplane-database-tenant -o jsonpath='{.status.succeeded}')" = 1 ]
}

@test "the ControlPlane runs the eight services on the brownfield bus with Neutron, Cinder and Nova Ready" {
	local controlplane
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json)
	[ "$(jq -r '[.status.conditions[] | select(.type == "Ready" or .type == "NeutronReady" or .type == "CinderReady" or .type == "NovaReady") | "\(.type)=\(.status)"] | sort | join(" ")' <<<"$controlplane")" = \
		"CinderReady=True NeutronReady=True NovaReady=True Ready=True" ]
	[ "$(jq -c '.spec.services | keys' <<<"$controlplane")" = \
		'["barbican","cinder","glance","horizon","keystone","neutron","nova","placement"]' ]
	[ "$(jq -c '.spec.infrastructure.messaging | [.secretRef.name, .tls.caBundleSecretRef.name, has("clusterRef")]' <<<"$controlplane")" = \
		'["rabbitmq-transport-url","shared-rabbitmq-tls",false]' ]
	[ "$(kc management -n openstack get rabbitmqclusters.rabbitmq.com -o name)" = "rabbitmqcluster.rabbitmq.com/shared-rabbitmq" ]
}

@test "make verify passes the twenty-one checks on the TLS bus" {
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 21 of 21 checks passed" ]
}

# The services declare their topic queues once they consume from the bus,
# which can be after the stage is Ready: right after make up the broker held
# conductor, scheduler and compute, but not yet cinder-scheduler. make verify
# sends a volume and a server through the schedulers first.
@test "the broker holds the queues of Nova and Cinder, and every connection uses TLS" {
	local queues name connections
	queues=$(rabbitmqctl list_queues name --quiet --no-table-headers)
	for name in conductor scheduler compute cinder-scheduler cinder-volume; do
		echo "$name"
		grep -qxF "$name" <<<"$queues"
	done
	connections=$(rabbitmqctl list_connections ssl --quiet --no-table-headers)
	[ -n "$connections" ]
	[ "$(sort -u <<<"$connections")" = true ]
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
