#!/usr/bin/env bats
# The lifecycle of the sandbox against a real Docker: it creates and removes a
# sandbox. It needs a host that passes the host check for all three roles and
# refuses to start while a sandbox exists.
#
# The tests run in file order, and each one starts from the state the one
# before left. A make target that fails exits 2, the status GNU make gives
# every failed recipe; its "Error 1" is the status of the script.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
ROLES=(management storage compute)
CONTAINERS=(sandbox-management-control-plane sandbox-storage-control-plane
	sandbox-compute-control-plane sandbox-compute-worker sandbox-registry)

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# config_copy <yq expression>: prints the path of a copy of config.yaml that
# the expression changed.
config_copy() {
	local path=$BATS_FILE_TMPDIR/config-$BATS_TEST_NUMBER.yaml
	yq "$1" "$ROOT/config.yaml" >"$path"
	printf '%s\n' "$path"
}

# failed_with <message>: the last run failed in its script with the message.
failed_with() {
	[ "$status" -eq 2 ] && [[ $output == *"Error 1"* && $output == *"$1"* ]]
}

# sandbox_exists: succeeds when any object of a sandbox exists on the host.
sandbox_exists() {
	docker network inspect cobaltcore-sandbox >/dev/null 2>&1 ||
		docker container inspect sandbox-registry >/dev/null 2>&1 ||
		kind get clusters | grep -qxE 'sandbox-(management|storage|compute)' ||
		[ -e "$ROOT/.sandbox" ]
}

absent_container() {
	! docker container inspect "$1" >/dev/null 2>&1
}

absent_network() {
	! docker network inspect cobaltcore-sandbox >/dev/null 2>&1
}

absent_cluster() {
	! kind get clusters | grep -qxF "sandbox-$1"
}

# container_ids: prints the name and ID of every container of the sandbox.
container_ids() {
	docker container inspect -f '{{.Name}} {{.Id}}' "${CONTAINERS[@]}"
}

# footprint_row <name>: prints the requests and the working set of the row of
# the last run's output.
footprint_row() {
	local line name requests working_set
	for line in "${lines[@]}"; do
		read -r name requests working_set <<<"$line"
		if [ "$name" = "$1" ]; then
			printf '%s %s\n' "$requests" "$working_set"
			return 0
		fi
	done
	return 1
}

# peer_readyz <a> <b>: asks the API of cluster a from the control-plane node
# of cluster b, at the address kind gives for the inside of the network.
peer_readyz() {
	kind get kubeconfig --internal --name "sandbox-$1" |
		docker exec -i "sandbox-$2-control-plane" sh -c \
			'cat > /tmp/peer && kubectl --kubeconfig /tmp/peer get --raw /readyz; rm -f /tmp/peer'
}

