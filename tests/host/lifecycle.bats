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

@test "make down removes the sandbox and leaves no new volume" {
	local container role
	run sb_make down
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]
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
	if [ -f ~/.kube/config ]; then
		[ "$(sha256sum <~/.kube/config)" = "$(cat "$BATS_FILE_TMPDIR/kubeconfig.sha256")" ]
	else
		[ "$(cat "$BATS_FILE_TMPDIR/kubeconfig.sha256")" = absent ]
	fi
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

@test "make up-compute creates the network, the registry and only the compute cluster" {
	run sb_make up-compute CONFIG="$(config_copy '.switches["hypervisor-nodes"] = 2')"
	[ "$status" -eq 0 ]
	docker network inspect cobaltcore-sandbox >/dev/null
	[ "$(docker container inspect -f '{{.State.Running}}' sandbox-registry)" = true ]
	[ "$(kind get nodes --name sandbox-compute | wc -l)" -eq 3 ]
	absent_cluster management
	absent_cluster storage
}

@test "make up refuses a network with another subnet" {
	run sb_make up CONFIG="$(config_copy '.network.subnet = "172.31.0.0/16"')"
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
	local subnet
	subnet=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' bridge)
	run sb_make up CONFIG="$(config_copy ".network.subnet = \"$subnet\"")"
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
