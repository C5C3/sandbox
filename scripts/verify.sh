#!/usr/bin/env bash
# Usage: verify.sh
#
# Checks the services of the ControlPlane openstack/controlplane on
# sandbox-management with the OpenStack CLI and the variables that make env
# prints. Each key of spec.services adds the checks of its service, in the
# order of this table:
#
#   keystone   keystone-token     openstack token issue prints a token id
#              keystone-catalog   the catalog holds a public identity endpoint
#                                 at OS_AUTH_URL
#   glance     glance-catalog     the catalog holds a public image endpoint at
#                                 https://<the hostname of its Gateway>
#              glance-image       a 1 KiB image sandbox-verify-image is active
#                                 within 60 s
#   placement  placement-catalog  the same for the type placement
#              placement-classes  resource class list holds VCPU, MEMORY_MB
#                                 and DISK_GB
#   barbican   barbican-catalog   the same for the type key-manager
#              barbican-secret    the payload stored as sandbox-verify-secret
#                                 comes back unchanged
#   neutron    neutron-catalog    the same for the type network
#              neutron-network    the network sandbox-verify-net with the
#                                 subnet sandbox-verify-subnet on 192.0.2.0/24
#                                 is ACTIVE
#   cinder     cinder-catalog     the same for the type block-storage
#              cinder-volume      the 1 GiB volume sandbox-verify-volume is
#                                 available within 120 s
#   nova       nova-catalog       the same for the type compute
#              nova-services      a nova-scheduler and a nova-conductor are up
#              nova-server        sandbox-verify-server boots to ACTIVE on the
#                                 fake compute, only when the Deployment
#                                 openstack/controlplane-fake-compute exists
#   horizon    horizon-login      admin logs in to the dashboard with curl
#
# After them, when a NovaCompute in openstack names the registration
# sandbox-compute, come the eight checks of scripts/lib/compute.sh:
#
#   compute-pool            the pools are Ready, their nodes Active, up and
#                           enabled
#   compute-chassis         the OVNChassis is Ready, an alive ovn-controller
#                           agent runs on each node
#   compute-metadata-agent  the same for the metadata agent
#   compute-hypervisor      the Hypervisor of each node on sandbox-compute is
#                           onboarded within 600 s, the node in its aggregate
#   compute-network         sandbox-verify-compute-net has the MTU 1442
#   compute-server          sandbox-verify-compute-server boots from
#                           cirros-kvm to ACTIVE on the first node within
#                           600 s
#   compute-metadata        cirros reads its instance id from the metadata
#                           service within 300 s
#   compute-console         the noVNC console relays the RFB greeting of the
#                           server
#
# Then, when spec.namespaceAssignments assigns a namespace on the management
# cluster, come the five checks of scripts/lib/orders.sh:
#
#   orders-ready      the orders of the assigned namespaces are Ready
#   orders-secrets    each Ready order that delivers a Secret has it
#   orders-converge   the scratch orders sandbox-verify* are Ready within
#                     300 s, with their Secrets
#   orders-rotation   sandbox-verify-appcred rotates on its schedule, and
#                     generation 1 is refused after its grace period
#   orders-teardown   the scratch orders leave nothing when deleted
#
# A key outside the table adds no check. It prints one line per check,
# ok <id>: <detail> or FAIL <id>: <first line of the error>, then
# verify: <passed> of <total> checks passed, and exits 1 when a check failed.
# Without a ControlPlane it runs no check and exits 0. It reads the hub, and
# compute-hypervisor also sandbox-compute, no configuration and no profile.
# No call passes --insecure or -k: the CLI trusts the CA of the sandbox
# through OS_CACERT, curl through --cacert, and openssl through -CAfile. A
# check deletes what an earlier run left of its sandbox-verify
# names before it creates, and deletes what it created when it ends, also
# after a failure; a failed delete is not reported. The temporary files of
# its checks live in one directory, which the script removes when it exits.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/access.sh
. "$SANDBOX_ROOT/scripts/lib/access.sh"
# shellcheck source=lib/compute.sh
. "$SANDBOX_ROOT/scripts/lib/compute.sh"
# shellcheck source=lib/orders.sh
. "$SANDBOX_ROOT/scripts/lib/orders.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
errfile=$tmp/stderr