# mgmt_kubectl <argument>...: runs kubectl against sandbox-management.
mgmt_kubectl() {
	kubectl --kubeconfig "$KUBECONFIG_DIR/management.yaml" "$@"
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

# profile_file <name> <yaml>: writes the profile into the directory that
# SANDBOX_PROFILE_DIR names for the make calls of a test.
profile_file() {
	mkdir -p "$BATS_FILE_TMPDIR/profiles"
	printf '%s\n' "$2" >"$BATS_FILE_TMPDIR/profiles/$1.yaml"
}

# ready_at <kind/name> <revision>: the object in flux-system is Ready and
# reports the revision.
ready_at() {
	[ "$(mgmt_kubectl -n flux-system get "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.artifact.revision}{.status.lastAppliedRevision}')" = "True $2" ]
}

# pin: prints upstream.cobaltcore of config.yaml.
pin() {
	yq '.upstream.cobaltcore' "$ROOT/config.yaml"
}

# upstream_record: prints the annotation sandbox.c5c3.io/upstream of the
# source.
upstream_record() {
	mgmt_kubectl -n flux-system get ocirepository sandbox -o jsonpath='{.metadata.annotations.sandbox\.c5c3\.io/upstream}'
}

# status_is <object> <ready>: make status shows the object with the READY
# value.
status_is() {
	[ "$(sb_make status | awk -v object="$1" '$2 == object { print $3 }')" = "$2" ]
}

# absent_object <role> <argument>...: kubectl get with the arguments finds
# nothing on the role's cluster.
absent_object() {
	! kubectl --kubeconfig "$KUBECONFIG_DIR/$1.yaml" get "${@:2}" >/dev/null 2>&1
}

# hub_data <role>: prints the data of the ConfigMap sandbox-test/hub of the
# role's cluster as cluster, subnet and gateway.
hub_data() {
	kubectl --kubeconfig "$KUBECONFIG_DIR/$1.yaml" -n sandbox-test get configmap hub \
		-o jsonpath='{.data.cluster} {.data.subnet} {.data.gateway}'
}

# kube_config_unchanged: ~/.kube/config is what setup_file found.
kube_config_unchanged() {
	if [ -f ~/.kube/config ]; then
		[ "$(sha256sum <~/.kube/config)" = "$(cat "$BATS_FILE_TMPDIR/kubeconfig.sha256")" ]
	else
		[ "$(cat "$BATS_FILE_TMPDIR/kubeconfig.sha256")" = absent ]
	fi
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	if [ -f ~/.kube/config ]; then
		sha256sum <~/.kube/config >"$BATS_FILE_TMPDIR/kubeconfig.sha256"
	else
		echo absent >"$BATS_FILE_TMPDIR/kubeconfig.sha256"
	fi
	docker volume ls -q | sort >"$BATS_FILE_TMPDIR/volumes.before"
	touch "$BATS_FILE_TMPDIR/owned"
}

teardown_file() {
	rm -f "$ROOT/push-marker.tmp" "$ROOT/vendor/cobaltcore/deploy/local.tmp"
	if [ -f "$BATS_FILE_TMPDIR/foreign-network" ]; then
		docker network rm cobaltcore-sandbox >/dev/null
	fi
	if [ -f "$BATS_FILE_TMPDIR/foreign-registry" ]; then
		docker rm -f -v sandbox-registry >/dev/null
	fi
	if [ -f "$BATS_FILE_TMPDIR/foreign-cluster" ]; then
		kind delete cluster --name sandbox-management --kubeconfig "$BATS_FILE_TMPDIR/foreign-cluster.yaml"
	fi
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up checks the host, creates the sandbox and prints one KUBECONFIG line per cluster" {
	run sb_make up
	[ "$status" -eq 0 ]
	local i summary='' creating=''
	for i in "${!lines[@]}"; do
		if [[ -z $summary && ${lines[i]} == "preflight: "* ]]; then summary=$i; fi
		if [[ -z $creating && ${lines[i]} == "up: creating "* ]]; then creating=$i; fi
	done
	[ -n "$summary" ]
	[ -n "$creating" ]
	[ "$summary" -lt "$creating" ]
	[ "$(printf '%s\n' "${lines[@]: -3}")" = "export KUBECONFIG=$KUBECONFIG_DIR/management.yaml  # sandbox-management
export KUBECONFIG=$KUBECONFIG_DIR/storage.yaml  # sandbox-storage
export KUBECONFIG=$KUBECONFIG_DIR/compute.yaml  # sandbox-compute" ]
}

@test "the network has the configured subnet and the sandbox label" {
	run docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}} {{index .Labels "cobaltcore-sandbox"}}' cobaltcore-sandbox
	[ "$status" -eq 0 ]
	[ "$output" = "172.30.0.0/16 true" ]
}

@test "the three clusters have 1, 1 and 2 nodes and every node is Ready" {
	local -A expected=([management]=1 [storage]=1 [compute]=2)
	local role clusters
	clusters=$(kind get clusters)
	for role in "${ROLES[@]}"; do
		grep -qxF "sandbox-$role" <<<"$clusters"
		[ "$(kind get nodes --name "sandbox-$role" | wc -l)" -eq "${expected[$role]}" ]
		run kubectl --kubeconfig "$KUBECONFIG_DIR/$role.yaml" get nodes \
			-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
		[ "$status" -eq 0 ]
		[ "${#lines[@]}" -eq "${expected[$role]}" ]
		[[ $output != *False* && $output != *Unknown* ]]
	done
}

