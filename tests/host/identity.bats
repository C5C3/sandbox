#!/usr/bin/env bats
# The profile identity against a real Docker: Keystone alone on the TLS
# message bus of the module messaging-tls, on sandbox-management, with the
# orders of the module orders. It checks the keystone-operator, the three
# checks of point 4 (the listener with the sandbox CA, the credentials of
# both transport URL Secrets, and the admission of a ControlPlane with
# remoteCompute on this bus), the ControlPlane and its database tenant
# onboarding Job, six of the seven example orders and the refused vhost, a
# password rotated by hand that survives a reconcile, make env and make
# verify, what make verify leaves, a second make up, a deleted Job and
# make down. It needs a host that passes the host check for the management
# role and has openssl and the OpenStack CLI, refuses to start while a
# sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The tests that rely on the host's resolver skip when the host
# check warns about it. No test prints a transport URL or a password.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
SERVICE_OPERATORS=(keystone horizon glance placement barbican ovn neutron cinder nova)
FIXTURE=$BATS_TEST_DIRNAME/fixtures/controlplane-remote-compute.yaml
ORDERS=keystoneusers.c5c3.io,keystoneprojects.c5c3.io,keystoneroleassignments.c5c3.io,keystonecatalogentries.c5c3.io,keystoneapplicationcredentials.c5c3.io,mariadbdatabases.c5c3.io,rabbitmqvhosts.c5c3.io
ORDER_KINDS=(keystoneuser keystoneproject keystoneroleassignment keystonecatalogentry keystoneapplicationcredential mariadbdatabase rabbitmqvhost)

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# config_value <yq expression>: prints the value of config.yaml.
config_value() {
	yq "$1" "$ROOT/config.yaml"
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

# broker_name: prints rabbitmq.<a-b-c-d>.nip.io for addresses.rabbitmq.
broker_name() {
	local address
	address=$(config_value .addresses.rabbitmq)
	printf 'rabbitmq.%s.nip.io\n' "${address//./-}"
}

# s_client [<argument>...]: connects to the AMQPS listener on
# addresses.rabbitmq with the broker's name and verifies the certificate and
# the name, with the arguments added.
s_client() {
	openssl s_client -connect "$(config_value .addresses.rabbitmq):5671" -servername "$(broker_name)" \
		-verify_hostname "$(broker_name)" -verify_return_error "$@" </dev/null
}

# job_field <jsonpath>: prints the field of the Job controlplane-database-tenant.
job_field() {
	kc management -n openstack get job controlplane-database-tenant -o jsonpath="$1"
}

# tenant_done: the Job controlplane-database-tenant has succeeded once.
tenant_done() {
	[ "$(job_field '{.status.succeeded}' 2>/dev/null)" = 1 ]
}

# controlplane_ready: prints the status of the condition Ready of the
# ControlPlane controlplane.
controlplane_ready() {
	kc management -n openstack get controlplanes.c5c3.io controlplane \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# stage_ready <name>: prints the status of the condition Ready of the stage.
stage_ready() {
	kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io "$1" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# password_generation: succeeds when the KeystoneUser workflow holds
# generation 2 of its password in Keystone.
password_generation() {
	[ "$(kc management -n workflow get keystoneusers.c5c3.io workflow -o jsonpath='{.status.passwordGeneration}')" = 2 ]
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

@test "make up PROFILE=identity brings eleven stages Ready on the management cluster alone" {
	SANDBOX_STAGE_TIMEOUT=2400 run sb_make up PROFILE=identity
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 11\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-1]} == "export KUBECONFIG="* ]]
	[ "$(kind get clusters 2>/dev/null | grep -cxE 'sandbox-(storage|compute)')" = 0 ]
}