passed=0
total=0
# What catalog_read read: the output of openstack catalog list -f json, the
# first line of its error, and read or failed once it ran.
catalog=
catalog_error=
catalog_state=
# The status that poll read last, or the first line of the error that ended
# it.
polled=

# report <ok|FAIL> <id> <detail>: prints one line of a check and counts it.
report() {
	printf '%s %s: %s\n' "$1" "$2" "$3"
	total=$((total + 1))
	if [ "$1" = ok ]; then
		passed=$((passed + 1))
	fi
}

# os_error <stdout>: prints the first line that holds more than spaces of
# openstack's stderr, which errfile holds, and its stdout, in that order, or
# a message of its own when both are empty.
os_error() {
	local out
	out=$(_first_line "$(<"$errfile")"$'\n'"$1")
	printf '%s\n' "${out:-openstack failed without a message}"
}

# curl_error: prints the first line that holds more than spaces of curl's
# stderr, which errfile holds, or a message of its own when it is empty.
curl_error() {
	local out
	out=$(_first_line "$(<"$errfile")")
	printf '%s\n' "${out:-curl failed without a message}"
}

# os_quiet <argument>...: runs openstack with the arguments and discards its
# output and its status. The deletes run through it, because a failed
# delete is not reported.
os_quiet() {
	openstack "$@" >/dev/null 2>&1 || :
}

# poll <want> <times> <command>...: runs the command, and again after each of
# up to <times> pauses of 2 s, until the first line of its output is <want>.
# It keeps that line in polled and returns 0 when it is <want>, 1 when it is
# not after the last pause, and 2 at once when a call fails, with the first
# line of the error in polled.
poll() {
	local want=$1 times=$2 out i
	shift 2
	for ((i = 0; ; i++)); do
		if ! out=$("$@" 2>"$errfile"); then
			polled=$(os_error "$out")
			return 2
		fi
		polled=$(_first_line "$out")
		if [ "$polled" = "$want" ]; then
			return 0
		fi
		if [ "$i" -ge "$times" ]; then
			return 1
		fi
		sleep 2
	done
}

# catalog_read: reads openstack catalog list -f json into catalog at its
# first call, and keeps it for the later ones. It returns 1, with the first
# line of the error in catalog_error, when the read failed.
catalog_read() {
	local out
	if [ -z "$catalog_state" ]; then
		if out=$(openstack catalog list -f json 2>"$errfile"); then
			catalog=$out
			catalog_state=read
		else
			catalog_error=$(os_error "$out")
			catalog_state=failed
		fi
	fi
	[ "$catalog_state" = read ]
}

