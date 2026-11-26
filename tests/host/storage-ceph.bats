#!/usr/bin/env bats
# Rook Ceph on loop devices in sandbox-storage, against a real Docker:
# points 1 and 2 of the README. It runs the scratch profile ceph, the modules
# block-devices, rook-crds, rook-operator and ceph-cluster on sandbox-storage
# and none on sandbox-management; then the scratch profile ceph-3, the same
# with switches.osd-count 3. Both live outside the tree in the test's
# directory. It checks the sparse OSD file, its loop device and its
# PersistentVolume, the release of Rook from the hub, the health, the pools
# and the clients of Ceph and the requests of its daemons, then, with the
# RBD client of tests/host/fixtures/storage-ceph-client.yaml on
# sandbox-management (ADR-0036), host networking, the name of the storage
# node, writes as cinder, the pool caps of both clients and a restarted
# monitor; then a second make up, make footprint, the growth to three OSDs,
# the refusal of fewer, and make down. It needs a host that passes the host
# check for the management and storage roles, has more than 10 % of the
# filesystem under Docker free and reaches ghcr.io, charts.rook.io,
# docker.io and quay.io, refuses to start while a sandbox exists and ends
# with make down. It needs no control plane.
#
# The tests run in file order, and each one starts from the state the one
# before left. No test prints a key or the data of a Secret: a key goes from
# its Secret into the client pod over stdin, and userKey is read by its
# length.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
FIXTURE=$BATS_TEST_DIRNAME/fixtures/storage-ceph-client.yaml
CLUSTER=$ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/ceph/cluster/cluster.yaml
NODE=sandbox-storage-control-plane
MON=$NODE:3300

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

# tools <argument>...: runs the command in the Ceph toolbox, for at most
# 60 s, because a ceph command waits for a monitor that is gone.
tools() {
	timeout 60 kubectl --kubeconfig "$KUBECONFIG_DIR/storage.yaml" -n rook-ceph exec deploy/rook-ceph-tools -- "$@"
}

# ceph_json <argument>...: runs ceph with the arguments in the toolbox and
# prints its JSON.
ceph_json() {
	tools ceph --connect-timeout 10 "$@" --format json
}

# node_address: prints the address of the storage node on the sandbox
# network.
node_address() {
	docker inspect -f '{{(index .NetworkSettings.Networks "cobaltcore-sandbox").IPAddress}}' "$NODE"
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

# key_to_client <client>: copies userKey of the client's Secret into
# /tmp/<client>.key in the client pod, with mode 600, over stdin.
key_to_client() {
	kc storage -n rook-ceph get secret "rook-ceph-client-$1" -o jsonpath='{.data.userKey}' | base64 -d |
		kc management -n default exec -i sandbox-verify-ceph -- sh -c "umask 077 && cat >/tmp/$1.key"
}

# rbd_as <client> <argument>...: runs rbd in the client pod as the client,
# against the monitor under the node's name.
rbd_as() {
	kc management -n default exec sandbox-verify-ceph -- rbd -m "$MON" --id "$1" --keyfile "/tmp/$1.key" "${@:2}"
}

# healthy: succeeds when Ceph reports HEALTH_OK.
healthy() {
	[ "$(ceph_json status 2>/dev/null | jq -r '.health.status')" = HEALTH_OK ]
}

# osds_under_node: prints the name and the status of each OSD under the CRUSH
# host of the node, one per line.
osds_under_node() {
	ceph_json osd tree | jq -r --arg host "$NODE" '
		(.nodes[] | select(.type == "host" and .name == $host) | .children) as $children
		| .nodes[] | select(.type == "osd" and (.id as $id | $children | index($id))) | "\(.name) \(.status)"' | sort
}

# pools: prints for the pools volumes, backups and .mgr their name, size,
# whether they carry the application rbd, and the type of the choose step of
# their CRUSH rule, as JSON.
pools() {
	local rules
	rules=$(ceph_json osd crush rule dump) || return 1
	ceph_json osd pool ls detail | jq -c --argjson rules "$rules" '
		[.[] | select(.pool_name | IN("volumes", "backups", ".mgr"))
		 | .crush_rule as $rule
		 | [.pool_name, .size, (.application_metadata | has("rbd")),
		    ($rules[] | select(.rule_id == $rule) | [.steps[] | select(.op | startswith("choose")) | .type][0])]]
		| sort'
}

# daemon_resources <app> <container>: prints the memory request and limit of
# the container of the pod with the label app.
daemon_resources() {
	kc storage -n rook-ceph get pods -l "app=$1" -o json |
		jq -r --arg c "$2" '[.items[0].spec.containers[] | select(.name == $c) | .resources.requests.memory, .resources.limits.memory] | join(" ")'
}

# mon_pod: prints the name and the uid of the pod of the monitor.
mon_pod() {
	kc storage -n rook-ceph get pods -l app=rook-ceph-mon -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.uid}'
}

