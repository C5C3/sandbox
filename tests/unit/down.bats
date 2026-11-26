#!/usr/bin/env bats
# down.sh with docker and kind replaced by exported functions. It runs from a
# copy of scripts/, so the .sandbox it removes is the copy's and not the
# repository's.

setup() {
	load helpers
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -- "$BATS_TEST_TMPDIR/.sandbox"
	# The check reads no loop device of the host.
	mkdir -- "$BATS_TEST_TMPDIR/sys-block"
	export SANDBOX_SYS_BLOCK=$BATS_TEST_TMPDIR/sys-block
}

@test "a node that Docker cannot inspect is recorded and the following steps still run" {
	kind() {
		case $* in
		"get clusters") echo sandbox-compute ;;
		"get nodes --name sandbox-compute") echo sandbox-compute-worker ;;
		*) return 1 ;;
		esac
	}
	# docker info answers, no container or network is listed, and the
	# inspection of the node fails.
	docker() {
		case $1 in
		info | ps | network) ;;
		*) return 1 ;;
		esac
	}
	export -f kind docker
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot inspect Docker container sandbox-compute-worker
error: cannot check the Docker network of kind cluster sandbox-compute
down: removing $BATS_TEST_TMPDIR/.sandbox
error: left over: kind cluster sandbox-compute" ]
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox" ]
}

# slow_node <running>: replaces kind, docker and sleep with exported
# functions for a sandbox-management on the sandbox network, without a
# registry and a network, whose first kind delete fails as when Docker gives
# up on a node that does not exit in time. The node answers Running true to
# the first <running> inspections of its state and false after them. The
# functions log the deletes and the pauses in the test's directory, and a
# second delete removes the cluster.
slow_node() {
	export RUNNING=$1 STATE=$BATS_TEST_TMPDIR
	kind() {
		case $* in
		"get clusters") [ -e "$STATE/deleted" ] || echo sandbox-management ;;
		"get nodes --name sandbox-management") [ -e "$STATE/deleted" ] || echo sandbox-management-control-plane ;;
		"delete cluster --name sandbox-management --kubeconfig "*)
			echo delete >>"$STATE/deletes"
			if [ "$(grep -c '' "$STATE/deletes")" -eq 1 ]; then
				echo 'ERROR: failed to delete cluster "sandbox-management": did not receive an exit event' >&2
				return 1
			fi
			touch "$STATE/deleted"
			;;
		*) return 1 ;;
		esac
	}
	docker() {
		case $* in
		info* | "ps "* | "network ls "*) ;;
		"container inspect -f {{.State.Running}} sandbox-management-control-plane")
			echo inspect >>"$STATE/inspects"
			if [ "$(grep -c '' "$STATE/inspects")" -le "$RUNNING" ]; then echo true; else echo false; fi
			;;
		"container inspect -f "*" sandbox-management-control-plane") echo 'cobaltcore-sandbox ' ;;
		*) return 1 ;;
		esac
	}
	sleep() {
		echo "$*" >>"$STATE/pauses"
	}
	export -f kind docker sleep
}

@test "a cluster that kind cannot delete while its node stops is deleted again once the node stopped" {
	slow_node 2
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "down: deleting kind cluster sandbox-management
ERROR: failed to delete cluster \"sandbox-management\": did not receive an exit event
down: waiting up to 120 s for the nodes of sandbox-management to stop
down: deleting kind cluster sandbox-management again
down: removing $BATS_TEST_TMPDIR/.sandbox
down: nothing left" ]
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/deletes")" = 2 ]
	[ "$(<"$BATS_TEST_TMPDIR/pauses")" = $'2\n2' ]
}

@test "a node that still runs after 120 s is recorded, and the cluster is not deleted again" {
	slow_node 1000
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 1 ]
	[ "${lines[-3]}" = "error: kind could not delete sandbox-management, a node still runs after 120 s" ]
	[ "${lines[-1]}" = "error: left over: kind cluster sandbox-management" ]
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/deletes")" = 1 ]
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/pauses")" = 60 ]
	[ "$(sort -u "$BATS_TEST_TMPDIR/pauses")" = 2 ]
}

# storage_sandbox <running>: replaces kind and docker with exported functions
# for a sandbox-storage on the sandbox network, without a registry and a
# network, whose node answers Running <running>. losetup --list in the node
# prints $BATS_TEST_TMPDIR/losetup; a file list-fails or detach-fails there
# makes losetup --list or losetup -d fail. Every call of kind and docker goes
# to $BATS_TEST_TMPDIR/calls, and the delete removes the cluster.
storage_sandbox() {
	export RUNNING=$1 STATE=$BATS_TEST_TMPDIR
	kind() {
		echo "kind $*" >>"$STATE/calls"
		case $* in
		"get clusters") [ -e "$STATE/deleted" ] || echo sandbox-storage ;;
		"get nodes --name sandbox-storage") [ -e "$STATE/deleted" ] || echo sandbox-storage-control-plane ;;
		"delete cluster --name sandbox-storage --kubeconfig "*) touch "$STATE/deleted" ;;
		*) return 1 ;;
		esac
	}
	docker() {
		echo "docker $*" >>"$STATE/calls"
		case $* in
		info* | "ps "* | "network ls "*) ;;
		"container inspect -f {{.State.Running}} sandbox-storage-control-plane") echo "$RUNNING" ;;
		"container inspect -f "*" sandbox-storage-control-plane") echo 'cobaltcore-sandbox ' ;;
		"exec sandbox-storage-control-plane losetup --list --noheadings --output NAME,BACK-FILE")
			if [ -e "$STATE/list-fails" ]; then
				echo "losetup: cannot open /dev/loop-control: Permission denied" >&2
				return 1
			fi
			cat "$STATE/losetup" 2>/dev/null || :
			;;
		"exec sandbox-storage-control-plane losetup -d "*)
			if [ -e "$STATE/detach-fails" ]; then
				echo "losetup: ${!#}: detach failed: No such device or address" >&2
				return 1
			fi
			;;
		*) return 1 ;;
		esac
	}
	export -f kind docker
}

