# shellcheck shell=bash
# The compute checks of make verify. Source scripts/lib/hub.sh first; the
# functions use report, poll, os_error, os_quiet, curl_error, errfile, tmp
# and controlplane of scripts/verify.sh, which sources this file.
#
# They run when a NovaCompute in openstack on the management cluster names
# the registration sandbox-compute in spec.targetClusterRef, after the checks
# of the services and in this order:
#
#   compute-pool            every such pool is Ready, and each node of its
#                           status.nodes is Active, with its compute service
#                           up and enabled
#   compute-chassis         every OVNChassis that names sandbox-compute is
#                           Ready, and Neutron lists an alive agent of the
#                           binary ovn-controller on each node
#   compute-metadata-agent  the same for the NeutronMetadataAgent and the
#                           binary neutron-ovn-metadata-agent
#   compute-hypervisor      on sandbox-compute, the Hypervisor of each node
#                           reports Onboarding Succeeded within 600 s, and
#                           the aggregate of the node's zone lists the node
#   compute-network         the network sandbox-verify-compute-net with the
#                           subnet sandbox-verify-compute-subnet on
#                           198.51.100.0/24 has the MTU 1442
#   compute-server          sandbox-verify-compute-server, from the image
#                           cirros-kvm and the flavor 1 on that network, is
#                           ACTIVE on the first node within 600 s
#   compute-metadata        its console log shows, within 300 s, the instance
#                           id cirros read from the metadata service
#   compute-console         the noVNC URL lies under the hostname of the
#                           console proxy, its page answers 200, and a
#                           WebSocket with its token relays the RFB greeting
#                           of the server's VNC
#
# Without the CRD of NovaCompute or without such a pool they report nothing.
# A check whose input an earlier check failed to create reports
# "skipped, <earlier id> failed", so they always report eight lines.
# compute-hypervisor reads sandbox-compute with the kubeconfig file of the
# role; the other checks read the hub and the cloud. Before compute-network
# the checks delete the server, the subnet and the network an earlier run
# left, and after compute-console what they created, also after a failure.
# The console token reaches openssl on stdin alone, never an argument or a
# line of the output.

# The registration the pools of the sandbox name.
COMPUTE_CLUSTER=sandbox-compute

# What check_compute read: the pools that name COMPUTE_CLUSTER and their
# nodes, as JSON arrays; a node is {pool, name, zone, phase, serviceState,
# serviceStatus}.
compute_pools=
compute_nodes=
# What compute_agents_read read: the output of openstack network agent list
# -f json, the first line of its error, and read or failed once it ran.
compute_agents=
compute_agents_error=
compute_agents_state=

# compute_skip <earlier id> <id>...: reports each check as skipped because
# the earlier check failed.
compute_skip() {
	local id
	for id in "${@:2}"; do
		report FAIL "$id" "skipped, $1 failed"
	done
}

# compute_unreadable <error>: reports compute-pool with the error of the read
# of the pools, and the seven other checks as skipped.
compute_unreadable() {
	report FAIL compute-pool "cannot read the NovaComputes of openstack: $1"
	compute_skip compute-pool compute-chassis compute-metadata-agent compute-hypervisor \
		compute-network compute-server compute-metadata compute-console
}

# compute_agents_read: reads openstack network agent list -f json into
# compute_agents at its first call, and keeps it for the later ones. It
# returns 1, with the first line of the error in compute_agents_error, when
# the read failed.
compute_agents_read() {
	local out
	if [ -z "$compute_agents_state" ]; then
		if out=$(openstack network agent list -f json 2>"$errfile"); then
			compute_agents=$out
			compute_agents_state=read
		else
			compute_agents_error=$(os_error "$out")
			compute_agents_state=failed
		fi
	fi
	[ "$compute_agents_state" = read ]
}