@test "the keystone-operator runs one Ready pod, and exactly the other eight service operators stay suspended" {
	local json
	json=$(kc management get helmreleases.helm.toolkit.fluxcd.io -A -o json)
	[ "$(jq -r '.items[] | select(.metadata.name == "keystone-operator")
		| "\(.spec.suspend) \(.spec.values.replicas) \([.status.conditions[]? | select(.type == "Ready")][0].status)"' <<<"$json")" = \
		"false 1 True" ]
	[ "$(jq -r '[.items[] | select(.spec.suspend == true) | .metadata.name] | sort | join(" ")' <<<"$json")" = \
		"$(printf '%s-operator\n' "${SERVICE_OPERATORS[@]:1}" | sort | paste -sd ' ')" ]
	[ "$(kc management -n keystone-system get pods -o json |
		jq -r '[.items[] | [.status.conditions[]? | select(.type == "Ready")][0].status] | join(" ")')" = True ]
}

@test "the broker listens with TLS alone on addresses.rabbitmq and its certificate verifies with the sandbox CA" {
	local service
	service=$(kc management -n openstack get service shared-rabbitmq -o json)
	[ "$(jq -r '[.spec.type, .status.loadBalancer.ingress[0].ip] | join(" ")' <<<"$service")" = \
		"LoadBalancer $(config_value .addresses.rabbitmq)" ]
	[ "$(jq '[.spec.ports[].port] | (index(5671) != null) and (index(5672) == null)' <<<"$service")" = true ]

	kc management -n cert-manager get secret sandbox-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >"$BATS_FILE_TMPDIR/ca.crt"
	run s_client -CAfile "$BATS_FILE_TMPDIR/ca.crt"
	[ "$status" -eq 0 ]
	[[ $output == *"Verify return code: 0 (ok)"* ]]
	run s_client
	[ "$status" -ne 0 ]
}

@test "both transport URL Secrets hold the URL of the default user, whose credentials the broker accepts" {
	local default user password secret url u p
	default=$(kc management -n openstack get secret shared-rabbitmq-default-user -o json)
	user=$(jq -r '.data.username | @base64d' <<<"$default")
	password=$(jq -r '.data.password | @base64d' <<<"$default")
	for secret in rabbitmq-transport-url controlplane-nova-remote-transport; do
		echo "$secret"
		url=$(kc management -n openstack get secret "$secret" -o jsonpath='{.data.transport_url}' | base64 -d)
		[[ $url =~ ^rabbit://([^:@/]+):([^@/]+)@([^:/]+):5671/$ ]]
		[ "${BASH_REMATCH[3]}" = "$(broker_name)" ]
		u=$(printf '%b' "${BASH_REMATCH[1]//%/\\x}")
		p=$(printf '%b' "${BASH_REMATCH[2]//%/\\x}")
		[ "$u" = "$user" ]
		[ "$p" = "$password" ]
		kc management -n openstack exec shared-rabbitmq-server-0 -c rabbitmq -- \
			rabbitmqctl authenticate_user "$u" "$p" >/dev/null 2>&1
	done
}

@test "a ControlPlane with remoteCompute is admitted on this bus and refused on a managed one, and the shape of identity is admitted" {
	run kc management apply --dry-run=server -f "$FIXTURE"
	echo "$output"
	[ "$status" -eq 0 ]
	run bash -c 'yq ".spec.infrastructure.messaging = {}" "$1" | kubectl --kubeconfig "$2" apply --dry-run=server -f -' _ \
		"$FIXTURE" "$KUBECONFIG_DIR/management.yaml"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"requires a brownfield bus with tls"* ]]
	run bash -c 'yq "del(.spec.services.glance, .spec.services.placement, .spec.services.neutron, .spec.services.nova)" "$1" |
		kubectl --kubeconfig "$2" apply --dry-run=server -f -' _ "$FIXTURE" "$KUBECONFIG_DIR/management.yaml"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(kc management get controlplanes.c5c3.io -A -o name)" = "controlplane.c5c3.io/controlplane" ]
}

@test "the ControlPlane runs Keystone alone on the brownfield bus, after one run of the tenant Job" {
	local controlplane
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json)
	[ "$(jq -r '[.status.conditions[] | select(.type == "Ready")][0].status' <<<"$controlplane")" = True ]
	[ "$(jq -c '.spec.services | keys' <<<"$controlplane")" = '["keystone"]' ]
	[ "$(jq -c '.spec.infrastructure.messaging | [.secretRef.name, .tls.caBundleSecretRef.name, has("clusterRef")]' <<<"$controlplane")" = \
		'["rabbitmq-transport-url","shared-rabbitmq-tls",false]' ]
	tenant_done
}

@test "the ControlPlane assigns workflow, six orders are Ready and RabbitMQVhost workflow-bus reports MessagingNotManaged with the stage of orders Ready" {
	local orders
	[ "$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json | jq -c '.spec.namespaceAssignments')" = \
		'[{"namespace":"workflow","allowedRoles":["member"],"allowCatalogEntries":true}]' ]
	[ "$(stage_ready management-orders)" = True ]
	orders=$(kc management -n workflow get "$ORDERS" -o json)
	[ "$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name] | sort | join(" ")' <<<"$orders")" = \
		"workflow workflow-appcred workflow-db workflow-dns workflow-member workflow-project" ]
	[ "$(jq -r '.items[] | select(.kind == "RabbitMQVhost") | "\(.metadata.name) \([.status.conditions[] | select(.type == "VhostReady")][0] | "\(.status) \(.reason)")"' <<<"$orders")" = \
		"workflow-bus False MessagingNotManaged" ]
	secret_has_keys workflow-credentials clouds.yaml password
	secret_has_keys workflow-appcred-credentials clouds.yaml application_credential_id application_credential_secret
	secret_has_keys workflow-db-credentials host port database username password
	run kc management -n workflow get secret workflow-bus-credentials
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
}

