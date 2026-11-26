#!/usr/bin/env bats
# The compute pool on a hypervisor of sandbox-compute, against a real Docker:
# points 5, 7, 8 and 9 of the README. It runs the scratch profile
# compute-pool: Keystone, Glance, Placement, Neutron and Nova on the TLS bus
# of messaging-tls on sandbox-management with the modules remote-compute,
# hypervisor-fixtures and compute-pool, and access, controllers, node-prep,
# trust, libvirt, kvm-node-agent and hypervisor-operator on sandbox-compute;
# then the scratch profile compute-pool-off, the same without compute-pool,
# trust and hypervisor-operator. Both live outside the tree in the test's
# directory. It checks the zone label of the worker, the sandbox CA on
# sandbox-compute, the copy of the auth Secret of hvo, the release of hvo and
# the Hypervisor it creates, the libvirt pod, the chassis, the metadata agent
# and the pool, the onboarding of the worker, make verify with a server on
# the worker, a second make up, make footprint, the three modules taken off
# the profile, and make down. It needs a host that passes the host check for
# the management and compute roles and has curl, openssl and the OpenStack
# CLI with osc-placement, refuses to start while a sandbox exists and ends
# with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The test of make verify skips when the host check warns about
# the resolver. No test prints a token, a password or the data of a Secret;
# secret values are compared by their SHA-256.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
NODE=sandbox-compute-worker
# The Secrets the operators deliver to a compute cluster.
MIRRORS=(controlplane-nova-compute-config controlplane-nova-hypervisor-operator-auth controlplane-nova-metadata-agent-secret)
# The client sections of the pool that carry cafile.
SECTIONS=(keystone_authtoken service_user placement neutron glance)

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

# ready <role> <kubectl argument>...: prints the status of the Ready
# condition of the object on the role's cluster.
ready() {
	kc "$1" get "${@:2}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
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

# key_sha <role> <namespace> <secret> <key>: prints the SHA-256 of the key of
# the Secret on the role's cluster, and fails when the Secret or the key
# cannot be read.
key_sha() {
	local json value
	json=$(kc "$1" -n "$2" get secret "$3" -o json) || return 1
	value=$(jq -er --arg key "$4" '.data[$key]' <<<"$json") || return 1
	base64 -d <<<"$value" | sha256sum | cut -d ' ' -f 1
}

# onboarding: prints the reason of the condition Onboarding of the Hypervisor
# of the worker.
onboarding() {
	kc compute get hypervisors.kvm.cloud.sap "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Onboarding")].reason}' 2>/dev/null
}

# onboarded: succeeds when onboarding prints Succeeded.
onboarded() {
	[ "$(onboarding)" = Succeeded ]
}

# hvo_pod: prints the name of the pod of hvo.
hvo_pod() {
	kc compute -n openstack get pods -l app.kubernetes.io/name=openstack-hypervisor-operator -o jsonpath='{.items[0].metadata.name}'
}

# modules_left: prints, by name, what remains of the modules compute-pool,
# trust and hypervisor-operator on either cluster: their stages, the
# DaemonSets of the pool, the agent and the chassis, the three mirrored
# Secrets, nova-metadata-ca and sandbox-ca, and the Deployment of hvo on
# sandbox-compute, and the ExternalSecret and the Secret of the copy in
# flux-system on sandbox-management.
modules_left() {
	local names
	kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io \
		management-compute-pool compute-trust compute-hypervisor-operator --ignore-not-found -o name | sed 's/^/sandbox-management: /'
	kc management -n flux-system get externalsecrets.external-secrets.io,secrets \
		--field-selector metadata.name=controlplane-nova-hypervisor-operator-auth -o name | sed 's/^/sandbox-management: /'
	if ! names=$(kc compute -n openstack get secrets,daemonsets,deployments -o name); then
		echo "sandbox-compute: cannot list openstack"
		return 0
	fi
	grep -E "^secret/($(IFS='|'; echo "${MIRRORS[*]}")|nova-metadata-ca|sandbox-ca)\$|^daemonset\.apps/lab-|^deployment\.apps/hypervisor-operator" <<<"$names" |
		sed 's/^/sandbox-compute: /'
	return 0
}