@test "the kubeconfig files are private and ignored by Git" {
	local role
	[ "$(stat -c %a "$KUBECONFIG_DIR")" = 700 ]
	for role in "${ROLES[@]}"; do
		[ "$(stat -c %a "$KUBECONFIG_DIR/$role.yaml")" = 600 ]
	done
	git -C "$ROOT" check-ignore -q .sandbox/kubeconfig/management.yaml
}

@test "every node and the registry are attached to the sandbox network only" {
	local container
	for container in "${CONTAINERS[@]}"; do
		[ "$(docker container inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$container")" = "cobaltcore-sandbox " ]
	done
}

@test "only the API servers publish a port, on 127.0.0.1" {
	local line api='^[^ ]+-control-plane 127\.0\.0\.1:[0-9]+->6443/tcp$'
	run docker ps --filter network=cobaltcore-sandbox --format '{{.Names}} {{.Ports}}'
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq "${#CONTAINERS[@]}" ]
	for line in "${lines[@]}"; do
		if [[ $line == *-control-plane* ]]; then
			[[ $line =~ $api ]]
		else
			[[ $line != *"->"* ]]
		fi
	done
}

@test "the registry answers the nodes by name and the host by address" {
	local address
	run docker exec sandbox-management-control-plane curl -fsS http://sandbox-registry:5000/v2/
	[ "$status" -eq 0 ]
	[ "$output" = "{}" ]
	address=$(docker container inspect -f '{{(index .NetworkSettings.Networks "cobaltcore-sandbox").IPAddress}}' sandbox-registry)
	timeout 2 bash -c '</dev/tcp/"$1"/5000' _ "$address"
}

@test "the API of each cluster answers the nodes of the other two" {
	local a b
	for a in "${ROLES[@]}"; do
		for b in "${ROLES[@]}"; do
			if [ "$a" = "$b" ]; then continue; fi
			run peer_readyz "$a" "$b"
			[ "$status" -eq 0 ]
			[ "$output" = ok ]
		done
	done
}

@test "make up prints the stages Ready on the three clusters before the KUBECONFIG lines" {
	run sb_make up
	[ "$status" -eq 0 ]
	[[ ${lines[-4]} =~ ^up:\ 3\ stages\ Ready\ on\ 3\ clusters\ at\ (latest@sha256:[0-9a-f]{64})$ ]]
	echo "${BASH_REMATCH[1]}" >"$BATS_FILE_TMPDIR/revision"
	[[ ${lines[-3]} == "export KUBECONFIG="* ]]
}

@test "make up checked out upstream at the pin and recorded it on the source" {
	[ "$(git --git-dir="$ROOT/vendor/cobaltcore/.git" rev-parse HEAD)" = "$(pin)" ]
	[ -f "$ROOT/vendor/cobaltcore/deploy/README.md" ]
	[ "$(upstream_record)" = "$(pin)" ]
}

@test "the FluxInstance runs four controllers on 2.10 with strict substitution and external artifacts" {
	run mgmt_kubectl -n flux-system get fluxinstance flux \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.lastAppliedRevision}'
	[ "$status" -eq 0 ]
	[[ $output == "True v2.10."* ]]
	run mgmt_kubectl -n flux-system get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
	[ "$status" -eq 0 ]
	[ "$(sort <<<"$output" | paste -sd ' ')" = "flux-operator helm-controller kustomize-controller source-controller source-watcher" ]
	run mgmt_kubectl -n flux-system get deployment kustomize-controller -o jsonpath='{.spec.template.spec.containers[0].args}'
	[ "$status" -eq 0 ]
	[[ $output == *'"--feature-gates=StrictPostBuildSubstitutions=true"'* ]]
	run mgmt_kubectl -n flux-system get deployment helm-controller -o jsonpath='{.spec.template.spec.containers[0].args}'
	[ "$status" -eq 0 ]
	[[ $output == *'"--feature-gates=ExternalArtifact=true"'* ]]
}

@test "the storage and compute clusters run no Flux" {
	local role
	for role in storage compute; do
		run kubectl --kubeconfig "$KUBECONFIG_DIR/$role.yaml" get namespace flux-system
		[ "$status" -ne 0 ]
		[[ $output == *NotFound* ]]
	done
}