# new_mon_ready <old uid>: succeeds when a monitor pod of another uid is
# Ready.
new_mon_ready() {
	kc storage -n rook-ceph get pods -l app=rook-ceph-mon -o json |
		jq -e --arg old "$1" '[.items[] | select(.metadata.uid != $old and .metadata.deletionTimestamp == null)
			| select(.status.conditions[]? | .type == "Ready" and .status == "True")] | length == 1' >/dev/null
}

# grown: succeeds when Ceph reports HEALTH_OK with three OSDs up and in and
# every placement group active+clean.
grown() {
	ceph_json status 2>/dev/null | jq -e '.health.status == "HEALTH_OK"
		and .osdmap.num_up_osds == 3 and .osdmap.num_in_osds == 3 and .pgmap.num_pgs > 0
		and ([.pgmap.pgs_by_state[] | select(.state_name != "active+clean")] | length == 0)' >/dev/null
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
	mkdir -p -- "$BATS_FILE_TMPDIR/profiles"
	cat >"$BATS_FILE_TMPDIR/profiles/ceph.yaml" <<'EOF'
clusters: [management, storage]
modules:
  storage: [block-devices, rook-crds, rook-operator, ceph-cluster]
EOF
	cat >"$BATS_FILE_TMPDIR/profiles/ceph-3.yaml" <<'EOF'
clusters: [management, storage]
modules:
  storage: [block-devices, rook-crds, rook-operator, ceph-cluster]
switches:
  osd-count: 3
EOF
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=ceph prepares the loop device before it waits and brings 4 stages Ready on two clusters" {
	local preparing attaching waiting
	run sb_up ceph
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[-3]} =~ ^up:\ 4\ stages\ Ready\ on\ 2\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-2]} == "export KUBECONFIG="* && ${lines[-1]} == "export KUBECONFIG="* ]]
	preparing=$(grep -nxF "up: preparing the loop devices of sandbox-storage: 1 of 10Gi" <<<"$output" | cut -d : -f 1)
	attaching=$(grep -nE "^up: attaching /var/lib/sandbox/osd-0\.img to /dev/loop[0-9]+ on $NODE\$" <<<"$output" | cut -d : -f 1)
	waiting=$(grep -nE '^up: waiting for 6 roots and stages to be Ready at ' <<<"$output" | cut -d : -f 1)
	[ -n "$preparing" ] && [ -n "$attaching" ] && [ -n "$waiting" ]
	[ "$preparing" -lt "$attaching" ]
	[ "$attaching" -lt "$waiting" ]
}

@test "the node holds the sparse OSD file of 10 GiB, and the host a loop device on it" {
	local size blocks unit
	read -r size blocks unit < <(docker exec "$NODE" stat -c '%s %b %B' /var/lib/sandbox/osd-0.img)
	[ "$size" = 10737418240 ]
	[ $((blocks * unit)) -lt "$size" ]
	run host_loop /var/lib/sandbox/osd-0.img
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} =~ ^/dev/loop[0-9]+\ /var/lib/sandbox/osd-0\.img$ ]]
	echo "${lines[0]%% *}" >"$BATS_FILE_TMPDIR/device"
}

@test "the PersistentVolume sandbox-osd-0 is a block volume of sandbox-block on that loop device, Bound to a claim in rook-ceph" {
	[ "$(kc storage get pv sandbox-osd-0 -o json | jq -r '[.spec.volumeMode, .spec.storageClassName, .spec.local.path, .status.phase, .spec.claimRef.namespace] | join(" ")')" = \
		"Block sandbox-block $(<"$BATS_FILE_TMPDIR/device") Bound rook-ceph" ]
}

