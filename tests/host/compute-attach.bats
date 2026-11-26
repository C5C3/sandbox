#!/usr/bin/env bats
# The compute cluster attached to the control plane, against a real Docker.
# It runs the scratch profile compute-attach: Keystone, Glance, Placement,
# Neutron and Nova on the TLS bus of messaging-tls on sandbox-management,
# with the modules remote-compute and hypervisor-fixtures, and the module
# access on sandbox-compute; then the scratch profile compute-detach, the
# same without access. Both live outside the tree in the test's directory.
# It checks Flux and the access chart, the registration of sandbox-compute
# and a second run of it, a registration by scripts/register.sh, the remote
# compute contract, the published OVN databases, the K-ORC fixtures, the
# delivery of the three Secrets to the scratch chassis, agent and pool of
# tests/host/fixtures/compute-attach-scratch.yaml (ADR-0028), make verify,
# make footprint, the removal of the registration, and make down. It needs a
# host that passes the host check for the management and compute roles and
# has curl and the OpenStack CLI with osc-placement, refuses to start while
# a sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The tests that rely on the host's resolver skip when the host
# check warns about it. No test prints a token, a password, a transport URL
# or the data of a Secret; two secret values are compared by their SHA-256.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
FIXTURE=$BATS_TEST_DIRNAME/fixtures/compute-attach-scratch.yaml
# The three Secrets the operators deliver to a compute cluster.
MIRRORS=(controlplane-nova-compute-config controlplane-nova-hypervisor-operator-auth controlplane-nova-metadata-agent-secret)
KORC=domains.openstack.k-orc.cloud,projects.openstack.k-orc.cloud,users.openstack.k-orc.cloud,roles.openstack.k-orc.cloud,roleassignments.openstack.k-orc.cloud,flavors.openstack.k-orc.cloud,images.openstack.k-orc.cloud

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# sb_up <profile>: runs make up with the profile of the test's directory.
sb_up() {
	SANDBOX_STAGE_TIMEOUT=3600 SANDBOX_PROFILE_DIR=$BATS_FILE_TMPDIR/profiles sb_make up PROFILE="$1"
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

# suffix <key>: prints <a-b-c-d>.nip.io for the address of addresses.<key>.
suffix() {
	printf '%s.nip.io\n' "$(yq ".addresses.$1" "$ROOT/config.yaml" | tr . -)"
}

# uid <kind> <name>: prints the uid of the object in openstack.
uid() {
	kc management -n openstack get "$1" "$2" -o jsonpath='{.metadata.uid}'
}

# keystone_engaged: succeeds when the keystone-operator logged that it built
# sandbox-compute from its registration Secret.
keystone_engaged() {
	kc management -n keystone-system logs -l app.kubernetes.io/name=keystone-operator --tail=-1 2>/dev/null |
		grep 'building the cluster from its registration Secret' | grep -q sandbox-compute
}

# mirrors_delivered: succeeds when sandbox-compute holds the three Secrets in
# openstack.
mirrors_delivered() {
	local names name
	names=$(kc compute -n openstack get secrets -o name 2>/dev/null) || return 1
	for name in "${MIRRORS[@]}"; do
		grep -qxF "secret/$name" <<<"$names" || return 1
	done
}

# nova_ready: succeeds when NovaReady of the ControlPlane is True.
nova_ready() {
	[ "$(kc management -n openstack get controlplanes.c5c3.io controlplane \
		-o jsonpath='{.status.conditions[?(@.type=="NovaReady")].status}')" = True ]
}

# scratch_left: prints, by name, the three Secrets and every DaemonSet and
# pod in openstack on sandbox-compute, and every object named
# sandbox-verify* of a listable resource but Events in openstack on
# sandbox-management.
scratch_left() {
	local names resources
	if ! names=$(kc compute -n openstack get secrets,daemonsets,pods -o name); then
		echo "sandbox-compute: cannot list openstack"
		return 0
	fi
	grep -E "^secret/($(IFS='|'; echo "${MIRRORS[*]}"))\$|^(daemonset\.apps|pod)/" <<<"$names" | sed 's/^/sandbox-compute: /'
	# An Event about a deleted object is a record, not a leftover; it expires
	# after an hour.
	if ! resources=$(kc management api-resources --verbs=list --namespaced -o name | grep -vxE 'events(\.events\.k8s\.io)?' | paste -sd ,); then
		echo "sandbox-management: cannot list the resources"
		return 0
	fi
	kc management -n openstack get "$resources" -o name 2>/dev/null | grep '/sandbox-verify' | sed 's/^/sandbox-management: /'
	return 0
}

# scratch_gone: succeeds when scratch_left prints nothing.
scratch_gone() {
	[ -z "$(scratch_left)" ]
}

# compute_detached: succeeds when the stage compute-access and the
# ServiceAccount of the access chart are gone; a failed read is not gone.
compute_detached() {
	local stage account
	stage=$(kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io compute-access --ignore-not-found -o name) &&
		account=$(kc compute -n c5c3-access get serviceaccount target-cluster-access --ignore-not-found -o name) &&
		[ -z "$stage" ] && [ -z "$account" ]
}

# key_sha <role> <secret> <key>: prints the SHA-256 of the key of the Secret
# in openstack on the role's cluster, and fails when the Secret or the key
# cannot be read.
key_sha() {
	local json value
	json=$(kc "$1" -n openstack get secret "$2" -o json) || return 1
	value=$(jq -er --arg key "$3" '.data[$key]' <<<"$json") || return 1
	base64 -d <<<"$value" | sha256sum | cut -d ' ' -f 1
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
	mkdir -p -- "$BATS_FILE_TMPDIR/profiles"
	cat >"$BATS_FILE_TMPDIR/profiles/compute-attach.yaml" <<'EOF'
clusters: [management, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, nova, remote-compute, hypervisor-fixtures]
  compute: [access]
switches:
  glance: true
EOF
	cat >"$BATS_FILE_TMPDIR/profiles/compute-detach.yaml" <<'EOF'
clusters: [management, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, nova, remote-compute, hypervisor-fixtures]
switches:
  glance: true
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=compute-attach registers sandbox-compute before it waits and brings 13 stages Ready on two clusters" {
	local registering waiting
	run sb_up compute-attach
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 13\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-2]} == "export KUBECONFIG="* && ${lines[-1]} == "export KUBECONFIG="* ]]
	registering=$(grep -nxF 'up: registering sandbox-compute in c5c3-clusters for the namespaces openstack' <<<"$output" | cut -d : -f 1)
	waiting=$(grep -nE '^up: waiting for 15 roots and stages to be Ready at ' <<<"$output" | cut -d : -f 1)
	[ -n "$registering" ] && [ -n "$waiting" ]
	[ "$registering" -lt "$waiting" ]
}