@test "the source follows the registry by name and is Ready at the revision of make up" {
	[ "$(mgmt_kubectl -n flux-system get ocirepository sandbox -o jsonpath='{.spec.url}')" = oci://sandbox-registry:5000/sandbox ]
	ready_at ocirepository/sandbox "$(cat "$BATS_FILE_TMPDIR/revision")"
}

@test "the kubeconfig Secrets of storage and compute name the API inside the network" {
	local role
	for role in storage compute; do
		run mgmt_kubectl -n flux-system get secret "kubeconfig-$role" -o jsonpath='{.data.value}'
		[ "$status" -eq 0 ]
		[ "$(base64 -d <<<"$output" | yq '.clusters[0].cluster.server')" = "https://sandbox-$role-control-plane:6443" ]
	done
	run mgmt_kubectl -n flux-system get secret kubeconfig-management
	[ "$status" -ne 0 ]
	[[ $output == *NotFound* ]]
}

@test "cluster-vars holds the addresses of the configuration" {
	run mgmt_kubectl -n flux-system get configmap cluster-vars -o jsonpath='{.data.NETWORK_SUBNET} {.data.ADDRESSES_GATEWAY}'
	[ "$status" -eq 0 ]
	[ "$output" = "172.30.0.0/16 172.30.255.10" ]
}

@test "the module test wrote its ConfigMap with the role and the addresses on each cluster" {
	local role
	for role in "${ROLES[@]}"; do
		[ "$(hub_data "$role")" = "$role 172.30.0.0/16 172.30.255.10" ]
	done
}

@test "make status shows the FluxInstance, the source, the roots and the stages Ready" {
	local role object
	run sb_make status
	[ "$status" -eq 0 ]
	for object in FluxInstance/flux OCIRepository/sandbox; do
		[[ $output =~ (^|$'\n')management\ +$object\ +True\  ]]
	done
	for role in "${ROLES[@]}"; do
		for object in "Kustomization/cluster-$role" "Kustomization/$role-test"; do
			[[ $output =~ (^|$'\n')$role\ +$object\ +True\  ]]
		done
	done
	[ "${lines[-2]}" = "status: upstream $(pin)" ]
	[ "${lines[-1]}" = "status: 8 of 8 ready" ]
}

@test "the artifact holds the tree without .sandbox and .git" {
	local address
	address=$(docker container inspect -f '{{(index .NetworkSettings.Networks "cobaltcore-sandbox").IPAddress}}' sandbox-registry)
	mkdir "$BATS_TEST_TMPDIR/artifact"
	flux pull artifact "oci://$address:5000/sandbox:latest" --insecure-registry --output "$BATS_TEST_TMPDIR/artifact"
	[ -f "$BATS_TEST_TMPDIR/artifact/clusters/management/kustomization.yaml" ]
	[ ! -e "$BATS_TEST_TMPDIR/artifact/.sandbox" ]
	[ ! -e "$BATS_TEST_TMPDIR/artifact/.git" ]
	[ -f "$BATS_TEST_TMPDIR/artifact/vendor/cobaltcore/deploy/README.md" ]
	[ ! -e "$BATS_TEST_TMPDIR/artifact/vendor/cobaltcore/.git" ]
}

@test "make push publishes a changed tree and Flux applies it within 120 s" {
	local revision address
	touch "$ROOT/push-marker.tmp"
	run sb_make push
	rm -f "$ROOT/push-marker.tmp"
	[ "$status" -eq 0 ]
	[[ ${lines[-1]} =~ ^push:\ asked\ Flux\ on\ sandbox-management\ to\ fetch\ (latest@sha256:[0-9a-f]{64})$ ]]
	revision=${BASH_REMATCH[1]}
	[ "$revision" != "$(cat "$BATS_FILE_TMPDIR/revision")" ]
	address=$(docker container inspect -f '{{(index .NetworkSettings.Networks "cobaltcore-sandbox").IPAddress}}' sandbox-registry)
	mkdir "$BATS_TEST_TMPDIR/artifact"
	flux pull artifact "oci://$address:5000/sandbox:latest" --insecure-registry --output "$BATS_TEST_TMPDIR/artifact"
	[ -f "$BATS_TEST_TMPDIR/artifact/push-marker.tmp" ]
	eventually 120 ready_at ocirepository/sandbox "$revision"
	eventually 120 ready_at kustomization/compute-test "$revision"
}

@test "make push records a changed checkout, and make up at another pin keeps it and every container" {
	local before
	touch "$ROOT/vendor/cobaltcore/deploy/local.tmp"
	run sb_make push
	[ "$status" -eq 0 ]
	[ "$(upstream_record)" = "$(pin)-modified" ]
	before=$(container_ids)
	run sb_make up CONFIG="$(config_copy '.upstream.cobaltcore = "bbb35e61e8df6b0e215c6a04732f2ad78759fe76"')"
	failed_with "vendor: vendor/cobaltcore is at $(pin) with local changes, the configuration pins bbb35e61e8df6b0e215c6a04732f2ad78759fe76; run make vendor to discard them"
	[ "$(container_ids)" = "$before" ]
	[ -f "$ROOT/vendor/cobaltcore/deploy/local.tmp" ]
	rm "$ROOT/vendor/cobaltcore/deploy/local.tmp"
}

@test "a broken kubeconfig Secret shows in make status and make up repairs it" {
	mgmt_kubectl -n flux-system patch secret kubeconfig-storage --type merge \
		-p "{\"data\":{\"value\":\"$(printf broken | base64)\"}}" >/dev/null
	[ "$(mgmt_kubectl -n flux-system get secret kubeconfig-storage -o jsonpath='{.metadata.labels.reconcile\.fluxcd\.io/watch}')" = Enabled ]
	eventually 60 status_is Kustomization/storage-test False
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 7 of 8 ready" ]
	run sb_make up
	[ "$status" -eq 0 ]
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 8 of 8 ready" ]
}

@test "a profile without the module of storage removes its stage and what the stage applied" {
	profile_file nostorage $'clusters: [management, storage, compute]\nmodules:\n  management: [test]\n  compute: [test]'
	run env SANDBOX_PROFILE_DIR="$BATS_FILE_TMPDIR/profiles" make --no-print-directory -C "$ROOT" up PROFILE=nostorage
	[ "$status" -eq 0 ]
	eventually 60 absent_object management -n flux-system kustomization storage-test
	eventually 60 absent_object storage namespace sandbox-test
	[ "$(mgmt_kubectl -n flux-system get kustomization cluster-storage -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 7 of 7 ready" ]
	run sb_make up
	[ "$status" -eq 0 ]
	[ "$(hub_data storage)" = "storage 172.30.0.0/16 172.30.255.10" ]
}

@test "make up refuses a profile that does not list an existing cluster" {
	profile_file mgmtonly 'clusters: [management]'
	run env SANDBOX_PROFILE_DIR="$BATS_FILE_TMPDIR/profiles" make --no-print-directory -C "$ROOT" up PROFILE=mgmtonly
	failed_with "sandbox-storage exists, the profile mgmtonly does not list it; run make down first"
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 8 of 8 ready" ]
}

@test "make up stops at a missing profile before the host check" {
	local line
	run sb_make up PROFILE=full
	failed_with "profile: $ROOT/profiles/full.yaml not found"
	for line in "${lines[@]}"; do
		[[ $line != preflight:* && $line != "ok "* && $line != "warn "* && $line != "FAIL "* ]]
	done
}

@test "make up-storage refuses a cluster the profile does not list" {
	profile_file mgmtonly 'clusters: [management]'
	run env SANDBOX_PROFILE_DIR="$BATS_FILE_TMPDIR/profiles" make --no-print-directory -C "$ROOT" up-storage PROFILE=mgmtonly
	failed_with "the profile mgmtonly does not list the cluster storage"
}

@test "a second make up keeps every container" {
	local before
	before=$(container_ids)
	run sb_make up
	[ "$status" -eq 0 ]
	[ "$(container_ids)" = "$before" ]
}

@test "make footprint reports every cluster, the registry and the total" {
	local row requests working_set
	run sb_make footprint
	[ "$status" -eq 0 ]
	for row in sandbox-management sandbox-storage sandbox-compute registry total; do
		read -r requests working_set <<<"$(footprint_row "$row")"
		[ "$working_set" -gt 0 ]
		if [ "$row" = registry ]; then
			[ "$requests" = - ]
		else
			[ "$requests" -gt 0 ]
		fi
	done
}

@test "make footprint restores a missing kubeconfig file" {
	rm "$KUBECONFIG_DIR/storage.yaml"
	run sb_make footprint
	[ "$status" -eq 0 ]
	[ -f "$KUBECONFIG_DIR/storage.yaml" ]
}

@test "make up-compute refuses a running compute cluster with another worker count" {
	run sb_make up-compute CONFIG="$(config_copy '.switches["hypervisor-nodes"] = 2')"
	failed_with "sandbox-compute has 1 worker nodes, the configuration says 2; run make down first"
}

@test "make up refuses a registry that runs another image" {
	run sb_make up-management CONFIG="$(config_copy '.registry.image = "registry:2"')"
	failed_with "container sandbox-registry runs registry:3, the configuration says registry:2; run make down first"
}

@test "make up refuses a registry that does not run" {
	docker stop sandbox-registry >/dev/null
	run sb_make up-management
	failed_with "container sandbox-registry exists but is not running; run make down first"
}

@test "make footprint fails without a total when a cluster does not answer" {
	local line
	docker stop sandbox-storage-control-plane >/dev/null
	run sb_make footprint
	failed_with "footprint: cannot list the pods of sandbox-storage"
	for line in "${lines[@]}"; do
		[[ $line != total* ]]
	done
}

@test "make down refuses to start without the Docker daemon and removes nothing" {
	run env DOCKER_HOST=tcp://127.0.0.1:1 make --no-print-directory -C "$ROOT" down
	failed_with "cannot reach the Docker daemon"
	docker container inspect "${CONTAINERS[@]}" >/dev/null
}

@test "make down removes the sandbox, leaves no new volume and keeps the checkout of upstream" {
	local container role
	run sb_make down
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
	[ -d "$ROOT/vendor/cobaltcore/.git" ]
	for container in "${CONTAINERS[@]}"; do
		absent_container "$container"
	done
	for role in "${ROLES[@]}"; do
		absent_cluster "$role"
	done
	absent_network
	[ ! -e "$ROOT/.sandbox" ]
	[ -z "$(docker volume ls -q | sort | comm -13 "$BATS_FILE_TMPDIR/volumes.before" -)" ]
}

@test "~/.kube/config is unchanged" {
	kube_config_unchanged
}

@test "a second make down finds nothing left" {
	run sb_make down
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
}

@test "make footprint without a sandbox reports a total of 0" {
	run sb_make footprint
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "${lines[@]: -2}" | tr -s ' ')" = "CLUSTER REQUESTS_MIB WORKING_SET_MIB
total 0 0" ]
}

