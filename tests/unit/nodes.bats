#!/usr/bin/env bats
# scripts/lib/nodes.sh: the system bus, the labels and the annotation of the
# worker nodes of sandbox-compute, with kind, docker and kubectl replaced by
# functions that record each call in calls.

setup() {
	load helpers
	KC=$(kubeconfig_path compute)
	export CALLS=$BATS_TEST_TMPDIR/calls KC
	LABELS='openstack.c5c3.io/chassis=true openstack.c5c3.io/nova-compute-pool=lab nova.openstack.cloud.sap/virt-driver=kvm cobaltcore.cloud.sap/node-hypervisor-lifecycle=skip-tests'
}

# attached <modules of compute>: loads a profile with the management and the
# compute cluster and the modules given for compute, both attached, and
# records each restore of a kubeconfig file in restored.
attached() {
	profile_with "clusters: [management, compute]
modules:
  management: [test]
  compute: [$1]"
	profile_load
	attached_roles() { echo "management compute"; }
	restore_kubeconfig() { echo "$1" >>"$BATS_TEST_TMPDIR/restored"; }
}

# kind_nodes <node>...: replaces kind with a function that lists the nodes
# given for sandbox-compute.
kind_nodes() {
	export NODES="$*"
	kind() {
		printf 'kind %s\n' "$*" >>"$CALLS"
		[ "$*" = "get nodes --name sandbox-compute" ] || return 1
		printf '%s\n' $NODES
	}
}

# node_answers: replaces docker with a function that answers the calls of
# node_bus. The exported BUS says whether systemd answers on the bus: up,
# down, or after-start, from the second call after systemctl start has run.
# APT_ERROR makes apt-get install fail with that line, START_ERROR systemctl
# start.
node_answers() {
	docker() {
		printf 'docker %s\n' "$*" >>"$CALLS"
		case $* in
		"exec "*" busctl --system status org.freedesktop.systemd1")
			if [ "$BUS" = after-start ] && [ -e "$BATS_TEST_TMPDIR/started" ]; then
				echo call >>"$BATS_TEST_TMPDIR/started"
				[ "$(grep -c call "$BATS_TEST_TMPDIR/started")" -lt 2 ] || BUS=up
			fi
			case $BUS in
			up) echo 'PID=1' ;;
			*) echo 'Failed to connect to bus: No such file or directory' >&2; return 1 ;;
			esac ;;
		"exec -e DEBIAN_FRONTEND=noninteractive "*" apt-get update -q") echo 'Get:1 http://deb.debian.org/debian trixie InRelease' ;;
		"exec -e DEBIAN_FRONTEND=noninteractive "*" apt-get install -y -q --no-install-recommends dbus")
			if [ -n "${APT_ERROR:-}" ]; then
				echo 'Reading package lists...'
				echo "$APT_ERROR" >&2
				return 100
			fi
			echo 'Setting up dbus' ;;
		"exec "*" systemctl start dbus.service")
			if [ -n "${START_ERROR:-}" ]; then
				echo 'Job for dbus.service failed.' >&2
				echo "$START_ERROR" >&2
				return 1
			fi
			touch "$BATS_TEST_TMPDIR/started" ;;
		*) return 1 ;;
		esac
	}
}

# cluster_answers: replaces kubectl with a function that answers the calls of
# ensure_node_prep on sandbox-compute. LABELLED lists the nodes that carry the
# labels, LABEL_ERROR makes a label fail, READ_ERROR the read of the nodes.
cluster_answers() {
	kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		case $* in
		"--kubeconfig $KC label "*)
			if [ -n "${LABEL_ERROR:-}" ]; then
				printf 'Warning: x\n%s\n' "$LABEL_ERROR" >&2
				return 1
			fi
			echo "$4 labeled" ;;
		"--kubeconfig $KC annotate "*) echo "$4 annotated" ;;
		"--kubeconfig $KC get nodes -l nova.openstack.cloud.sap/virt-driver -o name")
			if [ -n "${READ_ERROR:-}" ]; then
				printf 'E1126 memcache.go\n%s\n' "$READ_ERROR" >&2
				return 1
			fi
			[ -n "${LABELLED:-}" ] || { echo 'No resources found' >&2; return 0; }
			printf 'node/%s\n' $LABELLED ;;
		*) return 1 ;;
		esac
	}
}

