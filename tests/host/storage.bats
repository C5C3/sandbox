#!/usr/bin/env bats
# The profile storage against a real Docker: Keystone and Cinder on the RBD
# backend ceph1 of the Ceph of sandbox-storage, on the TLS bus, with the key
# hand-off. It runs the committed profile, then the same profile with a
# copy of config.yaml whose switches.cinder-backup is true, then the
# committed configuration again. It checks the stage of controlplane, the
# ControlPlane, the backend and its Deployment, make verify with its six
# checks and what it leaves, then with the backup target cephbk the nine
# checks twice, each raising keyGeneration of the CephClient cinder-backup
# by one, make footprint, the removal of the backup target and make down.
# It needs a host that passes the host check for the management and the
# storage role, has more than 10 % of the filesystem under Docker free,
# resolves nip.io names to private addresses, has openssl and the
# OpenStack CLI, and reaches ghcr.io, charts.rook.io,
# charts.external-secrets.io, docker.io and quay.io; it refuses to start
# while a sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. No test prints a key or the data of a Secret: keys are
# compared by the sha256 of userKey, and the raw keys stay in variables of
# the test, which only compares them with the output of make verify.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
# The checks of make verify on storage, and with cinder-backup on.
CHECKS="keystone-token keystone-catalog cinder-catalog cinder-volume rbd-backend rbd-volume"
BACKUP_CHECKS="$CHECKS rbd-backup rbd-restore rbd-rotation"

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# sb_up [<argument>...]: runs make up with the profile storage.
sb_up() {
	SANDBOX_STAGE_TIMEOUT=3600 sb_make up PROFILE=storage "$@"
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

# os <argument>...: runs the OpenStack CLI as the admin of make env.
os() {
	bash -c 'eval "$(make --no-print-directory -C "$1" env)" && openstack "${@:2}"' _ "$ROOT" "$@"
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

# config_copy <yq expression>: prints the path of a copy of config.yaml that
# the expression changed.
config_copy() {
	local path=$BATS_FILE_TMPDIR/config-$BATS_TEST_NUMBER.yaml
	yq "$1" "$ROOT/config.yaml" >"$path"
	printf '%s\n' "$path"
}

# controlplane: prints the ControlPlane openstack/controlplane as JSON.
controlplane() {
	kc management -n openstack get controlplanes.c5c3.io controlplane -o json
}

# check_ids: prints the ids of the check lines in $output, separated by
# spaces.
check_ids() {
	grep -E '^(ok|FAIL) ' <<<"$output" | cut -d ' ' -f 2 | tr -d : | paste -sd ' '
}

# generation: prints keyGeneration of the CephClient rook-ceph/cinder-backup.
generation() {
	kc storage -n rook-ceph get cephclient cinder-backup -o jsonpath='{.spec.security.cephx.keyGeneration}'
}

# secret_hash: prints the sha256 of userKey of
# openstack/ceph-client-cinder-backup on sandbox-management.
secret_hash() {
	kc management -n openstack get secret ceph-client-cinder-backup -o jsonpath='{.data.userKey}' | base64 -d |
		sha256sum | cut -d ' ' -f 1
}

# ceph_hash: prints the sha256 of the key Ceph holds for
# client.cinder-backup, computed in the toolbox.
ceph_hash() {
	tools sh -c 'key=$(ceph auth get-key client.cinder-backup) && printf %s "$key" | sha256sum' | cut -d ' ' -f 1
}

# rook_key: prints the raw key of client.cinder-backup from the Secret Rook
# writes. Only a comparison reads it.
rook_key() {
	kc storage -n rook-ceph get secret rook-ceph-client-cinder-backup -o jsonpath='{.data.userKey}' | base64 -d
}

# available <deployment>: succeeds when the Deployment in openstack on
# sandbox-management is Available.
available() {
	[ "$(kc management -n openstack get deployment "$1" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = True ]
}

# backup_target <name>: succeeds when the ControlPlane holds the backup
# target of that name and controlplane-cinder-backup is Available, or, for
# none, when it holds none and the Deployment is gone.
backup_target() {
	if [ "$1" = none ]; then
		[ "$(controlplane | jq -r '.spec.services.cinder | has("backupBackend")')" = false ] &&
			[ -z "$(kc management -n openstack get deployment controlplane-cinder-backup --ignore-not-found -o name)" ]
	else
		[ "$(controlplane | jq -r '.spec.services.cinder.backupBackend.name // empty')" = "$1" ] &&
			available controlplane-cinder-backup
	fi
}

# no_leftovers: succeeds when no volume and no backup carries a
# sandbox-verify name and the pool volumes holds no image.
no_leftovers() {
	local names images
	names=$(os volume list -f value -c Name && os volume backup list -f value -c Name) || return 1
	images=$(tools rbd ls volumes) || return 1
	! grep -q sandbox-verify <<<"$names" && [ -z "$images" ]
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

@test "make up PROFILE=storage brings 18 stages Ready on two clusters" {
	run sb_up
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qE '^up: 18 stages Ready on 2 clusters at latest@sha256:[0-9a-f]{64}$' <<<"$output"
	[ -z "$(kind get clusters 2>/dev/null | grep -xF sandbox-compute)" ]
}

@test "the stage of controlplane depends on ceph-keys, and the ControlPlane runs keystone and cinder on the brownfield bus with the backend ceph1 on sandbox-storage and no backup target" {
	local json subnet
	subnet=$(yq '.network.subnet' "$ROOT/config.yaml")
	[ "$(kc management -n flux-system get kustomization management-controlplane -o json |
		jq '[.spec.dependsOn[].name] | index("management-ceph-keys") != null')" = true ]
	json=$(controlplane)
	[ "$(jq -c '.spec.services | keys' <<<"$json")" = '["cinder","keystone"]' ]
	[ "$(jq -c '.spec.infrastructure.messaging | [.secretRef.name, .tls.caBundleSecretRef.name, has("clusterRef")]' <<<"$json")" = \
		'["rabbitmq-transport-url","shared-rabbitmq-tls",false]' ]
	[ "$(jq -c '[.spec.services.cinder.backends[] | [.name, .type, .rbd.monitors, .rbd.networks]]' <<<"$json")" = \
		"[[\"ceph1\",\"RBD\",[\"sandbox-storage-control-plane:3300\"],[\"$subnet\"]]]" ]
	[ "$(jq '.spec.services.cinder | has("backupBackend")' <<<"$json")" = false ]
}

@test "the CinderBackend ceph1 is Ready, its Deployment controlplane-cinder-volume-ceph1 Available, and no Deployment controlplane-cinder-backup exists" {
	[ "$(kc management -n openstack get cinderbackends.cinder.openstack.c5c3.io ceph1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
	available controlplane-cinder-volume-ceph1
	[ -z "$(kc management -n openstack get deployment controlplane-cinder-backup --ignore-not-found -o name)" ]
}

@test "make verify passes the six checks of Keystone, Cinder and ceph1" {
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 6 of 6 checks passed" ]
	[ "$(check_ids)" = "$CHECKS" ]
}

@test "within 120 s no volume or backup carries a sandbox-verify name, and the pool volumes holds no image" {
	eventually 120 no_leftovers
}

@test "make up PROFILE=storage with cinder-backup on brings 18 stages Ready, and within 600 s the ControlPlane holds cephbk and controlplane-cinder-backup is Available" {
	run sb_up CONFIG="$(config_copy '.switches["cinder-backup"] = true')"
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qE '^up: 18 stages Ready on 2 clusters at latest@sha256:[0-9a-f]{64}$' <<<"$output"
	eventually 600 backup_target cephbk
}

@test "make verify passes the nine checks, raises keyGeneration of cinder-backup by one, leaves Ceph's new key in openstack and prints neither key" {
	local before old new
	before=$(generation)
	[[ $before =~ ^[0-9]+$ ]]
	old=$(rook_key)
	[ -n "$old" ]
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 9 of 9 checks passed" ]
	[ "$(check_ids)" = "$BACKUP_CHECKS" ]
	[ "$(generation)" = $((before + 1)) ]
	[ "$(secret_hash)" = "$(ceph_hash)" ]
	new=$(rook_key)
	[ -n "$new" ] && [ "$new" != "$old" ]
	[[ $output != *"$old"* ]]
	[[ $output != *"$new"* ]]
}

@test "a second make verify passes the nine checks and raises keyGeneration once more" {
	local before
	before=$(generation)
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 9 of 9 checks passed" ]
	[ "$(generation)" = $((before + 1)) ]
	[ "$(secret_hash)" = "$(ceph_hash)" ]
}

@test "make footprint reports the management and the storage cluster" {
	run sb_make footprint
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"sandbox-management "* ]]
	[[ $output == *$'\n'"sandbox-storage "* ]]
}

@test "make up PROFILE=storage with the committed configuration removes cephbk and controlplane-cinder-backup within 600 s, and make verify passes the six checks" {
	run sb_up
	echo "$output"
	[ "$status" -eq 0 ]
	grep -qE '^up: 18 stages Ready on 2 clusters at latest@sha256:[0-9a-f]{64}$' <<<"$output"
	eventually 600 backup_target none
	run sb_make verify
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "verify: 6 of 6 checks passed" ]
	[ "$(check_ids)" = "$CHECKS" ]
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
	rm "$BATS_FILE_TMPDIR/owned"
}
