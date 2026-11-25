#!/usr/bin/env bats
# down.sh with docker and kind replaced by exported functions. It runs from a
# copy of scripts/, so the .sandbox it removes is the copy's and not the
# repository's.

setup() {
	load helpers
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -- "$BATS_TEST_TMPDIR/.sandbox"
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