# check_catalog <service> <type>: the check <service>-catalog. It passes when
# a service of the type in the catalog has a public endpoint at
# https://<hostname> or under it, where <hostname> is the hostname of the
# Gateway of the service in the ControlPlane.
check_catalog() {
	local hostname
	hostname=$(jq -r --arg service "$1" '.spec.services[$service].gateway.hostname // empty' <<<"$controlplane")
	if [ -z "$hostname" ]; then
		report FAIL "$1-catalog" "the ControlPlane publishes no hostname for $1"
	elif ! catalog_read; then
		report FAIL "$1-catalog" "$catalog_error"
	elif jq -e --arg type "$2" --arg url "https://$hostname" 'any(.[]?; .Type == $type
		and any(.Endpoints[]?; .interface == "public"
			and ((.url // "") as $u | $u == $url or ($u | startswith($url + "/")))))' >/dev/null 2>&1 <<<"$catalog"; then
		report ok "$1-catalog" "the catalog holds a public $2 endpoint at https://$hostname"
	else
		report FAIL "$1-catalog" "no public $2 endpoint at https://$hostname in the catalog"
	fi
}

# check_keystone: the checks of the service keystone.
check_keystone() {
	local out
	if out=$(openstack token issue -f value -c id 2>"$errfile"); then
		if [ -n "$(_first_line "$out")" ]; then
			report ok keystone-token "admin received a token from $OS_AUTH_URL"
		else
			report FAIL keystone-token "openstack token issue printed no token id"
		fi
	else
		report FAIL keystone-token "$(os_error "$out")"
	fi

	if ! catalog_read; then
		report FAIL keystone-catalog "$catalog_error"
	elif jq -e --arg url "$OS_AUTH_URL" 'any(.[]?; .Type == "identity"
		and any(.Endpoints[]?; .interface == "public" and .url == $url))' >/dev/null 2>&1 <<<"$catalog"; then
		report ok keystone-catalog "the catalog holds the public identity endpoint $OS_AUTH_URL"
	else
		report FAIL keystone-catalog "no public identity endpoint $OS_AUTH_URL in the catalog"
	fi
}

# check_glance: the checks of the service glance. The image is shown and
# deleted by its id once it exists.
check_glance() {
	local out image=sandbox-verify-image rc=0
	check_catalog glance image

	os_quiet image delete sandbox-verify-image
	head -c 1024 /dev/urandom >"$tmp/image.raw"
	if ! out=$(openstack image create --disk-format raw --container-format bare --file "$tmp/image.raw" \
		-f value -c id sandbox-verify-image 2>"$errfile"); then
		report FAIL glance-image "$(os_error "$out")"
	else
		image=$(_first_line "$out")
		poll active 30 openstack image show "$image" -f value -c status || rc=$?
		case $rc in
		0) report ok glance-image "a 1 KiB image uploaded as sandbox-verify-image became active" ;;
		1) report FAIL glance-image "the image sandbox-verify-image is '$polled' after 60 s, expected active" ;;
		*) report FAIL glance-image "$polled" ;;
		esac
	fi
	os_quiet image delete "$image"
}

# check_placement: the checks of the service placement.
check_placement() {
	local out class
	check_catalog placement placement

	if ! out=$(openstack resource class list -f value -c name 2>"$errfile"); then
		report FAIL placement-classes "$(os_error "$out")"
		return
	fi
	for class in VCPU MEMORY_MB DISK_GB; do
		if ! grep -qx -- "$class" <<<"$out"; then
			report FAIL placement-classes "resource class list holds no $class"
			return
		fi
	done
	report ok placement-classes "resource class list holds VCPU, MEMORY_MB and DISK_GB"
}

# barbican_cleanup: deletes every secret named sandbox-verify-secret. A
# secret is deleted by its href, not by its name.
barbican_cleanup() {
	local hrefs href
	hrefs=$(openstack secret list --name sandbox-verify-secret -f value -c 'Secret href' 2>/dev/null) || hrefs=
	for href in $hrefs; do
		os_quiet secret delete "$href"
	done
}

# check_barbican: the checks of the service barbican.
check_barbican() {
	local out href=
	check_catalog barbican key-manager

	barbican_cleanup
	if ! out=$(openstack secret store --name sandbox-verify-secret --payload sandbox-verify-payload \
		-f value -c 'Secret href' 2>"$errfile"); then
		report FAIL barbican-secret "$(os_error "$out")"
	else
		href=$(_first_line "$out")
		if ! out=$(openstack secret get -p "$href" -f value -c Payload 2>"$errfile"); then
			report FAIL barbican-secret "$(os_error "$out")"
		elif [ "$out" = sandbox-verify-payload ]; then
			report ok barbican-secret "the payload of sandbox-verify-secret came back unchanged"
		else
			report FAIL barbican-secret "the payload of sandbox-verify-secret came back changed"
		fi
	fi
	if [ -n "$href" ]; then
		os_quiet secret delete "$href"
	else
		barbican_cleanup
	fi
}

