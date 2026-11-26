#!/usr/bin/env bats
# scripts/lib/storage.sh: the loop devices of sandbox-storage and their
# PersistentVolumes, against a storage node that a docker function plays
# from files in the test's directory, and a kubectl function that records
# what it applies.

setup() {
	load helpers
	NODE=sandbox-storage-control-plane
	STATE=$BATS_TEST_TMPDIR/node
	CALLS=$BATS_TEST_TMPDIR/calls
	mkdir -- "$STATE"
	export SANDBOX_OSD_SIZE=10Gi
	fake_node
}

# fake_node: replaces docker, kubectl and sleep. The node holds the device
# nodes loop0 to loop7 and loop-control in $STATE/dev, reads 7:1 for loop1
# from $STATE/loop1, lists the block devices loop0 to loop7, nvme0n1 with
# two partitions and dm-0 in /sys/class/block, from $STATE/class, and no
# udev record, holds the OSD files of $STATE/files, one "<path> <size>" per
# line, and the attached devices of $STATE/attached, one "<device> <path>"
# per line. A new device is /dev/loop3, then loop4 and so on. The script of
# mknod lines goes to $STATE/mknod, that of the udev records to
# $STATE/records and the records it creates to $STATE/udev, each manifest
# kubectl applies to $BATS_TEST_TMPDIR/applied, and every call, on one line,
# to $CALLS. A file $STATE/<step>-fails makes the step fail;
# $STATE/attach-fails holds the number of attaches that fail before one
# succeeds.
fake_node() {
	{
		for i in 0 1 2 3 4 5 6 7; do echo "loop$i"; done
		printf '%s\n' loop-control null pts shm
	} >"$STATE/dev"
	echo 7:1 >"$STATE/loop1"
	printf '%s\n' 252:0 7:0 7:1 7:2 7:3 7:4 7:5 7:6 7:7 259:0 259:1 259:2 >"$STATE/class"
	: >"$STATE/files"
	: >"$STATE/attached"
	docker() {
		local arg n
		echo "docker ${*//$'\n'/; }" >>"$CALLS"
		[ "$1" = exec ] && [ "$2" = "$NODE" ] || return 1
		shift 2
		case $* in
		*/sys/block/loop1/dev*) cat "$STATE/loop1" 2>/dev/null || : ;;
		"ls /dev") cat "$STATE/dev" ;;
		*/sys/class/block/*) cat "$STATE/class" ;;
		*"ls /run/udev/data"*) cat "$STATE/udev" 2>/dev/null || : ;;
		"sh -ec mkdir -p /run/udev/data"*)
			if [ -e "$STATE/udev-fails" ]; then
				echo "sh: 2: cannot create /run/udev/data/b7:1: Read-only file system" >&2
				return 1
			fi
			printf '%s' "$3" >>"$STATE/records"
			sed -n 's|^: >/run/udev/data/||p' <<<"$3" >>"$STATE/udev"
			;;
		"sh -ec "*)
			if [ -e "$STATE/mknod-fails" ]; then
				echo "mknod: /dev/loop8: Operation not permitted" >&2
				return 1
			fi
			printf '%s' "$3" >>"$STATE/mknod"
			;;
		"losetup --list --noheadings --output NAME --associated "*)
			awk -v f="$7" '$2 == f { print $1 }' "$STATE/attached"
			;;
		"mkdir -p /var/lib/sandbox") ;;
		"truncate -s "*)
			if [ -e "$STATE/truncate-fails" ]; then
				echo "truncate: cannot open '$4' for writing: No space left on device" >&2
				return 1
			fi
			echo "$4 $((${3%G} * 1073741824))" >>"$STATE/files"
			;;
		"losetup --find --show "*)
			n=$(cat "$STATE/attach-fails" 2>/dev/null || echo 0)
			if [ "$n" != 0 ]; then
				echo $((n - 1)) >"$STATE/attach-fails"
				echo "losetup: $4: failed to set up loop device: Device or resource busy" >&2
				return 1
			fi
			arg=/dev/loop$((3 + $(grep -c . "$STATE/attached")))
			echo "$arg $4" >>"$STATE/attached"
			echo "$arg"
			;;
		"sh -c "*stat*)
			if [ -e "$STATE/read-fails" ]; then
				echo "Error response from daemon: container $NODE is not running" >&2
				return 1
			fi
			cat "$STATE/files"
			;;
		*) return 1 ;;
		esac
	}
	kubectl() {
		echo "kubectl $*" >>"$CALLS"
		echo --- >>"$BATS_TEST_TMPDIR/applied"
		cat >>"$BATS_TEST_TMPDIR/applied"
		if [ -e "$STATE/apply-fails" ]; then
			echo 'error: the server could not find the requested resource' >&2
			return 1
		fi
	}
	sleep() {
		echo "sleep $*" >>"$CALLS"
	}
	restore_kubeconfig() {
		echo "restore_kubeconfig $1" >>"$CALLS"
	}
	attached_roles() {
		echo "management storage"
	}
}

# storage_profile <modules>: selects a profile that lists the modules, a
# YAML list, for sandbox-storage.
storage_profile() {
	profile_with "clusters: [management, storage]
modules:
  storage: $1"
	export SANDBOX_PROFILE_FILE=$BATS_TEST_TMPDIR/profiles/case.yaml
}

# mknod_lines <first> <last>: prints the mknod lines of loop<first> to
# loop<last>.
mknod_lines() {
	local i
	for ((i = $1; i <= $2; i++)); do
		echo "mknod -m 660 /dev/loop$i b 7 $i"
	done
}

# calls <pattern>: prints the number of recorded calls that contain the
# pattern.
calls() {
	grep -cF -- "$1" "$CALLS" 2>/dev/null || :
}

@test "storage_node prints the node of sandbox-storage" {
	[ "$(storage_node)" = "$NODE" ]
}

@test "loop_nodes creates each missing device node with major 7 and the index as minor" {
	run loop_nodes "$NODE"
	[ "$status" -eq 0 ]
	[ "$(<"$STATE/mknod")" = "$(mknod_lines 8 255)" ]
}

@test "loop_nodes creates nothing on a node that has every device node" {
	mknod_lines 8 255 | awk '{ print substr($4, 6) }' >>"$STATE/dev"
	run loop_nodes "$NODE"
	[ "$status" -eq 0 ]
	[ ! -e "$STATE/mknod" ]
	[ "$(calls 'sh -ec')" = 0 ]
}

@test "loop_nodes refuses a kernel whose loop minors are not their index, before any mknod" {
	echo 7:16 >"$STATE/loop1"
	run loop_nodes "$NODE"
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: the loop devices of this kernel do not number their minors by index (loop.max_part is set), $NODE reads 7:16 for loop1" ]
	[ ! -e "$STATE/mknod" ]
}

@test "loop_nodes creates the device nodes on a node without /sys/block/loop1" {
	rm -- "$STATE/loop1"
	run loop_nodes "$NODE"
	[ "$status" -eq 0 ]
	[ "$(<"$STATE/mknod")" = "$(mknod_lines 8 255)" ]
}

@test "loop_nodes creates /dev/loop-control on a node without it, and none on a node that has it" {
	grep -vxF loop-control "$STATE/dev" >"$STATE/dev.new"
	mv -- "$STATE/dev.new" "$STATE/dev"
	run loop_nodes "$NODE"
	[ "$status" -eq 0 ]
	[ "$(head -n 1 "$STATE/mknod")" = "mknod -m 660 /dev/loop-control c 10 237" ]
	[ "$(grep -c loop-control "$STATE/mknod")" = 1 ]

	rm -- "$STATE/mknod"
	echo loop-control >>"$STATE/dev"
	run loop_nodes "$NODE"
	[ "$status" -eq 0 ]
	[ "$(grep -c loop-control "$STATE/mknod")" = 0 ]
}

@test "loop_nodes fails with the last line of a failed mknod" {
	touch "$STATE/mknod-fails"
	run loop_nodes "$NODE"
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: cannot create the loop device nodes on $NODE: mknod: /dev/loop8: Operation not permitted" ]
}

# record_lines <record>...: prints the lines that create the udev records.
record_lines() {
	local record
	for record in "$@"; do
		echo ": >/run/udev/data/$record"
	done
}

@test "udev_records creates an empty udev record for each block device and each loop device that lacks one" {
	local i
	echo b7:0 >"$STATE/udev"
	run udev_records "$NODE"
	[ "$status" -eq 0 ]
	[ "$(<"$STATE/records")" = "mkdir -p /run/udev/data
$(record_lines b252:0 b7:1 b7:2 b7:3 b7:4 b7:5 b7:6 b7:7 b259:0 b259:1 b259:2
		for ((i = 8; i < 256; i++)); do record_lines "b7:$i"; done)" ]
}

@test "udev_records creates nothing on a node that has every record" {
	udev_records "$NODE"
	rm -- "$STATE/records" "$CALLS"
	run udev_records "$NODE"
	[ "$status" -eq 0 ]
	[ ! -e "$STATE/records" ]
	[ "$(calls 'sh -ec')" = 0 ]
}

@test "udev_records fails with the last line of a failed creation" {
	touch "$STATE/udev-fails"
	run udev_records "$NODE"
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: cannot create the udev records on $NODE: sh: 2: cannot create /run/udev/data/b7:1: Read-only file system" ]
}

@test "block_device prints the device of an attached file and creates and attaches nothing" {
	echo "/dev/loop7 /var/lib/sandbox/osd-0.img" >"$STATE/attached"
	run block_device "$NODE" 0
	[ "$status" -eq 0 ]
	[ "$output" = /dev/loop7 ]
	[ "$(calls truncate)" = 0 ]
	[ "$(calls 'losetup --find')" = 0 ]
}

@test "block_device creates the sparse file, attaches it, logs it on stderr and prints the device" {
	run block_device "$NODE" 0
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
	[[ ${lines[0]} == *": attaching /var/lib/sandbox/osd-0.img to /dev/loop3 on $NODE" ]]
	[ "${lines[1]}" = /dev/loop3 ]
	[ "$(calls "truncate -s 10G /var/lib/sandbox/osd-0.img")" = 1 ]
	[ "$(calls truncate)" = 1 ]
	[ "$(calls "losetup --find --show /var/lib/sandbox/osd-0.img")" = 1 ]
	[ "$(<"$STATE/files")" = "/var/lib/sandbox/osd-0.img 10737418240" ]

	# The device alone is on stdout.
	[ "$(block_device "$NODE" 0 2>/dev/null)" = /dev/loop3 ]
}

@test "block_device fails with the last line of a failed truncate" {
	touch "$STATE/truncate-fails"
	run block_device "$NODE" 0
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: cannot create /var/lib/sandbox/osd-0.img on $NODE: truncate: cannot open '/var/lib/sandbox/osd-0.img' for writing: No space left on device" ]
	[ "$(calls 'losetup --find')" = 0 ]
}

@test "block_device attaches on the third try after two failed attaches, one second apart" {
	echo 2 >"$STATE/attach-fails"
	run block_device "$NODE" 0
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = /dev/loop3 ]
	[ "$(calls 'losetup --find --show')" = 3 ]
	[ "$(calls 'sleep 1')" = 2 ]
}

@test "block_device fails after five failed attaches" {
	echo 1000 >"$STATE/attach-fails"
	run block_device "$NODE" 0
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: cannot attach /var/lib/sandbox/osd-0.img on $NODE: losetup: /var/lib/sandbox/osd-0.img: failed to set up loop device: Device or resource busy" ]
	[ "$(calls 'losetup --find --show')" = 5 ]
	[ "$(calls 'sleep 1')" = 4 ]
}

@test "block_volume prints a block volume of the size on the device, bound to the storage node" {
	run block_volume 0 /dev/loop7
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind, .metadata.name, .metadata.labels]' - <<<"$output")" = \
		'["v1","PersistentVolume","sandbox-osd-0",{"sandbox.c5c3.io/cluster":"storage"}]' ]
	[ "$(yq -o=json -I=0 '.spec' - <<<"$output")" = \
		'{"capacity":{"storage":"10Gi"},"volumeMode":"Block","accessModes":["ReadWriteOnce"],"persistentVolumeReclaimPolicy":"Retain","storageClassName":"sandbox-block","local":{"path":"/dev/loop7"},"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["sandbox-storage-control-plane"]}]}]}}}' ]
}

@test "ensure_block_devices attaches three files on an empty node and applies their volumes in order, and a second run changes nothing" {
	local kubeconfig first
	kubeconfig=$(kubeconfig_path storage)
	storage_profile '[block-devices]'
	export SANDBOX_OSD_COUNT=3
	run ensure_block_devices
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == *": preparing the loop devices of sandbox-storage: 3 of 10Gi" ]]
	[ "$(grep -F 'losetup --find --show' "$CALLS" | awk '{ print $NF }' | paste -sd ' ')" = \
		"/var/lib/sandbox/osd-0.img /var/lib/sandbox/osd-1.img /var/lib/sandbox/osd-2.img" ]
	[ "$(grep -c '^kubectl ' "$CALLS")" = 3 ]
	[ "$(grep '^kubectl ' "$CALLS" | sort -u)" = \
		"kubectl --kubeconfig $kubeconfig apply --server-side --force-conflicts --field-manager=sandbox -f -" ]
	[ "$(yq ea -o=json -I=0 '[[.metadata.name, .spec.local.path]]' "$BATS_TEST_TMPDIR/applied")" = \
		'[["sandbox-osd-0","/dev/loop3"],["sandbox-osd-1","/dev/loop4"],["sandbox-osd-2","/dev/loop5"]]' ]
	[ "$(calls "restore_kubeconfig storage")" = 1 ]
	[ "$(grep -c . "$STATE/udev")" = 260 ]
	first=$(<"$BATS_TEST_TMPDIR/applied")

	rm -- "$CALLS" "$BATS_TEST_TMPDIR/applied"
	mknod_lines 8 255 | awk '{ print substr($4, 6) }' >>"$STATE/dev"
	run ensure_block_devices
	[ "$status" -eq 0 ]
	[ "$(calls truncate)" = 0 ]
	[ "$(calls 'losetup --find')" = 0 ]
	[ "$(calls 'sh -ec')" = 0 ]
	[ "$(grep -c '^kubectl ' "$CALLS")" = 3 ]
	[ "$(<"$BATS_TEST_TMPDIR/applied")" = "$first" ]
}

@test "ensure_block_devices refuses a node with more OSD files than switches.osd-count before it touches a device" {
	local i
	for i in 0 1 2; do
		echo "/var/lib/sandbox/osd-$i.img 10737418240" >>"$STATE/files"
	done
	storage_profile '[block-devices]'
	export SANDBOX_OSD_COUNT=1
	run ensure_block_devices
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: $NODE holds 3 OSD files, switches.osd-count says 1; run make down first" ]
	[ ! -e "$STATE/mknod" ]
	[ ! -e "$STATE/records" ]
	[ "$(calls 'losetup --find')" = 0 ]
	[ "$(calls kubectl)" = 0 ]
}

@test "ensure_block_devices refuses an OSD file of another size than switches.osd-size" {
	echo "/var/lib/sandbox/osd-0.img 10737418240" >"$STATE/files"
	storage_profile '[block-devices]'
	export SANDBOX_OSD_COUNT=1 SANDBOX_OSD_SIZE=20Gi
	run ensure_block_devices
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: /var/lib/sandbox/osd-0.img on $NODE has 10737418240 bytes, switches.osd-size says 20Gi; run make down first" ]
	[ "$(calls kubectl)" = 0 ]
}

@test "ensure_block_devices fails with the last line of a failed read of the directory or a failed apply" {
	storage_profile '[block-devices]'
	export SANDBOX_OSD_COUNT=1
	touch "$STATE/read-fails"
	run ensure_block_devices
	[ "$status" -eq 1 ]
	[ "$output" = "error: block-devices: cannot read /var/lib/sandbox on $NODE: Error response from daemon: container $NODE is not running" ]

	rm -- "$STATE/read-fails"
	touch "$STATE/apply-fails"
	run ensure_block_devices
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot apply the PersistentVolume sandbox-osd-0 on sandbox-storage: error: the server could not find the requested resource" ]
}

@test "ensure_block_devices calls neither docker nor kubectl for a profile without block-devices or without an attached storage cluster" {
	storage_profile '[rook-crds]'
	export SANDBOX_OSD_COUNT=1
	run ensure_block_devices
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$CALLS" ]

	storage_profile '[block-devices]'
	attached_roles() { echo management; }
	run ensure_block_devices
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$CALLS" ]
}