@test "the ArtifactGenerator and the HelmRelease of the access chart are Ready on the hub, with the ExternalArtifact beside them" {
	local objects
	objects=$(kc management -n flux-system get artifactgenerators.source.extensions.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io,externalartifacts.source.toolkit.fluxcd.io -o json)
	[ "$(jq -r '[.items[] | select(.kind != "ExternalArtifact") | "\(.kind)/\(.metadata.name)=\([.status.conditions[]? | select(.type == "Ready")][0].status)"] | sort | join(" ")' <<<"$objects")" = \
		"ArtifactGenerator/target-cluster-access=True HelmRelease/compute-access=True" ]
	[ "$(jq -r '[.items[] | select(.kind == "ExternalArtifact") | .metadata.name] | join(" ")' <<<"$objects")" = target-cluster-access ]
}

@test "sandbox-compute holds the account and the token of the access chart and the privileged namespace openstack, and runs no Flux" {
	run kc compute -n c5c3-access get serviceaccount target-cluster-access -o name
	[ "$status" -eq 0 ]
	[ "$(kc compute -n c5c3-access get secret target-cluster-access-token -o json | jq '(.data.token // "") != ""')" = true ]
	[ "$(kc compute get namespace openstack -o json | jq -c '[.metadata.labels["pod-security.kubernetes.io/enforce"], .metadata.annotations["helm.sh/resource-policy"]]')" = \
		'["privileged","keep"]' ]
	run kc compute get namespace flux-system
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
}