# neutron_network: creates the network sandbox-verify-net with the subnet
# sandbox-verify-subnet on 192.0.2.0/24 and reports the check
# neutron-network. It sets net and subnet of its caller to their ids once
# they exist.
neutron_network() {
	local out status
	if ! out=$(openstack network create -f value -c id sandbox-verify-net 2>"$errfile"); then
		report FAIL neutron-network "$(os_error "$out")"
		return
	fi
	net=$(_first_line "$out")
	if ! out=$(openstack subnet create --network "$net" --subnet-range 192.0.2.0/24 \
		-f value -c id sandbox-verify-subnet 2>"$errfile"); then
		report FAIL neutron-network "$(os_error "$out")"
		return
	fi
	subnet=$(_first_line "$out")
	if ! out=$(openstack network show "$net" -f value -c status 2>"$errfile"); then
		report FAIL neutron-network "$(os_error "$out")"
		return
	fi
	status=$(_first_line "$out")
	if [ "$status" = ACTIVE ]; then
		report ok neutron-network "the network sandbox-verify-net with the subnet sandbox-verify-subnet on 192.0.2.0/24 is ACTIVE"
	else
		report FAIL neutron-network "the network sandbox-verify-net is '$status', expected ACTIVE"
	fi
}

# check_neutron: the checks of the service neutron. The network and the
# subnet are deleted by their ids once they exist, by their names before.
check_neutron() {
	local net=sandbox-verify-net subnet=sandbox-verify-subnet
	check_catalog neutron network

	os_quiet subnet delete sandbox-verify-subnet
	os_quiet network delete sandbox-verify-net
	neutron_network
	os_quiet subnet delete "$subnet"
	os_quiet network delete "$net"
}

# check_cinder: the checks of the service cinder. The volume is shown and
# deleted by its id once it exists, because Cinder deletes a volume in the
# background and a leftover of the same name can still be there.
check_cinder() {
	local out volume=sandbox-verify-volume rc=0
	check_catalog cinder block-storage

	os_quiet volume delete sandbox-verify-volume
	if ! out=$(openstack volume create --size 1 -f value -c id sandbox-verify-volume 2>"$errfile"); then
		report FAIL cinder-volume "$(os_error "$out")"
	else
		volume=$(_first_line "$out")
		poll available 60 openstack volume show "$volume" -f value -c status || rc=$?
		case $rc in
		0) report ok cinder-volume "the 1 GiB volume sandbox-verify-volume is available" ;;
		1) report FAIL cinder-volume "the volume sandbox-verify-volume is '$polled' after 120 s, expected available" ;;
		*) report FAIL cinder-volume "$polled" ;;
		esac
	fi
	os_quiet volume delete "$volume"
}

# service_up <binary> <json>: succeeds when the output of openstack compute
# service list -f json holds a service of the binary with State up.
service_up() {
	jq -e --arg binary "$1" 'any(.[]?; .Binary == $binary and .State == "up")' >/dev/null 2>&1 <<<"$2"
}

# nova_server_cleanup <image>: deletes the server sandbox-verify-server and
# waits until it is gone, then the image, by its name or its id, and the
# flavor sandbox-verify-flavor.
nova_server_cleanup() {
	os_quiet server delete --wait sandbox-verify-server
	os_quiet image delete "$1"
	os_quiet flavor delete sandbox-verify-flavor
}