@test "make status and make push without a sandbox" {
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: sandbox-management does not exist" ]
	run sb_make push
	failed_with "container sandbox-registry does not run; run make up first"
}

@test "make up-compute creates the network, the registry and only the compute cluster" {
	run sb_make up-compute CONFIG="$(config_copy '.switches["hypervisor-nodes"] = 2')"
	[ "$status" -eq 0 ]
	[[ $output == *"up: sandbox-management does not exist, Flux applies nothing until make up-management has run"* ]]
	run kubectl --kubeconfig "$KUBECONFIG_DIR/compute.yaml" get namespace flux-system
	[ "$status" -ne 0 ]
	docker network inspect cobaltcore-sandbox >/dev/null
	[ "$(docker container inspect -f '{{.State.Running}}' sandbox-registry)" = true ]
	[ "$(kind get nodes --name sandbox-compute | wc -l)" -eq 3 ]
	absent_cluster management
	absent_cluster storage
}

@test "make up refuses a network with another subnet" {
	run sb_make up CONFIG="$(config_copy '.network.subnet = "172.31.0.0/16" | .addresses.pool = "172.31.255.0/24" | .addresses.gateway = "172.31.255.10" | .addresses.dns = "172.31.255.53" | .addresses.rabbitmq = "172.31.255.11"')"
	failed_with "Docker network cobaltcore-sandbox has subnet 172.30.0.0/16, the configuration says 172.31.0.0/16; run make down first"
}