@test "the account of the access chart may create Secrets in openstack and not in default" {
	run kc compute auth can-i create secrets -n openstack --as=system:serviceaccount:c5c3-access:target-cluster-access
	[ "$output" = yes ]
	run kc compute auth can-i create secrets -n default --as=system:serviceaccount:c5c3-access:target-cluster-access
	[ "$output" = no ]
}

@test "the registration Secret of sandbox-compute names openstack and holds a kubeconfig with the internal server and a token alone" {
	local secret
	secret=$(kc management -n c5c3-clusters get secret sandbox-compute -o json)
	[ "$(jq -c '[.metadata.labels["sigs.k8s.io/multicluster-runtime-kubeconfig"], .metadata.labels["sandbox.c5c3.io/cluster"], (.data | keys), (.data.namespaces | @base64d)]' <<<"$secret")" = \
		'["true","compute",["kubeconfig","namespaces"],"openstack"]' ]
	[ "$(jq -r '.data.kubeconfig | @base64d' <<<"$secret" | yq -o=json -I=0 '[[.clusters[].cluster.server], (.users | length), (.users[0].user | keys)]')" = \
		'[["https://sandbox-compute-control-plane:6443"],1,["token"]]' ]
}

@test "the keystone-operator builds sandbox-compute from its registration Secret within 120 s" {
	eventually 120 keystone_engaged
}

@test "the ControlPlane is Ready with the remote compute contract of Nova" {
	local controlplane gateway
	gateway=$(suffix gateway)
	controlplane=$(kc management -n openstack get controlplanes.c5c3.io controlplane -o json)
	[ "$(jq -r '[.status.conditions[] | select(.type == "Ready")][0].status' <<<"$controlplane")" = True ]
	[ "$(jq -c '.spec.services.nova | [.remoteCompute.transportURLSecretRef.name, .hypervisorOperator, .metadataGateway.hostname, .consoleProxy.gateway.hostname]' <<<"$controlplane")" = \
		"[\"controlplane-nova-remote-transport\",{},\"nova-metadata.$gateway\",\"nova-console.$gateway\"]" ]
}

@test "the Nova publishes the remote compute contract and the HTTPRoute of its metadata API" {
	local nova
	nova=$(kc management -n openstack get novas.nova.openstack.c5c3.io controlplane-nova -o json)
	[ "$(jq -c '[.status.remoteComputeConfigSecretRef.name, ([.status.conditions[] | select(.type == "MetadataHTTPRouteReady")][0].reason)]' <<<"$nova")" = \
		'["controlplane-nova-remote-compute-config","HTTPRouteAccepted"]' ]
}