@test "the release of Rook is Ready on the hub, its operator runs on sandbox-storage without a restart and allows loop devices, and sandbox-storage runs no Flux" {
	[ "$(kc management -n flux-system get helmrelease storage-rook-ceph -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
	[ "$(kc storage -n rook-ceph get deployment rook-ceph-operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = True ]
	[ "$(kc storage -n rook-ceph get pods -l app=rook-ceph-operator -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}')" = 0 ]
	[ "$(kc storage -n rook-ceph get configmap rook-ceph-operator-config -o jsonpath='{.data.ROOK_CEPH_ALLOW_LOOP_DEVICES}')" = true ]
	[ "$(kc storage get crd clientprofiles.csi.ceph.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')" = True ]
	run kc storage get namespace flux-system
	[ "$status" -ne 0 ]
}

@test "Ceph reports HEALTH_OK with one monitor in quorum, an active manager and osd.0 up and in under the host of the node" {
	local st
	st=$(ceph_json status)
	[ "$(jq -r '.health.status' <<<"$st")" = HEALTH_OK ]
	[ "$(jq '.quorum_names | length' <<<"$st")" = 1 ]
	[ "$(jq '.mgrmap.available' <<<"$st")" = true ]
	[ "$(jq -c '[.osdmap.num_up_osds, .osdmap.num_in_osds]' <<<"$st")" = '[1,1]' ]
	[ "$(osds_under_node)" = "osd.0 up" ]
}

@test "the pools volumes, backups and .mgr have size 1 and failure domain osd, the first two the application rbd" {
	[ "$(pools)" = '[[".mgr",1,false,"osd"],["backups",1,true,"osd"],["volumes",1,true,"osd"]]' ]
}

@test "cinder and cinder-backup have the rbd caps of their pool, and their Secrets a userKey" {
	local client
	[ "$(tools ceph auth get client.cinder --format json | jq -cS '.[0].caps')" = \
		'{"mgr":"profile rbd pool=volumes","mon":"profile rbd","osd":"profile rbd pool=volumes"}' ]
	[ "$(tools ceph auth get client.cinder-backup --format json | jq -cS '.[0].caps')" = \
		'{"mgr":"profile rbd pool=backups","mon":"profile rbd","osd":"profile rbd pool=backups"}' ]
	for client in cinder cinder-backup; do
		[ "$(kc storage -n rook-ceph get secret "rook-ceph-client-$client" -o jsonpath='{.data.userKey}' | wc -c)" -gt 0 ]
	done
}

@test "monitor, manager and OSD request 512Mi, 256Mi and 1Gi under the limits 1Gi, 512Mi and 2Gi" {
	[ "$(daemon_resources rook-ceph-mon mon)" = "512Mi 1Gi" ]
	[ "$(daemon_resources rook-ceph-mgr mgr)" = "256Mi 512Mi" ]
	[ "$(daemon_resources rook-ceph-osd osd)" = "1Gi 2Gi" ]
}

@test "monitor and OSD run on host networking and answer on the node's address, which the host reaches" {
	local address osd
	address=$(node_address)
	[ -n "$address" ]
	[ "$(kc storage -n rook-ceph get pods -l app=rook-ceph-mon -o jsonpath='{.items[*].spec.hostNetwork}')" = true ]
	[ "$(kc storage -n rook-ceph get pods -l app=rook-ceph-osd -o jsonpath='{.items[*].spec.hostNetwork}')" = true ]
	[ "$(kc storage -n rook-ceph get configmap rook-ceph-mon-endpoints -o jsonpath='{.data.data}')" = "a=$address:3300" ]
	osd=$(ceph_json osd dump | jq -r '.osds[] | select(.osd == 0) | .public_addrs.addrvec[] | select(.type == "v2") | .addr')
	[[ $osd =~ ^${address//./\\.}:([0-9]+)$ ]]
	[ "${BASH_REMATCH[1]}" -ge 6800 ] && [ "${BASH_REMATCH[1]}" -le 7300 ]
	timeout 5 bash -c '</dev/tcp/"$1"/3300' _ "$address"
	timeout 5 bash -c '</dev/tcp/"$1"/"$2"' _ "$address" "${BASH_REMATCH[1]}"
}

@test "the storage node publishes the API server on 127.0.0.1 and nothing else" {
	run docker port "$NODE"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} =~ ^6443/tcp\ -\>\ 127\.0\.0\.1:[0-9]+$ ]]
}

@test "the client pod on sandbox-management resolves the storage node by its container name" {
	local image
	image=$(yq '.spec.cephVersion.image' "$CLUSTER")
	[[ $image == quay.io/ceph/ceph:* ]]
	IMAGE=$image yq '.spec.containers[0].image = strenv(IMAGE)' "$FIXTURE" | kc management apply -f -
	kc management -n default wait --for=condition=Ready pod/sandbox-verify-ceph --timeout=900s
	[ "$(kc management -n default exec sandbox-verify-ceph -- getent hosts "$NODE" | awk '{ print $1 }')" = "$(node_address)" ]
}

@test "cinder creates and writes an image in volumes from sandbox-management, which the toolbox reads" {
	key_to_client cinder
	key_to_client cinder-backup
	[ "$(kc management -n default exec sandbox-verify-ceph -- stat -c %a /tmp/cinder.key /tmp/cinder-backup.key)" = $'600\n600' ]
	run rbd_as cinder create --size 16 volumes/sandbox-verify
	echo "$output"
	[ "$status" -eq 0 ]
	run rbd_as cinder bench --io-type write --io-total 4M volumes/sandbox-verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(tools rbd info volumes/sandbox-verify --format json | jq '.size')" = 16777216 ]
}

@test "cinder cannot list backups, cinder-backup can" {
	run rbd_as cinder ls backups
	[ "$status" -ne 0 ]
	run rbd_as cinder-backup ls backups
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "after the image is removed and the monitor's pod deleted, Ceph is healthy again within 300 s at the same address, which the client still reaches" {
	local endpoints old
	run rbd_as cinder rm volumes/sandbox-verify
	echo "$output"
	[ "$status" -eq 0 ]
	endpoints=$(kc storage -n rook-ceph get configmap rook-ceph-mon-endpoints -o jsonpath='{.data.data}')
	old=$(mon_pod)
	kc storage -n rook-ceph delete pod "${old%% *}" --wait=false
	eventually 300 new_mon_ready "${old#* }"
	eventually 300 healthy
	[ "$(kc storage -n rook-ceph get configmap rook-ceph-mon-endpoints -o jsonpath='{.data.data}')" = "$endpoints" ]
	run rbd_as cinder ls volumes
	echo "$output"
	[ "$status" -eq 0 ]
	# rbd reports the missing ceph.conf on stderr; the image list is stdout.
	[ -z "$(rbd_as cinder ls volumes 2>/dev/null)" ]
}

@test "a second make up PROFILE=ceph attaches nothing and keeps the volume and the pod of osd.0" {
	local volume pod
	volume=$(kc storage get pv sandbox-osd-0 -o jsonpath='{.metadata.uid}')
	pod=$(kc storage -n rook-ceph get pods -l ceph-osd-id=0 -o jsonpath='{.items[0].metadata.uid}')
	[ -n "$volume" ] && [ -n "$pod" ]
	run sb_up ceph
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output != *"up: attaching"* ]]
	[ "$(kc storage get pv sandbox-osd-0 -o jsonpath='{.metadata.uid}')" = "$volume" ]
	[ "$(kc storage -n rook-ceph get pods -l ceph-osd-id=0 -o jsonpath='{.items[0].metadata.uid}')" = "$pod" ]
}

@test "make footprint reports the management and the storage cluster with one OSD" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"sandbox-management "* ]]
	[[ $output == *$'\n'"sandbox-storage "* ]]
}

