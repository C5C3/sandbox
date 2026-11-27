#!/usr/bin/env bats
# The hand-off of the Ceph client keys through the shared OpenBao, against a
# real Docker: point 3 of the README for both remote clusters. It runs the
# scratch profile keys, which lives outside the tree in the test's
# directory: management with the modules up to openbao, openbao-remote-auth
# and ceph-keys, storage with the Ceph of tests/host/storage-ceph.bats,
# controllers and key-push, and compute with controllers alone. It checks
# the log of make up, the published OpenBao and its mutual TLS from the
# host, the auth config of kubernetes/storage and kubernetes/hypervisor,
# External Secrets on sandbox-storage without cert-manager, the push of
# both keys and their arrival in openstack, the refusal of an account the
# role does not bind, the compute mount with the scratch objects of
# tests/host/fixtures/storage-keys-compute.yaml in place of the module of
# #18 (ADR-0041), a rotation by keyGeneration, a second make up, make
# footprint and make down. It needs a host that passes the host check for
# all three roles, has more than 10 % of the filesystem under Docker free,
# resolves nip.io names to private addresses and reaches ghcr.io,
# charts.rook.io, charts.external-secrets.io, docker.io and quay.io,
# refuses to start while a sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. No test prints a key or the data of a Secret: keys are
# compared by the sha256 of userKey, the client pair goes into files of
# mode 600 in the test's directory, the root token into openbao-0 over
# stdin, and the client certificate of sandbox-compute from the hub to
# sandbox-compute over stdin.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
COMPUTE_FIXTURE=$BATS_TEST_DIRNAME/fixtures/storage-keys-compute.yaml
UNBOUND_FIXTURE=$BATS_TEST_DIRNAME/fixtures/storage-keys-unbound.yaml
# The sha256 of nothing: a hash of an empty or absent userKey.
EMPTY_HASH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# sb_up: runs make up with the profile keys of the test's directory.
sb_up() {
	SANDBOX_STAGE_TIMEOUT=3600 SANDBOX_PROFILE_DIR=$BATS_FILE_TMPDIR/profiles sb_make up PROFILE=keys
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

# host_loop <prefix>: prints the loop devices of the host whose backing file
# starts with the prefix, or contains it when the prefix starts with *.
host_loop() {
	local path file device
	for path in /sys/block/loop*/loop/backing_file; do
		[ -f "$path" ] || continue
		file=$(<"$path")
		# shellcheck disable=SC2053
		if [[ $file == $1* ]]; then
			device=${path%/loop/backing_file}
			echo "/dev/${device##*/} $file"
		fi
	done
}

# address: prints addresses.openbao of the configuration.
address() {
	yq '.addresses.openbao' "$ROOT/config.yaml"
}

# server: prints the URL of the published OpenBao.
server() {
	printf 'https://openbao.%s.nip.io:8200\n' "$(address | tr . -)"
}

# key_hash <role> <namespace> <secret>: prints the sha256 of userKey of the
# Secret.
key_hash() {
	kc "$1" -n "$2" get secret "$3" -o jsonpath='{.data.userKey}' | base64 -d | sha256sum | cut -d ' ' -f 1
}

# ready <role> <namespace> <resource> <name>: prints the status of the
# Ready condition of the object.
ready() {
	kc "$1" -n "$2" get "$3" "$4" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# is_ready <role> <namespace> <resource> <name>: succeeds when the object is
# Ready.
is_ready() {
	[ "$(ready "$@")" = True ]
}

# refusal <role> <name>: prints the lines of the last 10 minutes of the log
# of the External Secrets controller on the role's cluster that name the
# object. The Ready condition and the Warning events of a store or an
# ExternalSecret carry a generic line only, such as "unable to create
# client"; the log carries the error OpenBao returned.
refusal() {
	kc "$1" -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=-1 --since=10m |
		grep -F -- "\"$2\"" || :
}

# refused <role> <namespace> <resource> <name> <text>: succeeds when the
# object is Ready False and a line of the controller's log that names it
# holds the text.
refused() {
	[ "$(ready "$1" "$2" "$3" "$4")" = False ] || return 1
	[[ $(refusal "$1" "$4") == *"$5"* ]]
}

# bao_read <path>: reads the path in openbao-0 with the root token, which
# goes into the pod over stdin, and prints the JSON.
bao_read() {
	kc management -n shared-services get secret openbao-init-keys -o jsonpath='{.data.init-output}' |
		base64 -d | jq -r '.root_token' |
		kc management -n shared-services exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN && export BAO_TOKEN &&
			BAO_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/openbao/tls/ca.crt VAULT_CLIENT_CERT=/openbao/client-tls/tls.crt \
			VAULT_CLIENT_KEY=/openbao/client-tls/tls.key exec bao read -format=json "$1"' _ "$1"
}

# rotated: succeeds when the cinder key of the storage cluster is no longer
# OLD_HASH and the Secrets of openstack on the management and the compute
# cluster hold it.
rotated() {
	local new
	new=$(key_hash storage rook-ceph rook-ceph-client-cinder)
	[ "$new" != "$OLD_HASH" ] && [ "$new" != "$EMPTY_HASH" ] &&
		[ "$(key_hash management openstack ceph-client-cinder)" = "$new" ] &&
		[ "$(key_hash compute openstack sandbox-verify-cinder)" = "$new" ]
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
	mkdir -p -- "$BATS_FILE_TMPDIR/profiles"
	cat >"$BATS_FILE_TMPDIR/profiles/keys.yaml" <<'EOF'
clusters: [management, storage, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, openbao, openbao-remote-auth, ceph-keys]
  storage: [block-devices, rook-crds, rook-operator, ceph-cluster, controllers, key-push]
  compute: [controllers]
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=keys writes the API CAs and both client certificates before it waits, and brings 14 stages Ready on three clusters" {
	local configmap storage compute waiting
	run sb_up
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-4]} =~ ^up:\ 14\ stages\ Ready\ on\ 3\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	configmap=$(grep -nxF "up: writing the ConfigMap flux-system/openbao-remote-auth for sandbox-storage and sandbox-compute" <<<"$output" | cut -d : -f 1)
	storage=$(grep -nxF "up: writing the Secret flux-system/openbao-client-storage" <<<"$output" | cut -d : -f 1)
	compute=$(grep -nxF "up: writing the Secret flux-system/openbao-client-compute" <<<"$output" | cut -d : -f 1)
	waiting=$(grep -nE '^up: waiting for 17 roots and stages to be Ready at ' <<<"$output" | cut -d : -f 1)
	[ -n "$configmap" ] && [ -n "$storage" ] && [ -n "$compute" ] && [ -n "$waiting" ]
	[ "$configmap" -lt "$storage" ]
	[ "$configmap" -lt "$compute" ]
	[ "$storage" -lt "$waiting" ]
	[ "$compute" -lt "$waiting" ]
}