@test "make up-compute refuses a compute cluster without its control-plane node" {
	docker rm -f sandbox-compute-control-plane >/dev/null
	run sb_make up-compute CONFIG="$(config_copy '.switches["hypervisor-nodes"] = 2')"
	failed_with "sandbox-compute has no control-plane node; run make down first"
}

@test "make down removes the compute-only sandbox" {
	run sb_make down
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
}

@test "make up-management, then make up-storage attaches the storage cluster to the hub" {
	run sb_make up-management
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 1\ stages\ Ready\ on\ 1\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 4 of 4 ready" ]

	run sb_make up-storage
	[ "$status" -eq 0 ]
	[[ ${lines[-2]} =~ ^up:\ 2\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "$(hub_data storage)" = "storage 172.30.0.0/16 172.30.255.10" ]
	run sb_make status
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "status: 6 of 6 ready" ]

	run sb_make down
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
	kube_config_unchanged
}

@test "make up and make down leave a network they did not create alone" {
	touch "$BATS_FILE_TMPDIR/foreign-network"
	docker network create cobaltcore-sandbox >/dev/null
	run sb_make up-management
	failed_with "Docker network cobaltcore-sandbox exists and was not created by the sandbox"
	mkdir -p "$ROOT/.sandbox/kubeconfig"
	run sb_make down
	failed_with "Docker network cobaltcore-sandbox was not created by the sandbox"
	[[ $output == *"error: left over: Docker network cobaltcore-sandbox"* ]]
	[ ! -e "$ROOT/.sandbox" ]
	docker network inspect cobaltcore-sandbox >/dev/null
	docker network rm cobaltcore-sandbox >/dev/null
	rm "$BATS_FILE_TMPDIR/foreign-network"
}