# modules_gone: succeeds when modules_left prints nothing.
modules_gone() {
	[ -z "$(modules_left 2>&1)" ]
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
	mkdir -p -- "$BATS_FILE_TMPDIR/profiles"
	cat >"$BATS_FILE_TMPDIR/profiles/compute-pool.yaml" <<'EOF'
clusters: [management, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, nova, remote-compute, hypervisor-fixtures, compute-pool]
  compute: [access, controllers, node-prep, trust, libvirt, kvm-node-agent, hypervisor-operator]
switches:
  glance: true
EOF
	cat >"$BATS_FILE_TMPDIR/profiles/compute-pool-off.yaml" <<'EOF'
clusters: [management, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, nova, remote-compute, hypervisor-fixtures]
  compute: [access, controllers, node-prep, libvirt, kvm-node-agent]
switches:
  glance: true
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=compute-pool writes the ConfigMap sandbox-trust before it waits and brings 20 stages Ready on two clusters" {
	local writing waiting
	run sb_up compute-pool
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 20\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-2]} == "export KUBECONFIG="* && ${lines[-1]} == "export KUBECONFIG="* ]]
	writing=$(grep -nxF 'up: writing the ConfigMap flux-system/sandbox-trust' <<<"$output" | cut -d : -f 1)
	waiting=$(grep -nE '^up: waiting for 22 roots and stages to be Ready at ' <<<"$output" | cut -d : -f 1)
	[ -n "$writing" ] && [ -n "$waiting" ]
	[ "$writing" -lt "$waiting" ]
}

@test "the worker carries the zone label sandbox" {
	[ "$(kc compute get node "$NODE" -o json | jq -r '.metadata.labels["topology.kubernetes.io/zone"]')" = sandbox ]
}

@test "the Secrets nova-metadata-ca and sandbox-ca on sandbox-compute hold the sandbox CA of sandbox-management" {
	local ca
	ca=$(key_sha management cert-manager sandbox-ca tls.crt)
	[ "$(key_sha compute openstack nova-metadata-ca ca.crt)" = "$ca" ]
	[ "$(key_sha compute openstack sandbox-ca ca.crt)" = "$ca" ]
}

@test "the copy of the auth Secret of hvo in flux-system is Ready with the seven keys of its source, and its account may get that Secret alone" {
	local account=system:serviceaccount:flux-system:hypervisor-operator-auth
	[ "$(ready management -n flux-system externalsecrets.external-secrets.io controlplane-nova-hypervisor-operator-auth)" = True ]
	[ "$(kc management -n flux-system get secret controlplane-nova-hypervisor-operator-auth -o json | jq -c '.data | keys')" = \
		"$(kc management -n openstack get secret controlplane-nova-hypervisor-operator-auth -o json | jq -c '.data | keys')" ]
	[ "$(kc management -n flux-system get secret controlplane-nova-hypervisor-operator-auth -o json | jq '.data | length')" = 7 ]
	[ "$(key_sha management flux-system controlplane-nova-hypervisor-operator-auth password)" = \
		"$(key_sha management openstack controlplane-nova-hypervisor-operator-auth password)" ]
	run kc management auth can-i get secret/controlplane-nova-hypervisor-operator-auth -n openstack --as="$account"
	[ "$output" = yes ]
	run kc management auth can-i get secret/rabbitmq-transport-url -n openstack --as="$account"
	[ "$output" = no ]
}

@test "the source and the release of hvo are Ready on the hub, its Deployment is Available on sandbox-compute with SSL_CERT_FILE, and sandbox-compute runs no Flux" {
	local objects deployment
	objects=$(kc management -n flux-system get ocirepositories.source.toolkit.fluxcd.io/openstack-hypervisor-operator \
		helmreleases.helm.toolkit.fluxcd.io/compute-hypervisor-operator -o json)
	[ "$(jq -r '[.items[] | "\(.kind)/\(.metadata.name)=\([.status.conditions[]? | select(.type == "Ready")][0].status)"] | sort | join(" ")' <<<"$objects")" = \
		"HelmRelease/compute-hypervisor-operator=True OCIRepository/openstack-hypervisor-operator=True" ]
	kc compute -n openstack wait deployment/hypervisor-operator-controller-manager --for=condition=Available --timeout=60s
	deployment=$(kc compute -n openstack get deployment hypervisor-operator-controller-manager -o json)
	[ "$(jq -r '.spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == "SSL_CERT_FILE") | .value' <<<"$deployment")" = \
		/etc/sandbox-ca/ca.crt ]
	[ "$(jq -r '.spec.template.spec.volumes[] | select(.name == "sandbox-ca") | .secret.secretName' <<<"$deployment")" = sandbox-ca ]
	run kc compute get namespace flux-system
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
}

@test "hvo logs no x509 error, and created the Hypervisor of the worker with highAvailability false and installCertificate true" {
	local pod log count
	# Each read is an assignment of its own, so a failed one fails the test.
	pod=$(hvo_pod)
	log=$(kc compute -n openstack logs "$pod" -c manager --tail=-1)
	count=$(grep -c x509 <<<"$log" || :)
	echo "x509 lines: $count"
	[ "$count" = 0 ]
	[ "$(kc compute get hypervisors.kvm.cloud.sap "$NODE" -o json | jq -c '[.spec.highAvailability, .spec.installCertificate]')" = '[false,true]' ]
}

