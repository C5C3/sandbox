#!/usr/bin/env bats
# The worker of sandbox-compute as a hypervisor node, against a real Docker:
# point 6 of PLAN.md. It runs the scratch profile hypervisor-node, the
# modules access, controllers, node-prep, libvirt and kvm-node-agent on
# sandbox-compute and none on sandbox-management; then the scratch profile
# hypervisor-node-off, the same with access and controllers alone. Both live
# outside the tree in the test's directory. It checks the system bus and the
# labels of the worker, cert-manager and External Secrets, the reservation of
# the migration ports, the libvirt CA and the pods before a Hypervisor exists.
# With the CRDs of the pinned chart of the hypervisor operator and the scratch
# Hypervisor and Certificate of tests/host/fixtures/hypervisor-node-scratch.yaml
# (ADR-0030), it checks the TLS files kvm-node-agent installs, libvirtd in a
# systemd scope of the node, its TLS listener and test domains under TCG,
# and on KVM where the node has /dev/kvm; then a second make up, make
# footprint, the modules taken off the profile, and make down. It needs a
# host that passes the host check for the management and compute roles and
# reaches ghcr.io, quay.io, charts.jetstack.io, charts.external-secrets.io,
# docker.io and deb.debian.org, refuses to start while a sandbox exists and
# ends with make down. It needs no control plane.
#
# The tests run in file order, and each one starts from the state the one
# before left. No test prints a key or the data of a Secret; the TLS files
# are read by their size and mode only.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
FIXTURE=$BATS_TEST_DIRNAME/fixtures/hypervisor-node-scratch.yaml
DOMAIN=$BATS_TEST_DIRNAME/fixtures/hypervisor-node-domain.xml
NODE=sandbox-compute-worker
# The five labels and the annotation of upstream's lab.
MARKS='["openstack.c5c3.io/chassis","openstack.c5c3.io/nova-compute-pool","nova.openstack.cloud.sap/virt-driver","cobaltcore.cloud.sap/node-hypervisor-lifecycle","topology.kubernetes.io/zone","nova.openstack.cloud.sap/aggregates"]'
# The files kvm-node-agent installs from the Secret of the scratch
# Certificate.
TLS_FILES=(/etc/pki/CA/cacert.pem /etc/pki/libvirt/servercert.pem /etc/pki/libvirt/private/serverkey.pem
	/etc/pki/qemu/server-cert.pem /etc/pki/qemu/server-key.pem)

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