# compute_pool: the check compute-pool.
compute_pool() {
	local failure
	failure=$(jq -r --argjson nodes "$compute_nodes" '
		[(.[] | ([.status.conditions[]? | select(.type == "Ready")][0]) as $ready
		  | select($ready.status != "True")
		  | if $ready == null then "the pool \(.metadata.name) has no Ready condition"
		    else "the pool \(.metadata.name) is not Ready: \($ready.message // "")" end),
		 (.[] | select((.status.nodes // []) | length == 0) | "the pool \(.metadata.name) has no node"),
		 ($nodes[] | select(.phase != "Active" or .serviceState != "up" or .serviceStatus != "enabled")
		  | "the node \(.name) of the pool \(.pool) is \(.phase), its service \(.serviceState) and \(.serviceStatus)")]
		| .[0] // empty' <<<"$compute_pools")
	if [ -n "$failure" ]; then
		report FAIL compute-pool "$failure"
		return
	fi
	report ok compute-pool "$(jq -r --argjson nodes "$compute_nodes" \
		'"the pool \(map(.metadata.name) | join(", ")) is Ready, \($nodes | map(.name) | join(", ")) Active, up and enabled"' <<<"$compute_pools")"
}

# compute_agent <id> <resource> <kind> <binary>: the check <id>. It passes
# when every object of the resource in openstack that names COMPUTE_CLUSTER
# is Ready, and Neutron lists an alive agent of the binary on each node.
compute_agent() {
	local id=$1 resource=$2 kind=$3 binary=$4 out failure node names
	if ! out=$(_hub_json -n openstack get "$resource"); then
		report FAIL "$id" "cannot read the $kind objects of openstack: $out"
		return
	fi
	out=$(jq -c --arg cluster "$COMPUTE_CLUSTER" '[.items[]? | select(.spec.targetClusterRef.name? == $cluster)]' <<<"$out")
	if [ "$out" = '[]' ]; then
		report FAIL "$id" "no $kind in openstack names $COMPUTE_CLUSTER"
		return
	fi
	failure=$(jq -r --arg kind "$kind" '[.[] | ([.status.conditions[]? | select(.type == "Ready")][0]) as $ready
		| select($ready.status != "True")
		| if $ready == null then "the \($kind) \(.metadata.name) has no Ready condition"
		  else "the \($kind) \(.metadata.name) is not Ready: \($ready.message // "")" end][0] // empty' <<<"$out")
	if [ -n "$failure" ]; then
		report FAIL "$id" "$failure"
		return
	fi
	names=$(jq -r 'map(.metadata.name) | join(", ")' <<<"$out")
	if ! compute_agents_read; then
		report FAIL "$id" "$compute_agents_error"
		return
	fi
	for node in $(jq -r '.[].name' <<<"$compute_nodes"); do
		if ! jq -e --arg binary "$binary" --arg node "$node" \
			'any(.[]?; .Binary == $binary and .Host == $node and .Alive == true)' >/dev/null 2>&1 <<<"$compute_agents"; then
			report FAIL "$id" "no alive $binary agent on $node"
			return
		fi
	done
	report ok "$id" "the $kind $names is Ready, with an alive $binary agent on $(jq -r 'map(.name) | join(", ")' <<<"$compute_nodes")"
}

# compute_onboarding <kubeconfig> <node>: prints the reason of the condition
# Onboarding of the Hypervisor of the node, or none while it has none. When
# kubectl fails, it prints the last line of its error on stderr and returns 1.
compute_onboarding() {
	local out
	if ! out=$(kubectl --kubeconfig "$1" get hypervisors.kvm.cloud.sap "$2" --ignore-not-found -o json 2>"$tmp/kubectl.err"); then
		_last_line "$(<"$tmp/kubectl.err")" >&2
		return 1
	fi
	[ -n "$out" ] || out='{}'
	jq -r '[.status.conditions[]? | select(.type == "Onboarding")][0].reason // "none"' <<<"$out"
}

# compute_hypervisor: the check compute-hypervisor, which reads
# sandbox-compute with the kubeconfig file of the role and waits up to 600 s
# for each node.
compute_hypervisor() {
	local kubeconfig node zone out rc
	# sandbox_cluster and restore_kubeconfig end the script when they cannot
	# tell, so they run in a subshell, and their message is the check's.
	if ! (sandbox_cluster compute) 2>"$errfile"; then
		out=$(_first_line "$(<"$errfile")")
		out=${out#error: }
		report FAIL compute-hypervisor "${out:-$(cluster_name compute) does not exist}"
		return
	fi
	if ! (restore_kubeconfig compute) >&2 2>"$errfile"; then
		out=$(_first_line "$(<"$errfile")")
		report FAIL compute-hypervisor "${out#error: }"
		return
	fi
	kubeconfig=$(kubeconfig_path compute)
	while IFS=$'\t' read -r node zone <&3; do
		rc=0
		poll Succeeded 300 compute_onboarding "$kubeconfig" "$node" || rc=$?
		case $rc in
		0) ;;
		1)
			report FAIL compute-hypervisor "the Hypervisor $node reports Onboarding $polled after 600 s, expected Succeeded"
			return
			;;
		*)
			report FAIL compute-hypervisor "$polled"
			return
			;;
		esac
		if ! out=$(openstack aggregate show "$zone" -f json -c hosts 2>"$errfile"); then
			report FAIL compute-hypervisor "$(os_error "$out")"
			return
		fi
		if ! jq -e --arg node "$node" '(.hosts // []) | index($node) != null' >/dev/null 2>&1 <<<"$out"; then
			report FAIL compute-hypervisor "the aggregate $zone does not list $node as a host"
			return
		fi
	done 3< <(jq -r '.[] | [.name, .zone] | @tsv' <<<"$compute_nodes")
	report ok compute-hypervisor "$(jq -r 'map("\(.name) in \(.zone)") | join(", ")' <<<"$compute_nodes") onboarded, each in the aggregate of its zone"
}

# compute_network: creates the network sandbox-verify-compute-net with the
# subnet sandbox-verify-compute-subnet on 198.51.100.0/24 and reports the
# check compute-network. It sets net and subnet of its caller to their ids
# once they exist, and returns 1 when the check failed.
compute_network() {
	local out mtu
	if ! out=$(openstack network create -f value -c id sandbox-verify-compute-net 2>"$errfile"); then
		report FAIL compute-network "$(os_error "$out")"
		return 1
	fi
	net=$(_first_line "$out")
	if ! out=$(openstack subnet create --network "$net" --subnet-range 198.51.100.0/24 \
		-f value -c id sandbox-verify-compute-subnet 2>"$errfile"); then
		report FAIL compute-network "$(os_error "$out")"
		return 1
	fi
	subnet=$(_first_line "$out")
	if ! out=$(openstack network show "$net" -f value -c mtu 2>"$errfile"); then
		report FAIL compute-network "$(os_error "$out")"
		return 1
	fi
	mtu=$(_first_line "$out")
	if [ "$mtu" != 1442 ]; then
		report FAIL compute-network "the network sandbox-verify-compute-net has the MTU $mtu, expected 1442"
		return 1
	fi
	report ok compute-network "the network sandbox-verify-compute-net with the subnet sandbox-verify-compute-subnet on 198.51.100.0/24 has the MTU 1442"
}

# compute_server: boots sandbox-verify-compute-server from the image
# cirros-kvm and the flavor 1 of the module hypervisor-fixtures on the
# network net of its caller, in the zone and on the host of the first node,
# and reports the check compute-server. It returns 1 when the check failed.
compute_server() {
	local out node zone status host fault i create_error=
	if ! out=$(openstack image show cirros-kvm -f value -c id 2>"$errfile"); then
		report FAIL compute-server "the image cirros-kvm, which the module hypervisor-fixtures creates: $(os_error "$out")"
		return 1
	fi
	if ! out=$(openstack flavor show 1 -f value -c id 2>"$errfile"); then
		report FAIL compute-server "the flavor 1, which the module hypervisor-fixtures creates: $(os_error "$out")"
		return 1
	fi
	IFS=$'\t' read -r node zone < <(jq -r '.[0] | [.name, .zone] | @tsv' <<<"$compute_nodes")

	# The --wait of the CLI has no bound, so the create returns at once, and
	# the status is read, and again after each of up to 300 pauses of 2 s,
	# until the server is ACTIVE or ERROR. The error of the create counts only
	# when there is no server to show.
	if ! out=$(openstack server create --image cirros-kvm --flavor 1 --network "$net" \
		--availability-zone "$zone:$node" -f value -c id sandbox-verify-compute-server 2>"$errfile"); then
		create_error=$(os_error "$out")
	fi
	for ((i = 0; ; i++)); do
		if ! out=$(openstack server show sandbox-verify-compute-server -f json -c status -c OS-EXT-SRV-ATTR:host 2>"$errfile"); then
			report FAIL compute-server "${create_error:-$(os_error "$out")}"
			return 1
		fi
		status=$(jq -r '.status // ""' <<<"$out")
		if [ "$status" = ACTIVE ] || [ "$status" = ERROR ] || [ "$i" -ge 300 ]; then
			break
		fi
		sleep 2
	done
	host=$(jq -r '.["OS-EXT-SRV-ATTR:host"] // ""' <<<"$out")
	case $status in
	ACTIVE)
		if [ "$host" = "$node" ]; then
			report ok compute-server "the server sandbox-verify-compute-server is ACTIVE on $node"
			return 0
		fi
		report FAIL compute-server "the server sandbox-verify-compute-server is ACTIVE on '$host', expected $node"
		;;
	ERROR)
		fault=$(openstack server show sandbox-verify-compute-server -f json -c fault 2>/dev/null |
			jq -r '.fault | if type == "object" then .message // "" else . // "" end' 2>/dev/null) || fault=
		report FAIL compute-server "the server sandbox-verify-compute-server is 'ERROR', expected ACTIVE: $(_first_line "$fault")"
		;;
	*) report FAIL compute-server "the server sandbox-verify-compute-server is '$status' after 600 s, expected ACTIVE" ;;
	esac
	return 1
}