@test "the remote compute contract names the broker and Keystone at their published names" {
	local secret
	secret=$(kc management -n openstack get secret controlplane-nova-remote-compute-config -o json)
	[ "$(jq '.data | has("nova-compute.conf") and has("transport_url") and has("password") and has("metadata_proxy_shared_secret") and has("cell_name") and has("ca.crt")' <<<"$secret")" = true ]
	# Host and port alone, without the credentials before the @.
	[ "$(jq -r '.data.transport_url | @base64d | sub("^rabbit://[^@]*@"; "") | sub("/.*$"; "")' <<<"$secret")" = "rabbitmq.$(suffix rabbitmq):5671" ]
	jq -r '.data["nova-compute.conf"] | @base64d' <<<"$secret" | grep -qF "https://keystone.$(suffix gateway)/v3"
}

@test "the Secret of the hypervisor operator holds exactly its seven keys and the public Keystone" {
	local secret
	secret=$(kc management -n openstack get secret controlplane-nova-hypervisor-operator-auth -o json)
	[ "$(jq -c '.data | keys' <<<"$secret")" = \
		'["auth_url","password","project_domain_name","project_name","region_name","user_domain_name","username"]' ]
	[ "$(jq -r '.data.auth_url | @base64d' <<<"$secret")" = "https://keystone.$(suffix gateway)/v3" ]
}

@test "the console proxy and the metadata API answer on the Gateway with the sandbox CA" {
	local code
	skip_without_resolver
	sb_make env >/dev/null
	[ "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$ROOT/.sandbox/sandbox-ca.pem" "https://nova-console.$(suffix gateway)/vnc_lite.html")" = 200 ]
	code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$ROOT/.sandbox/sandbox-ca.pem" "https://nova-metadata.$(suffix gateway)/")
	echo "nova-metadata: $code"
	[ "$code" != 000 ]
	[ "$code" != 404 ]
}

@test "the OVN central publishes its databases on a node port of the management node" {
	local central address node
	central=$(kc management -n openstack get ovncentrals.ovn.openstack.c5c3.io controlplane-ovn -o json)
	[ "$(jq -c '[.spec.northbound.externallyReachable, .spec.southbound.externallyReachable]' <<<"$central")" = '[true,true]' ]
	node=$(kc management get node sandbox-management-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
	address=$(jq -r '.status.southbound.dbAddress' <<<"$central")
	echo "dbAddress: $address, node: $node"
	[[ $address =~ ^ssl:${node//./\\.}:([0-9]+)$ ]]
	printf '%s %s\n' "$node" "${BASH_REMATCH[1]}" >"$BATS_FILE_TMPDIR/southbound"
}

@test "a node of sandbox-compute reaches the Southbound database within 5 s" {
	local node port
	read -r node port <"$BATS_FILE_TMPDIR/southbound"
	docker exec sandbox-compute-worker timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$node" "$port"
}

@test "the eight K-ORC fixtures are Available, without the volume type, the network and the subnet of the smoke test" {
	local objects absent
	objects=$(kc management -n openstack get "$KORC" -o json)
	[ "$(jq -r '[.items[] | select(.metadata.name | startswith("hvo-")) | "\(.kind)/\(.metadata.name)=\([.status.conditions[]? | select(.type == "Available")][0].status)"] | sort | join(" ")' <<<"$objects")" = \
		"Domain/hvo-cc3test=True Domain/hvo-user-domain=True Flavor/hvo-smoke-test-flavor=True Image/hvo-cirros-kvm=True Project/hvo-test=True Role/hvo-admin-role=True RoleAssignment/hvo-test-admin=True User/hvo-user=True" ]
	absent=$(kc management -n openstack get volumetypes.openstack.k-orc.cloud,networks.openstack.k-orc.cloud,subnets.openstack.k-orc.cloud -o name)
	[ -z "$absent" ]
}

@test "Keystone, Nova and Glance hold the domain cc3test, the project test, the flavor 1 and the image cirros-kvm" {
	skip_without_resolver
	eval "$(sb_make env)"
	[ "$(openstack domain show cc3test -f value -c enabled)" = True ]
	openstack project show test --domain cc3test -f value -c id >/dev/null
	[ "$(openstack flavor show 1 -f value -c ram)" = 256 ]
	[ "$(openstack image show cirros-kvm -f value -c status)" = active ]
}

@test "the hypervisor operator's credentials issue a token scoped to the project test in the domain cc3test" {
	local secret
	skip_without_resolver
	sb_make env >/dev/null
	secret=$(kc management -n openstack get secret controlplane-nova-hypervisor-operator-auth -o json)
	# The password reaches the environment of openstack alone, never an
	# argument.
	OS_AUTH_URL=$(jq -r '.data.auth_url | @base64d' <<<"$secret") \
		OS_USERNAME=$(jq -r '.data.username | @base64d' <<<"$secret") \
		OS_USER_DOMAIN_NAME=$(jq -r '.data.user_domain_name | @base64d' <<<"$secret") \
		OS_PASSWORD=$(jq -r '.data.password | @base64d' <<<"$secret") \
		OS_PROJECT_NAME=test OS_PROJECT_DOMAIN_NAME=cc3test OS_CACERT=$ROOT/.sandbox/sandbox-ca.pem \
		openstack token issue -f value -c project_id >/dev/null
}

@test "a scratch chassis, agent and pool on sandbox-compute get the three Secrets within 300 s" {
	local secrets
	kc management apply -f "$FIXTURE"
	if ! eventually 300 mirrors_delivered; then
		kc management -n openstack get controlplanes.c5c3.io controlplane -o json |
			jq -r '.status.conditions[] | select(.type == "NovaReady") | "NovaReady \(.status) \(.reason): \(.message)"'
		return 1
	fi
	secrets=$(kc compute -n openstack get secrets -o json)
	[ "$(jq -r '[.items[] | select(.metadata.name == "controlplane-nova-compute-config" or .metadata.name == "controlplane-nova-hypervisor-operator-auth")
		| .metadata.labels["nova.openstack.c5c3.io/compute-config-mirror"]] | join(" ")' <<<"$secrets")" = "true true" ]
	[ "$(jq -c '.items[] | select(.metadata.name == "controlplane-nova-metadata-agent-secret")
		| [.metadata.labels["neutron.openstack.c5c3.io/metadata-shared-secret-mirror"], (.data | keys)]' <<<"$secrets")" = '["true",["shared_secret"]]' ]
}

@test "the mirror on sandbox-compute is the remote compute contract, not the contract of the management cluster" {
	local mirror remote local_contract
	mirror=$(key_sha compute controlplane-nova-compute-config transport_url)
	remote=$(key_sha management controlplane-nova-remote-compute-config transport_url)
	[ "$mirror" = "$remote" ]
	# The two contracts share transport_url, which messaging-tls renders from
	# one template for both, and differ in the endpoints of nova-compute.conf:
	# public in the remote contract, in-cluster in the other.
	mirror=$(key_sha compute controlplane-nova-compute-config nova-compute.conf)
	remote=$(key_sha management controlplane-nova-remote-compute-config nova-compute.conf)
	local_contract=$(key_sha management controlplane-nova-compute-config nova-compute.conf)
	[ "$mirror" = "$remote" ]
	[ "$mirror" != "$local_contract" ]
}

@test "NovaReady is True while the scratch objects exist" {
	eventually 120 nova_ready
}

@test "deleting the pool, the agent and the chassis leaves nothing on either cluster within 300 s" {
	local start=$SECONDS
	kc management -n openstack delete novacomputes.nova.openstack.c5c3.io sandbox-verify-pool --timeout=300s
	kc management -n openstack delete neutronmetadataagents.neutron.openstack.c5c3.io sandbox-verify-metadata --timeout=300s
	kc management -n openstack delete ovnchassis.ovn.openstack.c5c3.io sandbox-verify-chassis --timeout=300s
	# The 300 s count from the first delete.
	if ! eventually "$((300 - (SECONDS - start)))" scratch_gone; then
		scratch_left
		return 1
	fi
}

@test "make verify passes the ten checks of Keystone, Glance, Placement, Neutron and Nova" {
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 10 of 10 checks passed" ]
}

@test "scripts/register.sh registers a second name for the kubeconfig of sandbox-compute without the label of a role" {
	kc management -n c5c3-clusters get secret sandbox-compute -o json | jq -r '.data.kubeconfig | @base64d' |
		"$ROOT/scripts/register.sh" sandbox-verify-external -
	[ "$(kc management -n c5c3-clusters get secret sandbox-verify-external -o json |
		jq -c '[.metadata.labels["sigs.k8s.io/multicluster-runtime-kubeconfig"], (.metadata.labels | has("sandbox.c5c3.io/cluster"))]')" = '["true",false]' ]
}

@test "a second make up PROFILE=compute-attach keeps the registration, the ControlPlane and the other registration" {
	local version controlplane
	version=$(kc management -n c5c3-clusters get secret sandbox-compute -o jsonpath='{.metadata.resourceVersion}')
	controlplane=$(uid controlplanes.c5c3.io controlplane)
	run sb_up compute-attach
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 13\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(kc management -n c5c3-clusters get secret sandbox-compute -o jsonpath='{.metadata.resourceVersion}')" = "$version" ]
	[ "$(uid controlplanes.c5c3.io controlplane)" = "$controlplane" ]
	kc management -n c5c3-clusters get secret sandbox-verify-external -o name
	kc management -n c5c3-clusters delete secret sandbox-verify-external
}

@test "make footprint reports the management and the compute cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *sandbox-management* ]]
	[[ $output == *sandbox-compute* ]]
}

@test "make up PROFILE=compute-detach removes the registration, the stage and the account, and keeps the namespace openstack" {
	run sb_up compute-detach
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qxF 'up: removed the registration of sandbox-compute' <<<"$output"
	[[ ${lines[-3]} =~ ^up:\ 12\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	run kc management -n c5c3-clusters get secret sandbox-compute
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
	eventually 120 compute_detached
	kc compute get namespace openstack -o name
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	echo "$output"
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