@test "hypervisor_nodes prints the workers of sandbox-compute without its control-plane node" {
	kind_nodes sandbox-compute-control-plane sandbox-compute-worker sandbox-compute-worker2
	run hypervisor_nodes
	[ "$status" -eq 0 ]
	[ "$output" = "sandbox-compute-worker
sandbox-compute-worker2" ]
}

@test "hypervisor_nodes prints nothing for a cluster with the control-plane node alone" {
	kind_nodes sandbox-compute-control-plane
	run hypervisor_nodes
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "hypervisor_nodes fails when kind cannot list the nodes" {
	kind() {
		echo 'ERROR: unknown cluster' >&2
		return 1
	}
	run hypervisor_nodes
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot list the nodes of kind cluster sandbox-compute" ]
}

@test "node_bus leaves a node alone whose systemd answers on the system bus" {
	export BUS=up
	node_answers
	run node_bus sandbox-compute-worker
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(<"$CALLS")" = "docker exec sandbox-compute-worker busctl --system status org.freedesktop.systemd1" ]
}

@test "node_bus installs dbus without recommends, starts it and polls until systemd answers" {
	export BUS=after-start
	node_answers
	run node_bus sandbox-compute-worker
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": installing dbus on sandbox-compute-worker" ]]
	# systemd answers at the second check after the start.
	[ "$(<"$CALLS")" = "docker exec sandbox-compute-worker busctl --system status org.freedesktop.systemd1
docker exec -e DEBIAN_FRONTEND=noninteractive sandbox-compute-worker apt-get update -q
docker exec -e DEBIAN_FRONTEND=noninteractive sandbox-compute-worker apt-get install -y -q --no-install-recommends dbus
docker exec sandbox-compute-worker systemctl start dbus.service
docker exec sandbox-compute-worker busctl --system status org.freedesktop.systemd1
docker exec sandbox-compute-worker busctl --system status org.freedesktop.systemd1" ]
}

@test "node_bus names the last line of apt when it cannot install dbus" {
	export BUS=down APT_ERROR='E: Unable to locate package dbus'
	node_answers
	run node_bus sandbox-compute-worker
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: node-prep: cannot install dbus on sandbox-compute-worker: E: Unable to locate package dbus; the node must reach deb.debian.org" ]
	! grep -q 'systemctl start' "$CALLS"
}

@test "node_bus names the last line of systemctl when it cannot start dbus" {
	export BUS=down START_ERROR='Failed to start dbus.service: Unit dbus.service not found.'
	node_answers
	run node_bus sandbox-compute-worker
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: node-prep: cannot start dbus on sandbox-compute-worker: Failed to start dbus.service: Unit dbus.service not found." ]
}

@test "node_bus gives up after SANDBOX_NODE_TIMEOUT when systemd never answers on the bus" {
	export BUS=down
	node_answers
	export SANDBOX_NODE_TIMEOUT=1
	run node_bus sandbox-compute-worker
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: node-prep: systemd of sandbox-compute-worker does not answer on the system bus after 1 s" ]
}

@test "node_bus refuses a SANDBOX_NODE_TIMEOUT below 1 before it calls docker" {
	export BUS=down
	node_answers
	export SANDBOX_NODE_TIMEOUT=0
	run node_bus sandbox-compute-worker
	[ "$status" -eq 1 ]
	[ "$output" = "error: SANDBOX_NODE_TIMEOUT must be an integer of 1 or more, got '0'" ]
	[ ! -e "$CALLS" ]
}

@test "ensure_node_prep gives every worker the bus, the four labels and the empty annotation with the kubeconfig of compute" {
	attached node-prep
	kind_nodes sandbox-compute-control-plane sandbox-compute-worker sandbox-compute-worker2
	export BUS=up
	node_answers
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": preparing the nodes of sandbox-compute: sandbox-compute-worker, sandbox-compute-worker2" ]]
	[ "$(<"$BATS_TEST_TMPDIR/restored")" = compute ]
	[ "$(<"$CALLS")" = "kind get nodes --name sandbox-compute
docker exec sandbox-compute-worker busctl --system status org.freedesktop.systemd1
kubectl --kubeconfig $KC label node sandbox-compute-worker --overwrite $LABELS
kubectl --kubeconfig $KC annotate node sandbox-compute-worker --overwrite nova.openstack.cloud.sap/aggregates=
docker exec sandbox-compute-worker2 busctl --system status org.freedesktop.systemd1
kubectl --kubeconfig $KC label node sandbox-compute-worker2 --overwrite $LABELS
kubectl --kubeconfig $KC annotate node sandbox-compute-worker2 --overwrite nova.openstack.cloud.sap/aggregates=" ]
}