# compute_metadata: the check compute-metadata. It reads the console log of
# the server, and again after each of up to 150 pauses of 2 s, until cirros
# 0.6 reports the instance id it read from the metadata service, or that it
# failed to read one.
compute_metadata() {
	local out line i
	for ((i = 0; ; i++)); do
		if ! out=$(openstack console log show sandbox-verify-compute-server 2>"$errfile"); then
			report FAIL compute-metadata "$(os_error "$out")"
			return
		fi
		line=$(grep -m 1 -E 'successful after [0-9]+/20 tries: up [0-9.]+\. iid=' <<<"$out" | tr -d '\r' || :)
		if [ -n "$line" ]; then
			report ok compute-metadata "cirros on sandbox-verify-compute-server read the instance id ${line##*iid=} from the metadata service"
			return
		fi
		if grep -qF 'failed to read iid from metadata' <<<"$out"; then
			report FAIL compute-metadata "cirros on sandbox-verify-compute-server failed to read iid from metadata"
			return
		fi
		if [ "$i" -ge 150 ]; then
			report FAIL compute-metadata "the console log of sandbox-verify-compute-server shows no instance id after 300 s"
			return
		fi
		sleep 2
	done
}

# compute_console: the check compute-console. curl reads the page of the
# noVNC URL without its query, and openssl opens a WebSocket to the console
# proxy for the path the query's parameter path names, ?token=<token>, with
# the request on its stdin, which stays open for 5 s. A server frame carries
# its payload unmasked, so the answer holds the bytes of the RFB greeting.
compute_console() {
	local out hostname url page code query param value path status
	local -a params
	if ! command -v openssl >/dev/null; then
		report FAIL compute-console "openssl not found in PATH"
		return
	fi
	if ! command -v curl >/dev/null; then
		report FAIL compute-console "curl not found in PATH"
		return
	fi
	hostname=$(jq -r '.spec.services.nova.consoleProxy.gateway.hostname // empty' <<<"$controlplane")
	if [ -z "$hostname" ]; then
		report FAIL compute-console "the ControlPlane publishes no hostname for the console proxy"
		return
	fi
	if ! out=$(openstack console url show --novnc sandbox-verify-compute-server -f value -c url 2>"$errfile"); then
		report FAIL compute-console "$(os_error "$out")"
		return
	fi
	url=$(_first_line "$out")
	if [[ $url != "https://$hostname/"* ]]; then
		report FAIL compute-console "the noVNC URL of sandbox-verify-compute-server is not under https://$hostname/"
		return
	fi

	page=${url%%\?*}
	if ! code=$(curl --silent --show-error --cacert "$OS_CACERT" --output /dev/null --write-out '%{http_code}' "$page" 2>"$errfile"); then
		report FAIL compute-console "$(curl_error)"
		return
	fi
	if [ "$code" != 200 ]; then
		report FAIL compute-console "the console page $page answered $code, expected 200"
		return
	fi

	query=${url#"$page"}
	query=${query#\?}
	value=
	IFS='&' read -ra params <<<"$query"
	for param in "${params[@]}"; do
		if [[ $param == path=* ]]; then
			value=${param#path=}
		fi
	done
	if [ -z "$value" ]; then
		report FAIL compute-console "the noVNC URL of sandbox-verify-compute-server names no path"
		return
	fi
	# printf is a builtin, so the token is the argument of no process.
	path=$(printf '%b' "${value//%/\\x}")
	{
		printf 'GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: c2FuZGJveC12ZXJpZnkxMg==\r\nSec-WebSocket-Protocol: binary\r\n\r\n' \
			"${path#/}" "$hostname"
		sleep 5
	} 2>/dev/null | openssl s_client -quiet -no_ign_eof -verify_return_error -CAfile "$OS_CACERT" \
		-connect "$hostname:443" -servername "$hostname" >"$tmp/console" 2>"$errfile" || :
	status=$(head -n 1 "$tmp/console" | tr -d '\r')
	if [[ $status != "HTTP/1.1 101"* ]]; then
		report FAIL compute-console "the console proxy answered the WebSocket upgrade without 101: ${status:-$(_first_line "$(<"$errfile")")}"
		return
	fi
	if ! grep -qaF 'RFB 003.' "$tmp/console"; then
		report FAIL compute-console "the WebSocket to the console proxy relayed no RFB 003. greeting of the server's VNC"
		return
	fi
	report ok compute-console "the console page answers 200 on https://$hostname, and a WebSocket with the token of the noVNC URL relays the RFB greeting of the server's VNC"
}

# compute_cleanup: deletes the server sandbox-verify-compute-server and waits
# until it is gone, then the subnet and the network of the caller's subnet
# and net, by their names or their ids.
compute_cleanup() {
	os_quiet server delete --wait sandbox-verify-compute-server
	os_quiet subnet delete "$subnet"
	os_quiet network delete "$net"
}

# check_compute: the eight compute checks, for the pools in openstack that
# name COMPUTE_CLUSTER. Without the CRD of NovaCompute or without such a
# pool it reports nothing.
check_compute() {
	local out net=sandbox-verify-compute-net subnet=sandbox-verify-compute-subnet
	if ! out=$(_hub_json get crd novacomputes.nova.openstack.c5c3.io --ignore-not-found); then
		compute_unreadable "$out"
		return
	fi
	if [ -z "$out" ]; then
		return
	fi
	if ! out=$(_hub_json -n openstack get novacomputes.nova.openstack.c5c3.io); then
		compute_unreadable "$out"
		return
	fi
	compute_pools=$(jq -c --arg cluster "$COMPUTE_CLUSTER" '[.items[]? | select(.spec.targetClusterRef.name? == $cluster)]' <<<"$out")
	if [ "$compute_pools" = '[]' ]; then
		return
	fi
	compute_nodes=$(jq -c '[.[] | .metadata.name as $pool | .status.nodes[]?
		| {pool: $pool, name, zone: (.zone // ""), phase: (.phase // ""),
		   serviceState: (.serviceState // ""), serviceStatus: (.serviceStatus // "")}]' <<<"$compute_pools")

	compute_pool
	# The three checks after it look at each node of the pools.
	if [ "$compute_nodes" = '[]' ]; then
		compute_skip compute-pool compute-chassis compute-metadata-agent compute-hypervisor
	else
		compute_agent compute-chassis ovnchassis.ovn.openstack.c5c3.io OVNChassis ovn-controller
		compute_agent compute-metadata-agent neutronmetadataagents.neutron.openstack.c5c3.io NeutronMetadataAgent neutron-ovn-metadata-agent
		compute_hypervisor
	fi

	compute_cleanup
	if ! compute_network; then
		compute_skip compute-network compute-server compute-metadata compute-console
	elif [ "$compute_nodes" = '[]' ]; then
		compute_skip compute-pool compute-server compute-metadata compute-console
	elif ! compute_server; then
		compute_skip compute-server compute-metadata compute-console
	else
		compute_metadata
		compute_console
	fi
	compute_cleanup
}