@test "make up PROFILE=ceph-3 attaches two more files, and within 900 s three OSDs under the one host serve every pool at size 2" {
	run sb_up ceph-3
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"up: preparing the loop devices of sandbox-storage: 3 of 10Gi"$'\n'* ]]
	grep -qE "^up: attaching /var/lib/sandbox/osd-1\.img to /dev/loop[0-9]+ on $NODE\$" <<<"$output"
	grep -qE "^up: attaching /var/lib/sandbox/osd-2\.img to /dev/loop[0-9]+ on $NODE\$" <<<"$output"
	[[ $output != *"up: attaching /var/lib/sandbox/osd-0.img"* ]]
	eventually 900 grown
	[ "$(kc storage get pv -l sandbox.c5c3.io/cluster=storage -o jsonpath='{.items[*].status.phase}')" = "Bound Bound Bound" ]
	[ "$(osds_under_node)" = $'osd.0 up\nosd.1 up\nosd.2 up' ]
	[ "$(pools)" = '[[".mgr",2,false,"osd"],["backups",2,true,"osd"],["volumes",2,true,"osd"]]' ]
}

@test "make footprint reports the management and the storage cluster with three OSDs" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"sandbox-storage "* ]]
}

@test "make up PROFILE=ceph refuses the sandbox of three OSDs and leaves cluster-vars and the OSDs alone" {
	run sb_up ceph
	echo "$output"
	# make exits 2 for a failed recipe; "Error 1" is the status of up.sh.
	[ "$status" -eq 2 ]
	[[ $output == *"Error 1"* ]]
	[[ $output == *"error: block-devices: $NODE holds 3 OSD files, switches.osd-count says 1; run make down first"* ]]
	[ "$(kc management -n flux-system get configmap cluster-vars -o jsonpath='{.data.SWITCHES_OSD_COUNT}')" = 3 ]
	[ "$(ceph_json status | jq '.osdmap.num_up_osds')" = 3 ]
}

@test "make down detaches the loop devices and leaves no network, container, cluster, state directory or OSD loop device" {
	run sb_make down
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qE '^down: detaching [0-9]+ loop devices of sandbox-storage$' <<<"$output"
	[ "${lines[-1]}" = "down: nothing left" ]
	run docker network inspect cobaltcore-sandbox
	[ "$status" -ne 0 ]
	[ -z "$(docker ps -aq --filter label=cobaltcore-sandbox=true)" ]
	[ -z "$(kind get clusters 2>/dev/null | grep -xE 'sandbox-(management|storage)')" ]
	[ ! -e "$ROOT/.sandbox" ]
	[ -z "$(host_loop /var/lib/sandbox/osd-)" ]
	[ -z "$(host_loop '*/volumeDevices/sandbox-osd-')" ]
}