@test "ensure_node_prep names the node and the last line of kubectl when it cannot label a worker" {
	attached node-prep
	kind_nodes sandbox-compute-control-plane sandbox-compute-worker
	export BUS=up
	node_answers
	export LABEL_ERROR='Error from server (Forbidden): nodes "sandbox-compute-worker" is forbidden'
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: cannot label the node sandbox-compute-worker of sandbox-compute: Error from server (Forbidden): nodes \"sandbox-compute-worker\" is forbidden" ]
	! grep -q ' annotate ' "$CALLS"
}

@test "ensure_node_prep calls neither docker nor kubectl for a compute cluster without a worker" {
	attached node-prep
	kind_nodes sandbox-compute-control-plane
	run ensure_node_prep
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(<"$CALLS")" = "kind get nodes --name sandbox-compute" ]
}

@test "ensure_node_prep removes the four labels and the annotation from a labelled node of a profile without node-prep" {
	attached test
	export LABELLED=sandbox-compute-worker
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": removed the node labels of sandbox-compute" ]]
	[ "$(<"$CALLS")" = "kubectl --kubeconfig $KC get nodes -l nova.openstack.cloud.sap/virt-driver -o name
kubectl --kubeconfig $KC label node/sandbox-compute-worker openstack.c5c3.io/chassis- openstack.c5c3.io/nova-compute-pool- nova.openstack.cloud.sap/virt-driver- cobaltcore.cloud.sap/node-hypervisor-lifecycle-
kubectl --kubeconfig $KC annotate node/sandbox-compute-worker nova.openstack.cloud.sap/aggregates-" ]
}

@test "ensure_node_prep removes and logs nothing when no node of a profile without node-prep carries the labels" {
	attached test
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(<"$CALLS")" = "kubectl --kubeconfig $KC get nodes -l nova.openstack.cloud.sap/virt-driver -o name" ]
}

@test "ensure_node_prep names the last line of kubectl when it cannot read the nodes" {
	attached test
	export READ_ERROR='The connection to the server 127.0.0.1:41234 was refused'
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot read the nodes of sandbox-compute: The connection to the server 127.0.0.1:41234 was refused" ]
}

@test "ensure_node_prep names the last line of kubectl when it cannot remove the labels" {
	attached test
	export LABELLED=sandbox-compute-worker LABEL_ERROR='Error from server (NotFound): nodes "sandbox-compute-worker" not found'
	cluster_answers
	run ensure_node_prep
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot remove the node labels of sandbox-compute: Error from server (NotFound): nodes \"sandbox-compute-worker\" not found" ]
}

@test "ensure_node_prep calls neither kind, docker nor kubectl while sandbox-compute is not attached" {
	attached node-prep
	attached_roles() { echo management; }
	run ensure_node_prep
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$BATS_TEST_TMPDIR/restored" ]
}