@test "the libvirt certificate of the worker is Ready, the libvirt pod and the agent's pod turn Ready, and logind answers on the worker" {
	[ "$(ready compute -n hypervisor-system certificates.cert-manager.io "libvirt-$NODE")" = True ]
	kc compute -n openstack wait pod -l app.kubernetes.io/name=libvirt --for=condition=Ready --timeout=900s
	kc compute -n hypervisor-system wait pod -l app.kubernetes.io/name=kvm-node-agent --for=condition=Ready --timeout=300s
	[ "$(docker exec "$NODE" systemctl is-active systemd-logind.service)" = active ]
}

@test "the chassis, the metadata agent and the pool are Ready, and the client Secret of the chassis is on sandbox-compute" {
	[ "$(ready management -n openstack ovnchassis.ovn.openstack.c5c3.io lab-chassis)" = True ]
	[ "$(ready management -n openstack neutronmetadataagents.neutron.openstack.c5c3.io lab-metadata-agent)" = True ]
	[ "$(ready management -n openstack novacomputes.nova.openstack.c5c3.io lab)" = True ]
	kc compute -n openstack get secret lab-chassis-ovn-client -o name
}

@test "the container metadata-agent on the worker runs with 768Mi as memory request and limit" {
	[ "$(kc compute -n openstack get pods --field-selector "spec.nodeName=$NODE" -o json |
		jq -c '[.items[].spec.containers[] | select(.name == "metadata-agent") | [.resources.requests.memory, .resources.limits.memory]]')" = '[["768Mi","768Mi"]]' ]
}

@test "the configuration of the pool on the worker points cafile of the five client sections at ca.crt of the contract and runs the virt type of the host" {
	local pod conf section virt=qemu
	pod=$(kc compute -n openstack get pods -l app.kubernetes.io/name=novacompute,app.kubernetes.io/instance=lab \
		--field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].metadata.name}')
	[ -n "$pod" ]
	conf=$(kc compute -n openstack exec "$pod" -c nova-compute -- sh -c 'cat /etc/nova/compute-pool.conf.d/*')
	for section in "${SECTIONS[@]}"; do
		echo "$section: $(awk -v s="[$section]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && $1 == "cafile"' <<<"$conf")"
		[ "$(awk -v s="[$section]" '$0 == s { on = 1; next } /^\[/ { on = 0 } on && $1 == "cafile"' <<<"$conf")" = \
			"cafile = /etc/nova/compute-config/ca.crt" ]
	done
	[ "$(grep -c '^cafile = ' <<<"$conf")" = 5 ]
	if [ -e /dev/kvm ]; then
		virt=kvm
	fi
	[ "$(awk '$0 == "[libvirt]" { on = 1; next } /^\[/ { on = 0 } on && $1 == "virt_type"' <<<"$conf")" = "virt_type = $virt" ]
}

@test "the Hypervisor of the worker reports Onboarding Succeeded within 20 minutes" {
	if ! eventually 1200 onboarded; then
		echo "Onboarding: $(onboarding)"
		kc compute get hypervisors.kvm.cloud.sap "$NODE" -o json |
			jq -r '.status.conditions[]? | "\(.type) \(.status) \(.reason): \(.message)"'
		return 1
	fi
}

@test "make verify passes the 18 checks of Keystone, Glance, Placement, Neutron, Nova and the compute pool" {
	skip_without_resolver
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 18 of 18 checks passed" ]
}

@test "a second make up PROFILE=compute-pool keeps the pool, the pod of hvo and the ConfigMap sandbox-trust" {
	local pool pod version
	pool=$(kc management -n openstack get novacomputes.nova.openstack.c5c3.io lab -o jsonpath='{.metadata.uid}')
	pod=$(kc compute -n openstack get pod "$(hvo_pod)" -o jsonpath='{.metadata.uid}')
	version=$(kc management -n flux-system get configmap sandbox-trust -o jsonpath='{.metadata.resourceVersion}')
	run sb_up compute-pool
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 20\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(kc management -n openstack get novacomputes.nova.openstack.c5c3.io lab -o jsonpath='{.metadata.uid}')" = "$pool" ]
	[ "$(kc compute -n openstack get pod "$(hvo_pod)" -o jsonpath='{.metadata.uid}')" = "$pod" ]
	[ "$(kc management -n flux-system get configmap sandbox-trust -o jsonpath='{.metadata.resourceVersion}')" = "$version" ]
}

@test "make footprint reports the management and the compute cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *sandbox-management* ]]
	[[ $output == *sandbox-compute* ]]
}

@test "make up PROFILE=compute-pool-off removes the three stages and what they applied on either cluster within 600 s" {
	local start
	run sb_up compute-pool-off
	echo "$output"
	[ "$status" -eq 0 ]
	start=$SECONDS
	if ! eventually 600 modules_gone; then
		modules_left
		return 1
	fi
	echo "gone after $((SECONDS - start)) s"
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	echo "$output"
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
