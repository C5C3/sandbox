#!/usr/bin/env bats
# cluster_on_sandbox_network: a kind cluster of the sandbox's name is one of
# the sandbox when a node of it is on the sandbox network.

setup() {
	load helpers
	# kind lists a worker of sandbox-compute and no control-plane node, the
	# state an interrupted kind create or delete leaves.
	kind() {
		[ "$*" = "get nodes --name sandbox-compute" ] || return 1
		printf '%s\n' sandbox-compute-worker sandbox-compute-worker2
	}
}

@test "a cluster without its control-plane node is the sandbox's when a worker is on the sandbox network" {
	docker() {
		case ${!#} in
		sandbox-compute-worker) echo 'kind ' ;;
		sandbox-compute-worker2) echo 'cobaltcore-sandbox ' ;;
		*) return 1 ;;
		esac
	}
	run cluster_on_sandbox_network compute
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "a cluster with no node on the sandbox network is not the sandbox's" {
	docker() { echo 'kind '; }
	run cluster_on_sandbox_network compute
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
}

@test "a node that Docker cannot inspect is an error, not a cluster of another network" {
	docker() { return 1; }
	run cluster_on_sandbox_network compute
	[ "$status" -eq 2 ]
	[ "$output" = "error: cannot inspect Docker container sandbox-compute-worker" ]
}

@test "a cluster whose nodes kind cannot list is an error, not a cluster of another network" {
	run cluster_on_sandbox_network storage
	[ "$status" -eq 2 ]
	[ "$output" = "error: cannot list the nodes of kind cluster sandbox-storage" ]
}