# kubelet's path of the volume sandbox-osd-0 of a pod.
KUBELET_PATH=/var/lib/kubelet/plugins/kubernetes.io~local-volume/volumeDevices/sandbox-osd-0/0d5c6e2f-2a8b-4f6e-9a35-7d3b1c0e4f11

@test "down.sh detaches kubelet's loop device and the OSD's, in this order, before it deletes the storage cluster" {
	storage_sandbox true
	printf '%s\n' "/dev/loop3 /var/lib/sandbox/osd-0.img" "/dev/loop9 $KUBELET_PATH" "/dev/loop0 /var/lib/snapd/x.snap" \
		>"$BATS_TEST_TMPDIR/losetup"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "down: detaching 2 loop devices of sandbox-storage
down: deleting kind cluster sandbox-storage
down: removing $BATS_TEST_TMPDIR/.sandbox
down: nothing left" ]
	[ "$(grep -E 'losetup -d|kind delete cluster' "$BATS_TEST_TMPDIR/calls" | sed 's/ --kubeconfig .*//')" = \
		"docker exec sandbox-storage-control-plane losetup -d /dev/loop9
docker exec sandbox-storage-control-plane losetup -d /dev/loop3
kind delete cluster --name sandbox-storage" ]
}

@test "down.sh detaches nothing without an OSD device, on a node that does not run and without a storage cluster" {
	storage_sandbox true
	echo "/dev/loop0 /var/lib/snapd/x.snap" >"$BATS_TEST_TMPDIR/losetup"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[[ $output != *detaching* ]]
	[ "$(grep -c 'losetup -d' "$BATS_TEST_TMPDIR/calls")" = 0 ]

	rm -f -- "$BATS_TEST_TMPDIR/deleted" "$BATS_TEST_TMPDIR/calls"
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox"
	storage_sandbox false
	echo "/dev/loop3 /var/lib/sandbox/osd-0.img" >"$BATS_TEST_TMPDIR/losetup"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[[ $output != *detaching* ]]
	[ "$(grep -c losetup "$BATS_TEST_TMPDIR/calls")" = 0 ]
	[ "${lines[-1]}" = "down: nothing left" ]

	rm -f -- "$BATS_TEST_TMPDIR/calls"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "down: nothing left" ]
	[ "$(grep -c losetup "$BATS_TEST_TMPDIR/calls")" = 0 ]
}

@test "a failed list or detach of the loop devices is recorded, and the cluster and the state directory still go" {
	storage_sandbox true
	echo "/dev/loop3 /var/lib/sandbox/osd-0.img" >"$BATS_TEST_TMPDIR/losetup"
	touch "$BATS_TEST_TMPDIR/list-fails"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "error: cannot list the loop devices of sandbox-storage-control-plane: losetup: cannot open /dev/loop-control: Permission denied" ]
	[ -e "$BATS_TEST_TMPDIR/deleted" ]
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox" ]

	rm -f -- "$BATS_TEST_TMPDIR/deleted" "$BATS_TEST_TMPDIR/list-fails"
	mkdir -- "$BATS_TEST_TMPDIR/.sandbox"
	touch "$BATS_TEST_TMPDIR/detach-fails"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "down: detaching 1 loop devices of sandbox-storage" ]
	[ "${lines[1]}" = "error: cannot detach the loop device /dev/loop3 of sandbox-storage-control-plane: losetup: /dev/loop3: detach failed: No such device or address" ]
	[ -e "$BATS_TEST_TMPDIR/deleted" ]
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox" ]
}

@test "the check reports a loop device on an OSD file with the command that detaches it, and none on another file" {
	local dir=$BATS_TEST_TMPDIR/sys-block
	docker() {
		case $1 in
		info | ps | network) ;;
		*) return 1 ;;
		esac
	}
	kind() {
		case $* in
		"get clusters") ;;
		*) return 1 ;;
		esac
	}
	export -f kind docker
	mkdir -p -- "$dir/loop3/loop"
	echo "/var/lib/sandbox/osd-0.img (deleted)" >"$dir/loop3/loop/backing_file"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: left over: loop device /dev/loop3 on /var/lib/sandbox/osd-0.img (deleted); detach it with sudo losetup -d /dev/loop3" ]

	rm -rf -- "$dir/loop3"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "down: nothing left" ]

	mkdir -p -- "$dir/loop0/loop"
	echo /var/lib/snapd/x.snap >"$dir/loop0/loop/backing_file"
	run "$BATS_TEST_TMPDIR/scripts/down.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "down: nothing left" ]
}