# ready <kubectl argument>...: prints the status of the Ready condition of
# the object on sandbox-compute, or of sandbox-management with management
# first.
ready() {
	local role=compute
	if [ "$1" = management ]; then
		role=management
		shift
	fi
	kc "$role" get "$@" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# node_marks <node>: prints those of the five labels and the annotation that
# the node carries, as a JSON object with sorted keys.
node_marks() {
	kc compute get node "$1" -o json |
		jq -cS --argjson keys "$MARKS" '(.metadata.labels // {}) + (.metadata.annotations // {}) | with_entries(select(.key as $k | $keys | index($k)))'
}

# libvirt_pod: prints the name of the libvirt pod.
libvirt_pod() {
	kc compute -n openstack get pods -l app.kubernetes.io/name=libvirt -o jsonpath='{.items[0].metadata.name}'
}

# virsh_local <argument>...: runs virsh against the local libvirtd in the
# container libvirtd of the libvirt pod.
virsh_local() {
	kc compute -n openstack exec "$(libvirt_pod)" -c libvirtd -- virsh -c qemu:///system "$@"
}

# start_domain <name> <type>: starts a transient domain from the XML fixture
# with the name and the domain type given.
start_domain() {
	sed -e "s/@NAME@/$1/" -e "s/@TYPE@/$2/" "$DOMAIN" |
		kc compute -n openstack exec -i "$(libvirt_pod)" -c libvirtd -- \
			sh -c 'cat >/tmp/sandbox-verify.xml && virsh -c qemu:///system create /tmp/sandbox-verify.xml'
}

# libvirt_waits: succeeds when the container libvirtd logged that it waits
# for the TLS files.
libvirt_waits() {
	kc compute -n openstack logs -l app.kubernetes.io/name=libvirt -c libvirtd --tail=-1 2>/dev/null |
		grep -qxF 'libvirtd: waiting for the TLS files kvm-node-agent installs under /etc/pki'
}

# tls_installed: succeeds when every file of TLS_FILES exists on the node and
# is not empty.
tls_installed() {
	docker exec "$NODE" sh -c 'for f in "$@"; do [ -s "$f" ] || exit 1; done' _ "${TLS_FILES[@]}"
}

# hypervisor_ready: succeeds when the conditions TLSCertificateInstalled,
# libvirtd.service and LibVirtConnection of the Hypervisor of the worker are
# True.
hypervisor_ready() {
	kc compute get hypervisors.kvm.cloud.sap "$NODE" -o json 2>/dev/null | jq -e '
		[.status.conditions[]? | select(.status == "True") | .type] as $true
		| ["TLSCertificateInstalled", "libvirtd.service", "LibVirtConnection"] - $true == []' >/dev/null
}

# agent_report: prints the state of the kvm-node-agent pod and the end of its
# log.
agent_report() {
	kc compute -n hypervisor-system get pods -l app.kubernetes.io/name=kvm-node-agent -o wide
	kc compute -n hypervisor-system logs -l app.kubernetes.io/name=kvm-node-agent --tail=20 || :
}

# modules_left: prints the stages of node-prep, libvirt and kvm-node-agent,
# the DaemonSet libvirt and the scope of libvirtd while they are there.
modules_left() {
	kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io compute-node-prep compute-libvirt compute-kvm-node-agent \
		--ignore-not-found -o name
	kc compute -n openstack get daemonset libvirt --ignore-not-found -o name
	if docker exec "$NODE" systemctl is-active --quiet cobaltcore-libvirtd.scope; then
		echo "cobaltcore-libvirtd.scope is active on $NODE"
	fi
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
	cat >"$BATS_FILE_TMPDIR/profiles/hypervisor-node.yaml" <<'EOF'
clusters: [management, compute]
modules:
  compute: [access, controllers, node-prep, libvirt, kvm-node-agent]
EOF
	cat >"$BATS_FILE_TMPDIR/profiles/hypervisor-node-off.yaml" <<'EOF'
clusters: [management, compute]
modules:
  compute: [access, controllers]
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=hypervisor-node prepares the worker before it waits and brings 5 stages Ready on two clusters" {
	local preparing installing waiting
	run sb_up hypervisor-node
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 5\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-2]} == "export KUBECONFIG="* && ${lines[-1]} == "export KUBECONFIG="* ]]
	preparing=$(grep -nxF "up: preparing the nodes of sandbox-compute: $NODE" <<<"$output" | cut -d : -f 1)
	installing=$(grep -nxF "up: installing dbus on $NODE" <<<"$output" | cut -d : -f 1)
	waiting=$(grep -nE '^up: waiting for 7 roots and stages to be Ready at ' <<<"$output" | cut -d : -f 1)
	[ -n "$preparing" ] && [ -n "$installing" ] && [ -n "$waiting" ]
	[ "$preparing" -lt "$installing" ]
	[ "$installing" -lt "$waiting" ]
}

@test "systemd of the worker answers on the system bus at /run/dbus/system_bus_socket" {
	docker exec "$NODE" busctl --system status org.freedesktop.systemd1 >/dev/null
	docker exec "$NODE" test -S /run/dbus/system_bus_socket
}

@test "the worker carries the five labels and the empty annotation of upstream's lab, and the control-plane node none of them" {
	[ "$(node_marks "$NODE")" = '{"cobaltcore.cloud.sap/node-hypervisor-lifecycle":"skip-tests","nova.openstack.cloud.sap/aggregates":"","nova.openstack.cloud.sap/virt-driver":"kvm","openstack.c5c3.io/chassis":"true","openstack.c5c3.io/nova-compute-pool":"lab","topology.kubernetes.io/zone":"sandbox"}' ]
	[ "$(node_marks sandbox-compute-control-plane)" = '{}' ]
}

@test "cert-manager and External Secrets are released from the hub and run on sandbox-compute, which runs no Flux" {
	local releases
	releases=$(kc management -n flux-system get helmreleases.helm.toolkit.fluxcd.io compute-cert-manager compute-external-secrets -o json)
	[ "$(jq -r '[.items[] | "\(.metadata.name)=\([.status.conditions[]? | select(.type == "Ready")][0].status)"] | join(" ")' <<<"$releases")" = \
		"compute-cert-manager=True compute-external-secrets=True" ]
	kc compute -n cert-manager wait deployment --all --for=condition=Available --timeout=60s
	kc compute -n external-secrets wait deployment --all --for=condition=Available --timeout=60s
	run kc compute get namespace flux-system
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
}

@test "the migration port reservation runs on the worker and reserves 49152-49215 in its network namespace" {
	local daemonset
	daemonset=$(kc compute -n hypervisor-system get daemonset migration-port-reservation -o json)
	[ "$(jq -c '[.status.desiredNumberScheduled, .status.numberReady]' <<<"$daemonset")" = '[1,1]' ]
	[ "$(kc compute -n hypervisor-system get pods -l app.kubernetes.io/name=migration-port-reservation -o jsonpath='{.items[*].spec.nodeName}')" = "$NODE" ]
	docker exec "$NODE" cat /proc/sys/net/ipv4/ip_local_reserved_ports | tr , '\n' | grep -qxF 49152-49215
}