@test "make up and make down leave a registry container they did not create alone" {
	touch "$BATS_FILE_TMPDIR/foreign-registry"
	docker run -d --name sandbox-registry "$(yq .registry.image "$ROOT/config.yaml")" >/dev/null
	run sb_make up-management
	failed_with "container sandbox-registry exists and was not created by the sandbox"
	run sb_make down
	failed_with "container sandbox-registry was not created by the sandbox"
	[[ $output == *"error: left over: container sandbox-registry"* ]]
	absent_network
	docker container inspect sandbox-registry >/dev/null
	docker rm -f -v sandbox-registry >/dev/null
	rm "$BATS_FILE_TMPDIR/foreign-registry"
}

@test "make up and make down leave a kind cluster they did not create alone" {
	touch "$BATS_FILE_TMPDIR/foreign-cluster"
	kind create cluster --name sandbox-management --kubeconfig "$BATS_FILE_TMPDIR/foreign-cluster.yaml" >/dev/null
	run sb_make up-management
	failed_with "sandbox-management exists on another Docker network and was not created by the sandbox; remove or rename it"
	run sb_make down
	failed_with "kind cluster sandbox-management is not on Docker network cobaltcore-sandbox and was not created by the sandbox"
	[[ $output == *"error: left over: kind cluster sandbox-management"* ]]
	absent_container sandbox-registry
	absent_network
	docker container inspect sandbox-management-control-plane >/dev/null
	kind delete cluster --name sandbox-management --kubeconfig "$BATS_FILE_TMPDIR/foreign-cluster.yaml"
	rm "$BATS_FILE_TMPDIR/foreign-cluster"
}

@test "make up fails with Docker's message on a subnet another network uses" {
	local subnet base
	subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' bridge)
	base=${subnet%/*}; base=${base%.*}
	run sb_make up CONFIG="$(config_copy ".network.subnet = \"$subnet\" | .addresses.pool = \"$subnet\" | .addresses.gateway = \"$base.10\" | .addresses.dns = \"$base.53\" | .addresses.rabbitmq = \"$base.11\"")"
	failed_with "cannot create Docker network cobaltcore-sandbox with subnet $subnet: Error response from daemon:"
	absent_network
	absent_container sandbox-registry
	absent_cluster management
	absent_cluster storage
	absent_cluster compute
}

@test "make up stops at a failed host check and creates nothing" {
	run sb_make up CONFIG="$(config_copy '.network.subnet = "foo"')"
	failed_with "host check failed, nothing was created"
	[[ $output == *"FAIL config: config: network.subnet 'foo' is not an IPv4 CIDR"* ]]
	absent_network
	absent_container sandbox-registry
	absent_cluster management
	absent_cluster storage
	absent_cluster compute
	[ ! -e "$ROOT/.sandbox" ]
}
