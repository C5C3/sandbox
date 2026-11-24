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