@test "the Service shared-services/openbao-published has the address of addresses.openbao and one endpoint" {
	[ "$(kc management -n shared-services get service openbao-published -o jsonpath='{.status.loadBalancer.ingress[*].ip}')" = "$(address)" ]
	[ "$(kc management -n shared-services get endpointslices -l kubernetes.io/service-name=openbao-published -o json |
		jq '[.items[].endpoints[]? | select(.conditions.ready)] | length')" = 1 ]
}

@test "the host reaches OpenBao under its published name with the client certificate of sandbox-storage, and OpenBao is initialised and unsealed" {
	local key
	for key in CLIENT_CRT CLIENT_KEY CA; do
		(umask 077 && kc management -n flux-system get secret openbao-client-storage -o jsonpath="{.data.OPENBAO_${key}_B64}" |
			base64 -d | base64 -d >"$BATS_FILE_TMPDIR/$key.pem")
	done
	[ "$(stat -c %a "$BATS_FILE_TMPDIR/CLIENT_CRT.pem" "$BATS_FILE_TMPDIR/CLIENT_KEY.pem" "$BATS_FILE_TMPDIR/CA.pem" | paste -sd ' ')" = "600 600 600" ]
	run curl -sS --fail --cacert "$BATS_FILE_TMPDIR/CA.pem" --cert "$BATS_FILE_TMPDIR/CLIENT_CRT.pem" \
		--key "$BATS_FILE_TMPDIR/CLIENT_KEY.pem" "$(server)/v1/sys/health"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(jq -c '[.initialized, .sealed]' <<<"$output")" = '[true,false]' ]
}