# Flux would take back a field that kubectl patched, and the CRD refuses to
# lower passwordGeneration; the example orders carry ssa: Merge.
@test "a password of the example user rotated by hand survives a reconcile of the stage of orders" {
	kc management -n workflow patch keystoneusers.c5c3.io workflow --type merge -p '{"spec":{"passwordGeneration":2}}' >/dev/null
	run eventually 300 password_generation
	[ "$status" -eq 0 ]
	run flux --kubeconfig "$KUBECONFIG_DIR/management.yaml" -n flux-system reconcile kustomization management-orders
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(stage_ready management-orders)" = True ]
	[ "$(kc management -n workflow get keystoneusers.c5c3.io workflow -o jsonpath='{.spec.passwordGeneration}')" = 2 ]
}

@test "make env loads a client that gets a token with the sandbox CA and none without it" {
	skip_without_resolver
	run bash -c 'eval "$(make --no-print-directory -C "$1" env)" && openstack token issue -f value -c id >/dev/null' _ "$ROOT"
	echo "$output"
	[ "$status" -eq 0 ]
	[ -s "$ROOT/.sandbox/sandbox-ca.pem" ]
	run bash -c 'eval "$(make --no-print-directory -C "$1" env)" && unset OS_CACERT && openstack token issue -f value -c id' _ "$ROOT"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"CERTIFICATE_VERIFY_FAILED"* || $output == *"certificate verify failed"* ]]
}

@test "make verify passes the two checks of Keystone and the five of the orders" {
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(grep -oE '^(ok|FAIL) [^:]+' <<<"$output" | paste -sd ' ')" = \
		"ok keystone-token ok keystone-catalog ok orders-ready ok orders-secrets ok orders-converge ok orders-rotation ok orders-teardown" ]
	grep -qxF 'ok orders-ready: 6 orders in workflow are Ready, RabbitMQVhost workflow/workflow-bus reports MessagingNotManaged on a bus that serves no vhost orders' <<<"$output"
	grep -qxF 'ok orders-converge: the 6 scratch orders in workflow are Ready with their Secrets' <<<"$output"
	[ "${lines[-1]}" = "verify: 7 of 7 checks passed" ]
}

@test "make verify leaves no sandbox-verify order, Secret, labelled child, user, project or service" {
	local names resources kind json left list
	skip_without_resolver
	names=$(kc management get "$ORDERS" -A -o name)
	[[ $names != *sandbox-verify* ]]
	names=$(kc management -n workflow get secrets -o name)
	[[ $names != *sandbox-verify* ]]
	# Every resource the API server lists, whatever its kind.
	resources=$(kc management api-resources --verbs=list -o name | paste -sd ,)
	for kind in "${ORDER_KINDS[@]}"; do
		json=$(kc management get "$resources" -A -l "c5c3.io/$kind-name" -o json)
		left=$(jq -r --arg label "c5c3.io/$kind-name" '.items[] | select(.metadata.labels[$label] | startswith("sandbox-verify"))
			| "\(.kind) \(.metadata.namespace)/\(.metadata.name)"' <<<"$json")
		echo "$kind: $left"
		[ -z "$left" ]
	done
	for list in "user list -f value -c Name|sandbox-verify" "project list -f value -c Name|sandbox-verify-project" "service list -f value -c Type|sandbox-verify"; do
		run bash -c 'eval "$(make --no-print-directory -C "$1" env)" && openstack $2' _ "$ROOT" "${list%%|*}"
		echo "${list%%|*}: $output"
		[ "$status" -eq 0 ]
		[ -n "$output" ]
		run grep -qxF -- "${list#*|}" <<<"$output"
		[ "$status" -ne 0 ]
	done
}

@test "a second make up PROFILE=identity keeps the Job and the ControlPlane" {
	local job controlplane
	job=$(job_field '{.metadata.uid}')
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o jsonpath='{.metadata.uid}')
	[ -n "$job" ]
	[ -n "$controlplane" ]
	run sb_make up PROFILE=identity
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 11\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(job_field '{.metadata.uid}')" = "$job" ]
	[ "$(kc management -n openstack get controlplanes.c5c3.io controlplane -o jsonpath='{.metadata.uid}')" = "$controlplane" ]
}

@test "a deleted tenant Job runs again at the next reconcile and succeeds, and the ControlPlane stays Ready" {
	local job pid
	job=$(job_field '{.metadata.uid}')
	kc management -n openstack delete job controlplane-database-tenant >/dev/null
	# flux reconcile waits for the stage, so the test polls for the outcome
	# instead of reading its exit status, as tests/host/platform.bats does.
	flux --kubeconfig "$KUBECONFIG_DIR/management.yaml" -n flux-system reconcile kustomization management-controlplane \
		>"$BATS_FILE_TMPDIR/reconcile.log" 2>&1 3>&- &
	pid=$!
	run eventually 600 tenant_done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$status" -eq 0 ]
	[ "$(job_field '{.metadata.uid}')" != "$job" ]
	[ "$(controlplane_ready)" = True ]
}

@test "make down leaves no network, container, cluster or state directory, sandbox-ca.pem included" {
	run sb_make down
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	[ ! -e "$ROOT/.sandbox/sandbox-ca.pem" ]
	rm "$BATS_FILE_TMPDIR/owned"
}