@test "the ClusterIssuer, the libvirt CA and its Issuer are Ready on sandbox-compute" {
	[ "$(ready clusterissuers.cert-manager.io selfsigned-cluster-issuer)" = True ]
	[ "$(ready -n hypervisor-system certificates.cert-manager.io libvirt-migration-ca)" = True ]
	[ "$(ready -n hypervisor-system issuers.cert-manager.io nova-hypervisor-agents-ca-issuer)" = True ]
}

@test "before a Hypervisor exists, the stage of libvirt is Ready and its pod Running and not Ready, waiting for the TLS files" {
	local pod
	[ "$(ready management -n flux-system kustomizations.kustomize.toolkit.fluxcd.io compute-libvirt)" = True ]
	# The stage does not wait for the pod, whose image may still be pulled.
	eventually 900 libvirt_waits
	pod=$(kc compute -n openstack get pods -l app.kubernetes.io/name=libvirt -o json)
	[ "$(jq -c '[(.items | length), .items[0].spec.nodeName, .items[0].status.phase, ([.items[0].status.conditions[] | select(.type == "Ready")][0].status)]' <<<"$pod")" = \
		"[1,\"$NODE\",\"Running\",\"False\"]" ]
	[ "$(jq -c '[.items[0].status.initContainerStatuses[] | select(.name == "host-prepare") | .state.terminated.exitCode]' <<<"$pod")" = '[0]' ]
}

@test "vhost_net is loaded on the host, and the worker has /dev/kvm exactly when the host has it" {
	[ -d /sys/module/vhost_net ]
	if [ -e /dev/kvm ]; then
		docker exec "$NODE" test -e /dev/kvm
	else
		! docker exec "$NODE" test -e /dev/kvm
	fi
}

@test "the source and the release of kvm-node-agent are Ready on the hub, and its DaemonSet schedules one pod on the worker" {
	local objects
	objects=$(kc management -n flux-system get ocirepositories.source.toolkit.fluxcd.io/kvm-node-agent helmreleases.helm.toolkit.fluxcd.io/compute-kvm-node-agent -o json)
	[ "$(jq -r '[.items[] | "\(.kind)/\(.metadata.name)=\([.status.conditions[]? | select(.type == "Ready")][0].status)"] | sort | join(" ")' <<<"$objects")" = \
		"HelmRelease/compute-kvm-node-agent=True OCIRepository/kvm-node-agent=True" ]
	kc compute -n hypervisor-system get daemonset kvm-node-agent-controller-manager -o name
	[ "$(kc compute -n hypervisor-system get pods -l app.kubernetes.io/name=kvm-node-agent -o jsonpath='{.items[*].spec.nodeName}')" = "$NODE" ]
}