@test "the same call without the client certificate fails" {
	run curl -sS --fail --cacert "$BATS_FILE_TMPDIR/CA.pem" "$(server)/v1/sys/health"
	echo "$output"
	[ "$status" -ne 0 ]
}

@test "auth/kubernetes/storage/config and auth/kubernetes/hypervisor/config name the API servers of sandbox-storage and sandbox-compute and review with the caller's token" {
	local out
	out=$(bao_read auth/kubernetes/storage/config)
	[ "$(jq -c '[.data.kubernetes_host, .data.disable_local_ca_jwt]' <<<"$out")" = '["https://sandbox-storage-control-plane:6443",true]' ]
	out=$(bao_read auth/kubernetes/hypervisor/config)
	[ "$(jq -c '[.data.kubernetes_host, .data.disable_local_ca_jwt]' <<<"$out")" = '["https://sandbox-compute-control-plane:6443",true]' ]
}

@test "the release of External Secrets is Ready on the hub and runs on sandbox-storage, which runs neither cert-manager nor Flux" {
	[ "$(kc management -n flux-system get helmrelease storage-external-secrets -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
	kc storage -n external-secrets wait --for=condition=Available deployment --all --timeout=60s
	[ "$(kc storage -n external-secrets get deployments -o name | wc -l)" -ge 1 ]
	run kc storage get namespace cert-manager
	[ "$status" -ne 0 ]
	run kc storage get namespace flux-system
	[ "$status" -ne 0 ]
}

@test "on sandbox-storage the client certificate is a Secret of type kubernetes.io/tls, no Certificate exists, and the store and both PushSecrets are Ready" {
	[ "$(kc storage -n rook-ceph get secret ceph-keys-push-client-tls -o jsonpath='{.type}')" = kubernetes.io/tls ]
	# Without cert-manager's CRD no Certificate can exist in rook-ceph.
	run kc storage get crd certificates.cert-manager.io
	[ "$status" -ne 0 ]
	is_ready storage rook-ceph secretstores.external-secrets.io openbao-ceph-store
	is_ready storage rook-ceph pushsecrets.external-secrets.io ceph-client-cinder
	is_ready storage rook-ceph pushsecrets.external-secrets.io ceph-client-cinder-backup
}

@test "openstack/ceph-client-cinder and ceph-client-cinder-backup on sandbox-management hold userKey alone, equal to the keys of sandbox-storage" {
	local client hub
	for client in cinder cinder-backup; do
		echo "$client"
		[ "$(kc management -n openstack get secret "ceph-client-$client" -o json | jq -c '.data | keys')" = '["userKey"]' ]
		hub=$(key_hash management openstack "ceph-client-$client")
		[ "$hub" != "$EMPTY_HASH" ]
		[ "$hub" = "$(key_hash storage rook-ceph "rook-ceph-client-$client")" ]
	done
}

@test "a SecretStore whose account the role push-ceph-keys does not bind is refused within 120 s" {
	SERVER=$(server) yq '(select(.kind == "SecretStore") | .spec.provider.vault.server) = strenv(SERVER)' "$UNBOUND_FIXTURE" |
		kc storage apply -f -
	eventually 120 refused storage rook-ceph secretstores.external-secrets.io sandbox-verify-unbound "service account name not authorized" || {
		ready storage rook-ceph secretstores.external-secrets.io sandbox-verify-unbound
		refusal storage sandbox-verify-unbound
		false
	}
}

@test "with the scratch objects on sandbox-compute, read-ceph-client-cinder on kubernetes/hypervisor reads the cinder key within 120 s and is refused the cinder-backup key" {
	kc management -n flux-system get secret openbao-client-compute -o json |
		SERVER=$(server) yq ea '(select(fileIndex == 1) | .data) as $hub
			| select(fileIndex == 0)
			| (select(.kind == "Secret") | .data) = {"tls.crt": ($hub.OPENBAO_CLIENT_CRT_B64 | @base64d),
				"tls.key": ($hub.OPENBAO_CLIENT_KEY_B64 | @base64d), "ca.crt": ($hub.OPENBAO_CA_B64 | @base64d)}
			| (select(.kind == "SecretStore") | .spec.provider.vault.server) = strenv(SERVER)' "$COMPUTE_FIXTURE" - |
		kc compute apply -f -
	eventually 120 is_ready compute openstack externalsecrets.external-secrets.io sandbox-verify-cinder || {
		refusal compute sandbox-verify-cinder
		refusal compute sandbox-verify-openbao
		false
	}
	[ "$(key_hash compute openstack sandbox-verify-cinder)" = "$(key_hash storage rook-ceph rook-ceph-client-cinder)" ]
	eventually 120 refused compute openstack externalsecrets.external-secrets.io sandbox-verify-cinder-backup "permission denied" || {
		ready compute openstack externalsecrets.external-secrets.io sandbox-verify-cinder-backup
		refusal compute sandbox-verify-cinder-backup
		false
	}
}

@test "after keyGeneration of the CephClient cinder is raised to 2, the new key reaches openstack on sandbox-management and sandbox-compute within 300 s" {
	OLD_HASH=$(key_hash storage rook-ceph rook-ceph-client-cinder)
	[ "$OLD_HASH" != "$EMPTY_HASH" ]
	kc storage -n rook-ceph patch cephclient cinder --type merge -p '{"spec":{"security":{"cephx":{"keyGeneration":2}}}}'
	eventually 300 rotated
}

@test "a reconcile of storage-ceph-cluster leaves keyGeneration at 2" {
	run flux --kubeconfig "$KUBECONFIG_DIR/management.yaml" -n flux-system reconcile kustomization storage-ceph-cluster
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(kc storage -n rook-ceph get cephclient cinder -o jsonpath='{.spec.security.cephx.keyGeneration}')" = 2 ]
}

@test "a second make up PROFILE=keys keeps the Job openbao-remote-auth and the two client Secrets of the hub" {
	local job storage compute
	job=$(kc management -n shared-services get job openbao-remote-auth -o jsonpath='{.metadata.uid}')
	storage=$(kc management -n flux-system get secret openbao-client-storage -o jsonpath='{.metadata.resourceVersion}')
	compute=$(kc management -n flux-system get secret openbao-client-compute -o jsonpath='{.metadata.resourceVersion}')
	[ -n "$job" ] && [ -n "$storage" ] && [ -n "$compute" ]
	run sb_up
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(kc management -n shared-services get job openbao-remote-auth -o jsonpath='{.metadata.uid}')" = "$job" ]
	[ "$(kc management -n flux-system get secret openbao-client-storage -o jsonpath='{.metadata.resourceVersion}')" = "$storage" ]
	[ "$(kc management -n flux-system get secret openbao-client-compute -o jsonpath='{.metadata.resourceVersion}')" = "$compute" ]
}

@test "make footprint reports the management, the storage and the compute cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"sandbox-management "* ]]
	[[ $output == *$'\n'"sandbox-storage "* ]]
	[[ $output == *$'\n'"sandbox-compute "* ]]
}

@test "make down leaves no network, container, cluster, state directory or OSD loop device" {
	run sb_make down
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
	run docker network inspect cobaltcore-sandbox
	[ "$status" -ne 0 ]
	[ -z "$(docker ps -aq --filter label=cobaltcore-sandbox=true)" ]
	[ -z "$(kind get clusters 2>/dev/null | grep -xE 'sandbox-(management|storage|compute)')" ]
	[ ! -e "$ROOT/.sandbox" ]
	[ -z "$(host_loop /var/lib/sandbox/osd-)" ]
	[ -z "$(host_loop '*/volumeDevices/sandbox-osd-')" ]
}