# nova_server_boot <node>: creates the flavor sandbox-verify-flavor and the
# 1 MiB image sandbox-verify-boot, boots sandbox-verify-server from them
# without a network, and reports the check nova-server. It sets image of
# its caller to the id of the image once it exists.
nova_server_boot() {
	local out status fault create_error= rc=0
	if ! out=$(openstack flavor create --vcpus 1 --ram 128 --disk 1 -f value -c id sandbox-verify-flavor 2>"$errfile"); then
		report FAIL nova-server "$(os_error "$out")"
		return
	fi
	truncate -s 1M "$tmp/boot.raw"
	if ! out=$(openstack image create --disk-format raw --container-format bare --file "$tmp/boot.raw" \
		-f value -c id sandbox-verify-boot 2>"$errfile"); then
		report FAIL nova-server "$(os_error "$out")"
		return
	fi
	image=$(_first_line "$out")
	poll active 30 openstack image show "$image" -f value -c status || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL nova-server "the image sandbox-verify-boot is '$polled' after 60 s, expected active"
		return
		;;
	*)
		report FAIL nova-server "$polled"
		return
		;;
	esac

	# server create --wait fails when the server ends in ERROR, and the
	# status and the fault of the server tell why. Its own error counts only
	# when there is no server to show. The CLI speaks compute API 2.1 unless
	# told otherwise, and refuses --nic none below 2.37.
	if ! out=$(openstack --os-compute-api-version 2.37 server create --image "$image" \
		--flavor sandbox-verify-flavor --nic none --wait -f value -c id sandbox-verify-server 2>"$errfile"); then
		create_error=$(os_error "$out")
	fi
	if ! out=$(openstack server show sandbox-verify-server -f value -c status 2>"$errfile"); then
		report FAIL nova-server "${create_error:-$(os_error "$out")}"
		return
	fi
	status=$(_first_line "$out")
	if [ "$status" = ACTIVE ]; then
		report ok nova-server "the server sandbox-verify-server is ACTIVE on the fake compute of $1"
		return
	fi
	fault=$(openstack server show sandbox-verify-server -f json -c fault 2>/dev/null |
		jq -r '.fault | if type == "object" then .message // "" else . // "" end' 2>/dev/null) || fault=
	report FAIL nova-server "the server sandbox-verify-server is '$status', expected ACTIVE: $(_first_line "$fault")"
}

# check_nova_server: the check nova-server, which boots a server on the fake
# compute of the Deployment openstack/controlplane-fake-compute. Without
# that Deployment it reports nothing.
check_nova_server() {
	local out node image=sandbox-verify-boot rc=0
	if ! out=$(_hub_json -n openstack get deployment controlplane-fake-compute --ignore-not-found); then
		report FAIL nova-server "cannot read the Deployment openstack/controlplane-fake-compute: $out"
		return
	fi
	if [ -z "$out" ]; then
		return
	fi
	if ! out=$(_hub_json -n openstack get pods -l app.kubernetes.io/name=nova-fake-compute); then
		report FAIL nova-server "cannot read the pods of the Deployment openstack/controlplane-fake-compute: $out"
		return
	fi
	node=$(jq -r '[.items[]? | .spec.nodeName // empty][0] // empty' <<<"$out")
	if [ -z "$node" ]; then
		report FAIL nova-server "the Deployment controlplane-fake-compute has no pod"
		return
	fi

	# The fake compute registers under the name of its node, and the
	# scheduler places a server only on a host that discover_hosts mapped
	# into the cell.
	poll up 60 openstack compute service list --service nova-compute --host "$node" -f value -c State || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL nova-server "the compute service of $node is '$polled' after 120 s, expected up"
		return
		;;
	*)
		report FAIL nova-server "$polled"
		return
		;;
	esac
	if ! out=$(hub_kubectl -n openstack exec deploy/controlplane-nova-conductor -c conductor -- \
		nova-manage --config-dir /etc/nova/nova.conf.d cell_v2 discover_hosts 2>&1); then
		report FAIL nova-server "cannot run nova-manage cell_v2 discover_hosts in deploy/controlplane-nova-conductor: $(_last_line "$out")"
		return
	fi

	nova_server_cleanup sandbox-verify-boot
	nova_server_boot "$node"
	nova_server_cleanup "$image"
}

# check_nova: the checks of the service nova.
check_nova() {
	local out
	check_catalog nova compute

	if ! out=$(openstack compute service list -f json 2>"$errfile"); then
		report FAIL nova-services "$(os_error "$out")"
	elif ! service_up nova-scheduler "$out"; then
		report FAIL nova-services "no nova-scheduler service is up"
	elif ! service_up nova-conductor "$out"; then
		report FAIL nova-services "no nova-conductor service is up"
	else
		report ok nova-services "a nova-scheduler and a nova-conductor service are up"
	fi

	check_nova_server
}

# attribute <tag> <name>: prints the value of the attribute <name> of the
# HTML tag, in double, single or no quotes, and returns 1 when the tag has
# no such attribute.
attribute() {
	local re="[[:space:]]$2[[:space:]]*=[[:space:]]*(\"([^\"]*)\"|'([^']*)'|([^[:space:]\"'>]+))"
	[[ $1 =~ $re ]] || return 1
	printf '%s\n' "${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
}