@test "with the CRDs of the pinned hypervisor operator and the scratch Hypervisor, kvm-node-agent installs the TLS files within 600 s, the keys with mode 600" {
	local tag crds key
	tag=$(yq 'select(.metadata.name == "openstack-hypervisor-operator") | .spec.ref.tag' \
		"$ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/sources.yaml")
	[ -n "$tag" ]
	# Helm takes the version with +, the OCI tag carries _ in its place, and
	# helm says so on stderr.
	crds=$(helm show crds oci://ghcr.io/cobaltcore-dev/charts/openstack-hypervisor-operator --version "${tag//_/+}" 2>"$BATS_TEST_TMPDIR/helm.err") ||
		{ cat "$BATS_TEST_TMPDIR/helm.err"; return 1; }
	[ "$(yq ea -N '.metadata.name' - <<<"$crds" | sort | paste -sd ' ')" = "evictions.kvm.cloud.sap hypervisors.kvm.cloud.sap" ]
	kc compute apply --server-side -f - <<<"$crds"
	kc compute wait --for=condition=Established crd/hypervisors.kvm.cloud.sap crd/evictions.kvm.cloud.sap --timeout=60s
	kc compute apply -f "$FIXTURE"
	# The agent ended at every start before the Hypervisor existed; a new pod
	# starts without the back-off of those restarts.
	kc compute -n hypervisor-system delete pod -l app.kubernetes.io/name=kvm-node-agent --wait=false
	if ! eventually 600 tls_installed; then
		agent_report
		return 1
	fi
	for key in /etc/pki/libvirt/private/serverkey.pem /etc/pki/qemu/server-key.pem; do
		echo "$key: $(docker exec "$NODE" stat -c %a "$key")"
		[ "$(docker exec "$NODE" stat -c %a "$key")" = 600 ]
	done
}

@test "the libvirt pod turns Ready within 900 s" {
	kc compute -n openstack wait pod -l app.kubernetes.io/name=libvirt --for=condition=Ready --timeout=900s
}

@test "libvirtd runs in the scope cobaltcore-libvirtd of the node's systemd, beside the active libvirtd.service" {
	local pids pid
	[ "$(docker exec "$NODE" systemctl is-active cobaltcore-libvirtd.scope)" = active ]
	[ "$(docker exec "$NODE" systemctl is-active libvirtd.service)" = active ]
	pids=$(docker exec "$NODE" sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = libvirtd ] && echo "${p#/proc/}"; done; :')
	echo "libvirtd: $pids"
	[ -n "$pids" ]
	for pid in $pids; do
		docker exec "$NODE" grep -qF /system.slice/cobaltcore-libvirtd.scope "/proc/$pid/cgroup"
	done
}

@test "the Hypervisor of the worker reports TLSCertificateInstalled, libvirtd.service and LibVirtConnection True within 300 s" {
	if ! eventually 300 hypervisor_ready; then
		kc compute get hypervisors.kvm.cloud.sap "$NODE" -o json |
			jq -r '.status.conditions[]? | "\(.type) \(.status) \(.reason): \(.message)"'
		return 1
	fi
}

@test "the TLS listener on port 16514 serves the certificate kvm-node-agent installed, which its own CA verifies" {
	kc compute -n openstack exec "$(libvirt_pod)" -c libvirtd -- virsh -c "qemu+tls://$NODE/system" version
}

@test "a test domain of type kvm runs, or of type qemu on a node without /dev/kvm" {
	local type=qemu
	if docker exec "$NODE" test -e /dev/kvm; then
		type=kvm
	fi
	start_domain sandbox-verify "$type"
	[ "$(virsh_local domstate sandbox-verify)" = running ]
}

@test "a test domain of type qemu runs under TCG beside it on a node with /dev/kvm" {
	docker exec "$NODE" test -e /dev/kvm || skip "the node has no /dev/kvm, and sandbox-verify ran under TCG"
	start_domain sandbox-verify-tcg qemu
	[ "$(virsh_local domstate sandbox-verify-tcg)" = running ]
}

@test "destroying the test domains leaves no domain" {
	local domain names
	for domain in sandbox-verify sandbox-verify-tcg; do
		if virsh_local domstate "$domain" >/dev/null 2>&1; then
			virsh_local destroy "$domain"
		fi
	done
	# The assignment fails the test when virsh does; an empty list does not.
	names=$(virsh_local list --all --name)
	[ -z "$(tr -d '[:space:]' <<<"$names")" ]
}

@test "a second make up PROFILE=hypervisor-node installs nothing and keeps the labels and the libvirt pod" {
	local uid marks
	uid=$(kc compute -n openstack get pods -l app.kubernetes.io/name=libvirt -o jsonpath='{.items[0].metadata.uid}')
	marks=$(node_marks "$NODE")
	run sb_up hypervisor-node
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 5\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	grep -qxF "up: preparing the nodes of sandbox-compute: $NODE" <<<"$output"
	# A negated command in the middle of a test fails nothing, so the lines
	# are counted.
	[ "$(grep -c 'installing dbus' <<<"$output")" = 0 ]
	[ "$(node_marks "$NODE")" = "$marks" ]
	[ "$(kc compute -n openstack get pods -l app.kubernetes.io/name=libvirt -o jsonpath='{.items[0].metadata.uid}')" = "$uid" ]
}

@test "make footprint reports the management and the compute cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *sandbox-management* ]]
	[[ $output == *sandbox-compute* ]]
}

@test "without the scratch objects, make up PROFILE=hypervisor-node-off removes the labels, and the stages, the DaemonSet libvirt and the scope go within 300 s" {
	kc compute delete -f "$FIXTURE" --timeout=120s
	kc compute -n hypervisor-system delete secret tls-libvirt-sandbox-compute-worker --ignore-not-found
	kc compute delete crd hypervisors.kvm.cloud.sap evictions.kvm.cloud.sap --timeout=120s
	run sb_up hypervisor-node-off
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qxF 'up: removed the node labels of sandbox-compute' <<<"$output"
	[[ ${lines[-3]} =~ ^up:\ 2\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(node_marks "$NODE")" = '{}' ]
	if ! eventually 300 modules_gone; then
		modules_left
		return 1
	fi
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	echo "$output"
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
