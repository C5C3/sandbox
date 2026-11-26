# shellcheck shell=bash
# The preparation of the worker nodes of sandbox-compute, which no manifest
# can do: the system bus the kvm-node-agent dials, and the labels and the
# annotation of upstream's lab, which upstream sets by hand (Quick Start
# (metal-stack), Part 2, Step 1). Source scripts/lib/common.sh,
# scripts/lib/profile.sh and scripts/lib/hub.sh first.

# The labels of the hypervisor nodes. The pool label is lab because
# upstream's libvirt DaemonSet selects it, and the kvm-node-agent runs on
# every node that carries nova.openstack.cloud.sap/virt-driver.
SANDBOX_NODE_LABELS=(
	openstack.c5c3.io/chassis=true
	openstack.c5c3.io/nova-compute-pool=lab
	nova.openstack.cloud.sap/virt-driver=kvm
	cobaltcore.cloud.sap/node-hypervisor-lifecycle=skip-tests
)
# The annotation of the hypervisor nodes, set to the empty string.
SANDBOX_NODE_ANNOTATION=nova.openstack.cloud.sap/aggregates

# hypervisor_nodes: prints the worker nodes of sandbox-compute, one per line,
# in the order kind lists them.
hypervisor_nodes() {
	local name out
	name=$(cluster_name compute)
	out=$(kind get nodes --name "$name") || die "cannot list the nodes of kind cluster $name"
	grep -vxF -e "$name-control-plane" -e '' <<<"$out" || :
}

# node_bus <node>: makes systemd of the node answer on the system bus. kind
# node images carry no D-Bus daemon, so it installs the package dbus from the
# archive the node image names, which apt checks against the keyring of the
# image, and starts it: the policy-rc.d of the image keeps the package from
# starting it. It then polls every second, for at most SANDBOX_NODE_TIMEOUT
# seconds, by default 30, until systemd answers. A node whose systemd answers
# already is left alone.
node_bus() {
	local node=$1 timeout out start
	timeout=$(_timeout SANDBOX_NODE_TIMEOUT 30) || exit 1
	if docker exec "$node" busctl --system status org.freedesktop.systemd1 >/dev/null 2>&1; then
		return 0
	fi
	log "installing dbus on $node"
	out=$(docker exec -e DEBIAN_FRONTEND=noninteractive "$node" apt-get update -q 2>&1 &&
		docker exec -e DEBIAN_FRONTEND=noninteractive "$node" apt-get install -y -q --no-install-recommends dbus 2>&1) ||
		die "node-prep: cannot install dbus on $node: $(_last_line "$out"); the node must reach deb.debian.org"
	out=$(docker exec "$node" systemctl start dbus.service 2>&1) ||
		die "node-prep: cannot start dbus on $node: $(_last_line "$out")"
	start=$SECONDS
	until docker exec "$node" busctl --system status org.freedesktop.systemd1 >/dev/null 2>&1; do
		[ $((SECONDS - start)) -lt "$timeout" ] ||
			die "node-prep: systemd of $node does not answer on the system bus after $timeout s"
		sleep 1
	done
}

# ensure_node_prep: prepares the worker nodes of sandbox-compute when it is
# attached. When cluster_modules lists node-prep for compute, it gives every
# worker a system bus (node_bus), the labels of SANDBOX_NODE_LABELS and the
# annotation SANDBOX_NODE_ANNOTATION. Otherwise it removes the labels and the
# annotation from every node that carries nova.openstack.cloud.sap/virt-driver,
# and logs it when there was one; the package dbus stays. A second run finds
# the bus, applies the same labels and changes nothing.
ensure_node_prep() {
	local attached name kubeconfig modules nodes node out errfile
	local -a keys=("${SANDBOX_NODE_LABELS[@]%%=*}")
	attached=$(attached_roles) || exit 1
	[[ " $attached " == *" compute "* ]] || return 0
	name=$(cluster_name compute)
	kubeconfig=$(kubeconfig_path compute)
	# make up writes the kubeconfig file only for the roles it is given.
	restore_kubeconfig compute
	modules=$(cluster_modules compute) || exit 1
	if grep -qxF node-prep <<<"$modules"; then
		nodes=$(hypervisor_nodes) || exit 1
		[ -n "$nodes" ] || return 0
		log "preparing the nodes of $name: ${nodes//$'\n'/, }"
		for node in $nodes; do
			node_bus "$node"
			out=$(kubectl --kubeconfig "$kubeconfig" label node "$node" --overwrite "${SANDBOX_NODE_LABELS[@]}" 2>&1 &&
				kubectl --kubeconfig "$kubeconfig" annotate node "$node" --overwrite "$SANDBOX_NODE_ANNOTATION=" 2>&1) ||
				die "cannot label the node $node of $name: $(_last_line "$out")"
		done
		return 0
	fi

	errfile=$(mktemp)
	if ! nodes=$(kubectl --kubeconfig "$kubeconfig" get nodes -l nova.openstack.cloud.sap/virt-driver -o name 2>"$errfile"); then
		out=$(_last_line "$(<"$errfile")")
		rm -f -- "$errfile"
		die "cannot read the nodes of $name: $out"
	fi
	rm -f -- "$errfile"
	[ -n "$nodes" ] || return 0
	for node in $nodes; do
		out=$(kubectl --kubeconfig "$kubeconfig" label "$node" "${keys[@]/%/-}" 2>&1 &&
			kubectl --kubeconfig "$kubeconfig" annotate "$node" "$SANDBOX_NODE_ANNOTATION-" 2>&1) ||
			die "cannot remove the node labels of $name: $(_last_line "$out")"
	done
	log "removed the node labels of $name"
}