# hidden_fields <file>: prints name=value for each <input type="hidden"> of
# the first form of the HTML file, the login form, one per line and in the
# order of the page. The attributes of an input may come in any order.
hidden_fields() {
	local page form tag name value input_re='<input[[:space:]][^>]*>'
	page=$(tr '\t\r\n' '   ' <"$1")
	form=${page#*<form}
	form=${form%%</form>*}
	while [[ $form =~ $input_re ]]; do
		tag=${BASH_REMATCH[0]}
		form=${form#*"$tag"}
		value=$(attribute "$tag" type) || continue
		[ "${value,,}" = hidden ] || continue
		name=$(attribute "$tag" name) || continue
		value=$(attribute "$tag" value) || value=
		printf '%s=%s\n' "$name" "$value"
	done
}

# check_horizon: the checks of the service horizon. curl logs in as admin
# through the login form of the dashboard, with the CA of OS_CACERT and a
# cookie jar in the temporary directory. The password reaches curl from a
# file of mode 600 there, never as an argument. Django checks the Referer of
# a POST over HTTPS, so the POST names the login page.
check_horizon() {
	local hostname url field fields=() out code path
	hostname=$(jq -r '.spec.services.horizon.gateway.hostname // empty' <<<"$controlplane")
	if [ -z "$hostname" ]; then
		report FAIL horizon-login "the ControlPlane publishes no hostname for horizon"
		return
	fi
	if ! command -v curl >/dev/null; then
		report FAIL horizon-login "curl not found in PATH"
		return
	fi
	url=https://$hostname/auth/login/

	if ! curl --silent --show-error --fail --location --cacert "$OS_CACERT" \
		--cookie-jar "$tmp/cookies" --output "$tmp/login.html" "$url" 2>"$errfile"; then
		report FAIL horizon-login "$(curl_error)"
		return
	fi
	while IFS= read -r field; do
		fields+=(--data-urlencode "$field")
	done < <(hidden_fields "$tmp/login.html")
	(umask 077 && printf '%s' "$OS_PASSWORD" >"$tmp/password")
	if ! out=$(curl --silent --show-error --location --cacert "$OS_CACERT" \
		--cookie "$tmp/cookies" --cookie-jar "$tmp/cookies" --referer "$url" \
		"${fields[@]}" --data-urlencode username=admin --data-urlencode domain=Default \
		--data-urlencode "password@$tmp/password" \
		--output "$tmp/response.html" --write-out '%{http_code} %{url_effective}' "$url" 2>"$errfile"); then
		report FAIL horizon-login "$(curl_error)"
		return
	fi

	# The path of the last URL, without its query.
	code=${out%% *}
	path=/${out#*://*/}
	path=${path%%[?#]*}
	if [ "$code" = 200 ] && [[ $path != /auth/login* ]]; then
		report ok horizon-login "admin logged in to https://$hostname and reached $path"
	else
		report FAIL horizon-login "the login of admin ended on $path with status $code"
	fi
}

controlplane=$(access_controlplane) || exit 1
if [ -z "$controlplane" ]; then
	echo "verify: sandbox-management runs no ControlPlane, 0 of 0 checks passed"
	exit 0
fi
command -v openstack >/dev/null || die 'verify: openstack not found in PATH, see "Host requirements" in the README'

# The checks run with the seven variables of access_load and with no other
# OS_ variable of the caller, such as OS_CLOUD, which would add the settings
# of another cloud.
for name in $(compgen -e); do
	if [[ $name == OS_* ]]; then
		unset "$name"
	fi
done
access_load

# The checks of the service <key> are the function check_<key>. They run in
# the order of the table above, whatever the order of spec.services.
declared=$(jq -r '.spec.services // {} | keys[]' <<<"$controlplane")
for service in keystone glance placement barbican neutron cinder nova horizon; do
	if grep -qx -- "$service" <<<"$declared"; then
		"check_$service"
	fi
done
check_compute
check_orders

echo "verify: $passed of $total checks passed"
if [ "$passed" -ne "$total" ]; then
	exit 1
fi
