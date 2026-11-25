#!/usr/bin/env bats
# make env and make verify: scripts/env.sh and scripts/verify.sh with docker,
# kind, kubectl, openstack, curl and sleep replaced by exported functions.
# The scripts run from a copy of scripts/, so the .sandbox they read and
# write is the copy's and not the repository's.

bats_require_minimum_version 1.5.0

setup() {
	load helpers
}

PASSWORD='p w$'
CA_PEM='-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIQc2FuZGJveCBjYSBvZiBhIHRlc3Q=
-----END CERTIFICATE-----'
AUTH_URL=https://keystone.172-30-255-10.nip.io/v3

# controlplane <hostname>: writes the ControlPlane of the hub with the
# Keystone hostname.
controlplane() {
	jq -n --arg hostname "$1" '{apiVersion: "c5c3.io/v1alpha1", kind: "ControlPlane",
		metadata: {name: "controlplane", namespace: "openstack"},
		spec: {services: {keystone: {gateway: {hostname: $hostname}}}}}' >"$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# secret <file> <key> <value>: writes a Secret of the hub whose key holds the
# value, base64-encoded as the API server serves it.
secret() {
	jq -n --arg key "$2" --arg value "$(printf '%s' "$3" | base64 -w 0)" \
		'{apiVersion: "v1", kind: "Secret", data: {($key): $value}}' >"$BATS_TEST_TMPDIR/hub/$1"
}

# access_host: a copy of scripts/ with a kubeconfig file for management,
# docker and kind answering for a sandbox-management on the sandbox network,
# and a kubectl that appends its arguments to kubectl.log in the test's
# directory and answers from the files of hub/ there, a missing file as a
# missing object: the four reads of scripts/lib/access.sh, and for
# nova-server the reads of the Deployment controlplane-fake-compute and its
# pods and the exec of discover_hosts. The hub has the CRD, a ControlPlane
# with the Keystone hostname of AUTH_URL, the admin password PASSWORD and the
# CA CA_PEM. kubectl fails like an unreachable server for the call whose file
# name KUBECTL_FAILS names.
access_host() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig" "$BATS_TEST_TMPDIR/hub"
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	echo '{"kind": "CustomResourceDefinition", "metadata": {"name": "controlplanes.c5c3.io"}}' >"$BATS_TEST_TMPDIR/hub/crd"
	controlplane keystone.172-30-255-10.nip.io
	secret admin.json password "$PASSWORD"
	secret ca.json tls.crt "$CA_PEM"
	kind() {
		case $* in
		"get clusters") echo sandbox-management ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		*) return 1 ;;
		esac
	}
	docker() { echo 'cobaltcore-sandbox '; }
	kubectl() {
		local file
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/kubectl.log"
		case $* in
		*" get crd controlplanes.c5c3.io --ignore-not-found -o json") file=crd ;;
		*" -n openstack get controlplanes.c5c3.io controlplane --ignore-not-found -o json") file=controlplane.json ;;
		*" -n openstack get secret controlplane-keystone-admin-credentials --ignore-not-found -o json") file=admin.json ;;
		*" -n cert-manager get secret sandbox-ca --ignore-not-found -o json") file=ca.json ;;
		*" -n openstack get deployment controlplane-fake-compute --ignore-not-found -o json") file=fake-compute.json ;;
		*" -n openstack get pods -l app.kubernetes.io/name=nova-fake-compute -o json") file=fake-compute-pods.json ;;
		*" -n openstack exec deploy/controlplane-nova-conductor -c conductor -- nova-manage --config-dir /etc/nova/nova.conf.d cell_v2 discover_hosts")
			file=discover-hosts
			;;
		*)
			echo "unexpected kubectl $*" >&2
			return 1
			;;
		esac
		if [ "$file" = "${KUBECTL_FAILS:-}" ]; then
			printf 'E1125 memcache.go\nThe connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?\n' >&2
			return 1
		fi
		if [ -f "$BATS_TEST_TMPDIR/hub/$file" ]; then
			cat -- "$BATS_TEST_TMPDIR/hub/$file"
		fi
	}
	export -f kind docker kubectl
}

# openstack_logs: replaces openstack with a function that appends its
# arguments to openstack.log in the test's directory and answers every call
# of verify.sh as a healthy cloud does: token issue with a token, or with
# TOKEN_ERROR on stderr and status 1 when it is set; catalog list with
# catalog.json; compute service list -f json with services.json; a create
# with the id id-<name>, an image create after it writes the size of the file
# of --file to image-size.<name> in the test's directory; the status of the
# image sandbox-verify-image, of the image sandbox-verify-boot, of the
# network, the volume, the compute service and the server with IMAGE_STATUS,
# BOOT_STATUS, NETWORK_STATUS, VOLUME_STATUS, COMPUTE_STATE and
# SERVER_STATUS, which default to the healthy one; resource class list with
# CLASSES; secret get with PAYLOAD; the fault of the server with FAULT; the
# leftover secrets with the hrefs of SECRET_LEFTOVERS; a delete with nothing.
# As openstack 6.6.0 does, it refuses a server create with --nic none
# without --os-compute-api-version 2.37, and with SERVER_ABSENT set a server
# show of sandbox-verify-server fails as for a server that does not exist. A
# call whose arguments match the pattern STUB_FAILS prints STUB_ERROR, by
# default an unreachable endpoint, on stderr and fails, and one that matches
# STUB_SILENT prints nothing. The names do not start with OS_, which
# verify.sh unsets.
openstack_logs() {
	openstack() {
		local arg prev=
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/openstack.log"
		# shellcheck disable=SC2053 # STUB_FAILS and STUB_SILENT are patterns.
		if [[ -n ${STUB_FAILS:-} && $* == $STUB_FAILS ]]; then
			printf '%s\n' "${STUB_ERROR:-Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens}" >&2
			return 1
		elif [[ -n ${STUB_SILENT:-} && $* == $STUB_SILENT ]]; then
			return 0
		elif [[ -n ${SERVER_ABSENT:-} && $* == "server show sandbox-verify-server "* ]]; then
			echo 'No Server found for sandbox-verify-server' >&2
			return 1
		fi
		case $* in
		"token issue -f value -c id")
			if [ -n "${TOKEN_ERROR:-}" ]; then
				printf '%s\n' "$TOKEN_ERROR" >&2
				return 1
			fi
			echo gAAAAABsandboxtoken
			;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		"image show id-sandbox-verify-image -f value -c status") echo "${IMAGE_STATUS:-active}" ;;
		"image show id-sandbox-verify-boot -f value -c status") echo "${BOOT_STATUS:-active}" ;;
		"resource class list -f value -c name")
			printf '%s\n' "${CLASSES:-VCPU
MEMORY_MB
DISK_GB
PCI_DEVICE
IPV4_ADDRESS}"
			;;
		"secret list --name sandbox-verify-secret -f value -c Secret href") printf '%s' "${SECRET_LEFTOVERS:-}" ;;
		"secret store --name sandbox-verify-secret --payload sandbox-verify-payload -f value -c Secret href")
			echo https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe
			;;
		"secret get -p https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe -f value -c Payload")
			echo "${PAYLOAD:-sandbox-verify-payload}"
			;;
		"network show id-sandbox-verify-net -f value -c status") echo "${NETWORK_STATUS:-ACTIVE}" ;;
		"volume show id-sandbox-verify-volume -f value -c status") echo "${VOLUME_STATUS:-available}" ;;
		"compute service list -f json") cat -- "$BATS_TEST_TMPDIR/services.json" ;;
		"compute service list --service nova-compute --host sandbox-management-control-plane -f value -c State")
			echo "${COMPUTE_STATE:-up}"
			;;
		"server show sandbox-verify-server -f value -c status") echo "${SERVER_STATUS:-ACTIVE}" ;;
		"server show sandbox-verify-server -f json -c fault")
			jq -n --arg message "${FAULT:-}" '{fault: {code: 500, created: "2026-11-25T10:00:00Z", message: $message}}'
			;;
		"image create "*)
			for arg; do
				if [ "$prev" = --file ]; then
					stat -c %s -- "$arg" >"$BATS_TEST_TMPDIR/image-size.${!#}"
				fi
				prev=$arg
			done
			printf 'id-%s\n' "${!#}"
			;;
		"server create "*" --nic none "*)
			echo '--os-compute-api-version 2.37 or greater is required to support explicit auto-allocation of a network or to disable network allocation' >&2
			return 1
			;;
		*" create "*) printf 'id-%s\n' "${!#}" ;;
		*" delete "*) : ;;
		*)
			echo "unexpected openstack $*" >&2
			return 1
			;;
		esac
	}
	export -f openstack
}

# catalog_with <url>: writes the catalog of openstack 6.6.0 under -f json,
# with the identity service at the public URL and an internal endpoint.
catalog_with() {
	jq -n --arg url "$1" '[{Name: "keystone", Type: "identity", Endpoints: [
		{id: "a1", interface: "internal", region_id: "RegionOne", url: "http://keystone-api.openstack.svc/v3", region: "RegionOne"},
		{id: "a2", interface: "public", region_id: "RegionOne", url: $url, region: "RegionOne"}]}]' >"$BATS_TEST_TMPDIR/catalog.json"
}

# controlplane_services <service>...: writes the ControlPlane of the hub with
# the services in the order given, each published by the Gateway
# openstack-gw at <service>.172-30-255-10.nip.io.
controlplane_services() {
	jq -n '{apiVersion: "c5c3.io/v1alpha1", kind: "ControlPlane",
		metadata: {name: "controlplane", namespace: "openstack"},
		spec: {services: ($ARGS.positional | map({key: ., value: {gateway: {parentRef: {name: "openstack-gw"},
			hostname: (. + ".172-30-255-10.nip.io")}}}) | from_entries)}}' --args "$@" >"$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# hub_edit <jq filter>: changes the ControlPlane of the hub with the filter.
hub_edit() {
	jq "$1" "$BATS_TEST_TMPDIR/hub/controlplane.json" >"$BATS_TEST_TMPDIR/cp.json"
	mv -- "$BATS_TEST_TMPDIR/cp.json" "$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# catalog_edit <jq filter>: changes catalog.json with the filter.
catalog_edit() {
	jq "$1" "$BATS_TEST_TMPDIR/catalog.json" >"$BATS_TEST_TMPDIR/c.json"
	mv -- "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/catalog.json"
}

# healthy_catalog: writes the catalog of the eight services, each with an
# internal endpoint and a public one at its Gateway, Cinder and Nova with
# the version that their registration appends.
healthy_catalog() {
	jq -n --arg auth "$AUTH_URL" '
		def service($name; $type; $public; $internal): {Name: $name, Type: $type, Endpoints: [
			{id: ($name + "-internal"), interface: "internal", region_id: "RegionOne", url: $internal, region: "RegionOne"},
			{id: ($name + "-public"), interface: "public", region_id: "RegionOne", url: $public, region: "RegionOne"}]};
		[service("keystone"; "identity"; $auth; "http://keystone-api.openstack.svc/v3"),
		service("glance"; "image"; "https://glance.172-30-255-10.nip.io"; "http://controlplane-glance.openstack.svc:9292"),
		service("placement"; "placement"; "https://placement.172-30-255-10.nip.io"; "http://controlplane-placement.openstack.svc:8778"),
		service("barbican"; "key-manager"; "https://barbican.172-30-255-10.nip.io"; "http://controlplane-barbican.openstack.svc:9311"),
		service("neutron"; "network"; "https://neutron.172-30-255-10.nip.io"; "http://controlplane-neutron.openstack.svc:9696"),
		service("cinder"; "block-storage"; "https://cinder.172-30-255-10.nip.io/v3"; "http://controlplane-cinder.openstack.svc:8776/v3"),
		service("nova"; "compute"; "https://nova.172-30-255-10.nip.io/v2.1"; "http://controlplane-nova.openstack.svc:8774/v2.1")]' >"$BATS_TEST_TMPDIR/catalog.json"
}

# compute_services <state of the scheduler> <state of the conductor>: writes
# services.json, the compute services of openstack 6.6.0 under -f json, with
# a nova-scheduler and a nova-conductor in the states given and a
# nova-scheduler of a replaced pod that is down.
compute_services() {
	jq -n --arg scheduler "$1" --arg conductor "$2" '[
		{ID: "1", Binary: "nova-scheduler", Host: "controlplane-nova-scheduler-5b7d9-old", Zone: "internal", Status: "enabled", State: "down", "Updated At": "2026-11-25T09:00:00.000000"},
		{ID: "2", Binary: "nova-scheduler", Host: "controlplane-nova-scheduler-5b7d9-x2k4p", Zone: "internal", Status: "enabled", State: $scheduler, "Updated At": "2026-11-25T10:00:00.000000"},
		{ID: "3", Binary: "nova-conductor", Host: "controlplane-nova-conductor-6c8f4-q7r2s", Zone: "internal", Status: "enabled", State: $conductor, "Updated At": "2026-11-25T10:00:00.000000"}]' >"$BATS_TEST_TMPDIR/services.json"
}

# login_page: writes the login page of the dashboard that the curl stub
# serves: a hidden input before the form, and in the form three hidden
# inputs in double, single and no quotes, with their attributes in other
# orders and one over two lines, beside the visible inputs.
login_page() {
	cat >"$BATS_TEST_TMPDIR/login.html" <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Login - OpenStack Dashboard</title></head>
<body>
<input type="hidden" name="outside" value="not-of-the-form">
<form id="" class="ng-pristine ng-valid" method="POST" action="/auth/login/" autocomplete="off">
<input type="hidden" name="csrfmiddlewaretoken" value="Zx9pQcsrfTokenOfTheForm">
<input name='region' type='hidden' value='default' id='id_region'>
<input id="id_next" value="/project/" type=hidden
  name="next" />
<input style="display:none" type="text" name="fake_email" value="" />
<input style="display:none" type="password" name="fake_password" value="" />
<input class="form-control" id="id_username" name="username" type="text" autofocus="autofocus" />
<input class="form-control" id="id_password" name="password" type="password" />
</form>
</body>
</html>
EOF
}

# curl_logs: replaces curl with a function that appends its arguments to
# curl.log in the test's directory, one per line and each call closed by a
# line --, and copies the file of --data-urlencode password@<file> to
# posted-password, with its mode in posted-password.mode and its path in
# posted-password.path. It answers as the dashboard of a healthy cloud
# does: a call without data writes login.html to the file of --output, and
# a call with data prints, as --write-out '%{http_code} %{url_effective}'
# does, the status HORIZON_STATUS, 200 by default, and the URL of the path
# HORIZON_PATH, /project/ by default. With CURL_ERROR set it prints it on
# stderr and fails as curl does.
curl_logs() {
	curl() {
		local arg prev= output= data=
		{
			printf '%s\n' "$@"
			echo --
		} >>"$BATS_TEST_TMPDIR/curl.log"
		for arg; do
			case $prev in
			--output) output=$arg ;;
			--data-urlencode)
				data=1
				if [[ $arg == password@* ]]; then
					cp -- "${arg#password@}" "$BATS_TEST_TMPDIR/posted-password"
					stat -c %a -- "${arg#password@}" >"$BATS_TEST_TMPDIR/posted-password.mode"
					printf '%s\n' "${arg#password@}" >"$BATS_TEST_TMPDIR/posted-password.path"
				fi
				;;
			esac
			prev=$arg
		done
		if [ -n "${CURL_ERROR:-}" ]; then
			printf '%s\n' "$CURL_ERROR" >&2
			return 60
		fi
		if [ -z "$data" ]; then
			cat -- "$BATS_TEST_TMPDIR/login.html" >"$output"
		else
			echo '<html><title>Instance Overview - OpenStack Dashboard</title></html>' >"$output"
			printf '%s https://horizon.172-30-255-10.nip.io%s' "${HORIZON_STATUS:-200}" "${HORIZON_PATH:-/project/}"
		fi
	}
	export -f curl
}

# curl_call <n>: prints the arguments of the n-th call of curl, one per line.
curl_call() {
	awk -v n="$1" '$0 == "--" { call++; next } call == n - 1' "$BATS_TEST_TMPDIR/curl.log"
}

# healthy_cloud: access_host, openstack_logs and curl_logs with a hub and a
# cloud that pass every check of verify.sh. The ControlPlane declares the
# eight services in the reverse of the order of the checks, the catalog
# publishes each at its hostname, the scheduler and the conductor are up,
# the Deployment controlplane-fake-compute has a pod on
# sandbox-management-control-plane, and discover_hosts succeeds. sleep
# returns at once and appends its argument to sleep.log.
healthy_cloud() {
	access_host
	controlplane_services horizon nova cinder neutron barbican placement glance keystone
	healthy_catalog
	compute_services up up
	echo '{"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "controlplane-fake-compute", "namespace": "openstack"}}' \
		>"$BATS_TEST_TMPDIR/hub/fake-compute.json"
	jq -n '{apiVersion: "v1", kind: "List", items: [{apiVersion: "v1", kind: "Pod",
		metadata: {name: "controlplane-fake-compute-7d9f8-m4n6t", namespace: "openstack"},
		spec: {nodeName: "sandbox-management-control-plane"}}]}' >"$BATS_TEST_TMPDIR/hub/fake-compute-pods.json"
	echo 'Found 1 cell mappings.' >"$BATS_TEST_TMPDIR/hub/discover-hosts"
	login_page
	openstack_logs
	curl_logs
	sleep() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/sleep.log"; }
	export -f sleep
}

# verify_fails <line> <passed>: runs verify.sh and checks that it exits 1,
# prints the line, and ends with verify: <passed> of 16 checks passed.
verify_fails() {
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 1 ]
	grep -qxF -- "$1" <<<"$output"
	[ "${lines[-1]}" = "verify: $2 of 16 checks passed" ]
}

# logged <pattern>: prints the number of each line of openstack.log that
# matches the pattern, one per line.
logged() {
	local line n=0
	while IFS= read -r line; do
		n=$((n + 1))
		# shellcheck disable=SC2053 # the argument is a pattern.
		if [[ $line == $1 ]]; then
			echo "$n"
		fi
	done <"$BATS_TEST_TMPDIR/openstack.log"
}

# runs_before <pattern> <pattern>: succeeds when the first call of
# openstack.log that matches the first pattern comes before the last call
# that matches the second.
runs_before() {
	local first second
	first=$(logged "$1" | head -n 1)
	second=$(logged "$2" | tail -n 1)
	[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

# env_fails <message>: runs env.sh and checks that it exits 1 with
# error: <message> on stderr, prints nothing on stdout, and that no message
# holds the password, plain or base64-encoded.
env_fails() {
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
	[ "$stderr" = "error: $1" ]
	[[ $stderr != *"$PASSWORD"* ]]
	[[ $stderr != *"$(printf '%s' "$PASSWORD" | base64 -w 0)"* ]]
}

@test "env.sh prints seven export lines that load the admin of the ControlPlane, and writes the CA" {
	local names=(OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_CACERT) i
	access_host
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 0 ]
	[ "$stderr" = "" ]
	[ "$(grep -c '' <<<"$output")" -eq 7 ]
	for i in "${!names[@]}"; do
		[[ ${lines[i]} == "export ${names[i]}="* ]]
	done

	eval "$output"
	[ "$OS_AUTH_URL" = "$AUTH_URL" ]
	[ "$OS_USERNAME" = admin ]
	[ "$OS_PASSWORD" = "$PASSWORD" ]
	[ "$OS_PROJECT_NAME" = admin ]
	[ "$OS_USER_DOMAIN_NAME" = Default ]
	[ "$OS_PROJECT_DOMAIN_NAME" = Default ]
	[ "$OS_CACERT" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
	[ "$(<"$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem")" = "$CA_PEM" ]
	# The temporary file is renamed, not left beside it.
	[ "$(find "$BATS_TEST_TMPDIR/.sandbox" -maxdepth 1 -type f)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "env.sh restores a missing kubeconfig with its message on stderr and seven lines on stdout" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	kind() {
		case $* in
		"get clusters") echo sandbox-management ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		"export kubeconfig --name sandbox-management --kubeconfig "*) : >"${!#}" ;;
		*) return 1 ;;
		esac
	}
	export -f kind
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 0 ]
	[ "$stderr" = "env: restoring $BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml" ]
	[ "$(grep -c '' <<<"$output")" -eq 7 ]
	[ "$(grep -c '^export OS_' <<<"$output")" -eq 7 ]
}

@test "env.sh fails without a management cluster" {
	access_host
	kind() { [ "$*" = "get clusters" ]; }
	export -f kind
	env_fails "access: sandbox-management does not exist; run make up"
}

@test "env.sh fails without the CRD of the ControlPlane" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/crd"
	env_fails "access: no ControlPlane openstack/controlplane on sandbox-management; the profile runs no control plane"
}

@test "env.sh fails without the ControlPlane openstack/controlplane" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/controlplane.json"
	env_fails "access: no ControlPlane openstack/controlplane on sandbox-management; the profile runs no control plane"
}

@test "env.sh fails for an empty or absent Keystone hostname" {
	access_host
	controlplane ""
	env_fails "access: the ControlPlane openstack/controlplane publishes no Keystone hostname"
	jq 'del(.spec.services.keystone.gateway)' "$BATS_TEST_TMPDIR/hub/controlplane.json" >"$BATS_TEST_TMPDIR/cp.json"
	mv -- "$BATS_TEST_TMPDIR/cp.json" "$BATS_TEST_TMPDIR/hub/controlplane.json"
	env_fails "access: the ControlPlane openstack/controlplane publishes no Keystone hostname"
}

@test "env.sh fails without the Secret of the admin password" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/admin.json"
	env_fails "access: the Secret openstack/controlplane-keystone-admin-credentials holds no password; the ControlPlane is not Ready, make status shows its stage"
}

@test "env.sh fails for an empty admin password" {
	access_host
	secret admin.json password ""
	env_fails "access: the Secret openstack/controlplane-keystone-admin-credentials holds no password; the ControlPlane is not Ready, make status shows its stage"
}

@test "env.sh fails for an empty or missing tls.crt and writes no CA" {
	access_host
	secret ca.json tls.crt ""
	env_fails "access: the Secret cert-manager/sandbox-ca holds no tls.crt"
	rm -- "$BATS_TEST_TMPDIR/hub/ca.json"
	env_fails "access: the Secret cert-manager/sandbox-ca holds no tls.crt"
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "env.sh fails with the object and the last line of kubectl when kubectl cannot read it" {
	local refused="The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?"
	access_host
	export KUBECTL_FAILS=crd
	env_fails "access: cannot read the CRD controlplanes.c5c3.io: $refused"
	KUBECTL_FAILS=controlplane.json
	env_fails "access: cannot read the ControlPlane openstack/controlplane: $refused"
	KUBECTL_FAILS=admin.json
	env_fails "access: cannot read the Secret openstack/controlplane-keystone-admin-credentials: $refused"
	KUBECTL_FAILS=ca.json
	env_fails "access: cannot read the Secret cert-manager/sandbox-ca: $refused"
}

@test "verify.sh without a ControlPlane passes 0 of 0 checks and never calls openstack" {
	local file
	access_host
	openstack_logs
	for file in controlplane.json crd; do
		rm -- "$BATS_TEST_TMPDIR/hub/$file"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		[ "$status" -eq 0 ]
		[ "$output" = "verify: sandbox-management runs no ControlPlane, 0 of 0 checks passed" ]
	done
	[ ! -e "$BATS_TEST_TMPDIR/openstack.log" ]
}

@test "verify.sh with a ControlPlane fails without openstack in PATH" {
	local tool
	access_host
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	for tool in dirname mktemp rm grep cat; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: verify: openstack not found in PATH, see "Host requirements" in the README' ]
}

@test "verify.sh passes the token and the catalog checks of keystone without --insecure" {
	access_host
	openstack_logs
	catalog_with "$AUTH_URL"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 3 ]
	[[ ${lines[0]} == "ok keystone-token: "* ]]
	[[ ${lines[1]} == "ok keystone-catalog: "* ]]
	[ "${lines[2]}" = "verify: 2 of 2 checks passed" ]
	[[ $output != *gAAAAABsandboxtoken* ]]
	[ "$(<"$BATS_TEST_TMPDIR/openstack.log")" = "token issue -f value -c id
catalog list -f json" ]
	run ! grep -q -e --insecure "$BATS_TEST_TMPDIR/openstack.log"
}

@test "verify.sh runs openstack with the variables of env.sh and no other OS_ variable" {
	access_host
	catalog_with "$AUTH_URL"
	openstack() {
		env | grep '^OS_' | LC_ALL=C sort >"$BATS_TEST_TMPDIR/openstack.env"
		case $* in
		"token issue -f value -c id") echo gAAAAABsandboxtoken ;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		esac
	}
	export -f openstack
	export OS_CLOUD=elsewhere OS_TOKEN=foreign OS_PASSWORD=foreign
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(<"$BATS_TEST_TMPDIR/openstack.env")" = "OS_AUTH_URL=$AUTH_URL
OS_CACERT=$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem
OS_PASSWORD=$PASSWORD
OS_PROJECT_DOMAIN_NAME=Default
OS_PROJECT_NAME=admin
OS_USERNAME=admin
OS_USER_DOMAIN_NAME=Default" ]
}

@test "verify.sh fails the catalog check without a public identity endpoint at OS_AUTH_URL, and exits 1 when one check of two failed" {
	local case
	access_host
	openstack_logs
	for case in other-url internal-only other-type; do
		case $case in
		other-url) catalog_with http://keystone.172-30-255-10.nip.io/v3 ;;
		internal-only)
			jq -n --arg url "$AUTH_URL" '[{Name: "keystone", Type: "identity", Endpoints: [
				{id: "a1", interface: "internal", region_id: "RegionOne", url: $url, region: "RegionOne"}]}]' >"$BATS_TEST_TMPDIR/catalog.json"
			;;
		other-type)
			catalog_with "$AUTH_URL"
			jq '.[0].Type = "compute"' "$BATS_TEST_TMPDIR/catalog.json" >"$BATS_TEST_TMPDIR/c.json"
			mv -- "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/catalog.json"
			;;
		esac
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 1 ]
		[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
FAIL keystone-catalog: no public identity endpoint $AUTH_URL in the catalog
verify: 1 of 2 checks passed" ]
	done
}

@test "verify.sh fails the token check when openstack prints no token id, and names the first line of a longer error" {
	access_host
	catalog_with "$AUTH_URL"
	openstack() {
		case $* in
		"token issue -f value -c id") : ;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		esac
	}
	export -f openstack
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "FAIL keystone-token: openstack token issue printed no token id" ]
	[ "${lines[-1]}" = "verify: 1 of 2 checks passed" ]

	openstack_logs
	export TOKEN_ERROR="Failed to discover available identity versions when contacting $AUTH_URL.
SSL exception connecting to $AUTH_URL/auth/tokens"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "FAIL keystone-token: Failed to discover available identity versions when contacting $AUTH_URL." ]
	[ "${lines[-1]}" = "verify: 1 of 2 checks passed" ]
}

@test "verify.sh fails each keystone check with the first line of its error" {
	access_host
	openstack_logs
	export TOKEN_ERROR="SSL exception connecting to $AUTH_URL"
	echo '[]' >"$BATS_TEST_TMPDIR/catalog.json"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "FAIL keystone-token: SSL exception connecting to $AUTH_URL
FAIL keystone-catalog: no public identity endpoint $AUTH_URL in the catalog
verify: 0 of 2 checks passed" ]
}

@test "verify.sh passes the 16 checks of the eight services in the fixed order, whatever the order of spec.services" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
ok keystone-catalog: the catalog holds the public identity endpoint $AUTH_URL
ok glance-catalog: the catalog holds a public image endpoint at https://glance.172-30-255-10.nip.io
ok glance-image: a 1 KiB image uploaded as sandbox-verify-image became active
ok placement-catalog: the catalog holds a public placement endpoint at https://placement.172-30-255-10.nip.io
ok placement-classes: resource class list holds VCPU, MEMORY_MB and DISK_GB
ok barbican-catalog: the catalog holds a public key-manager endpoint at https://barbican.172-30-255-10.nip.io
ok barbican-secret: the payload of sandbox-verify-secret came back unchanged
ok neutron-catalog: the catalog holds a public network endpoint at https://neutron.172-30-255-10.nip.io
ok neutron-network: the network sandbox-verify-net with the subnet sandbox-verify-subnet on 192.0.2.0/24 is ACTIVE
ok cinder-catalog: the catalog holds a public block-storage endpoint at https://cinder.172-30-255-10.nip.io
ok cinder-volume: the 1 GiB volume sandbox-verify-volume is available
ok nova-catalog: the catalog holds a public compute endpoint at https://nova.172-30-255-10.nip.io
ok nova-services: a nova-scheduler and a nova-conductor service are up
ok nova-server: the server sandbox-verify-server is ACTIVE on the fake compute of sandbox-management-control-plane
ok horizon-login: admin logged in to https://horizon.172-30-255-10.nip.io and reached /project/
verify: 16 of 16 checks passed" ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,nova-server,horizon-login ]
	# One catalog serves the seven catalog checks, and nothing waits.
	[ "$(grep -cxF 'catalog list -f json' "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/sleep.log" ]
}

@test "verify.sh runs the checks of a service only when the ControlPlane declares it" {
	local case checks
	healthy_cloud
	for case in \
		glance:glance-catalog,glance-image \
		placement:placement-catalog,placement-classes \
		barbican:barbican-catalog,barbican-secret \
		neutron:neutron-catalog,neutron-network \
		cinder:cinder-catalog,cinder-volume \
		nova:nova-catalog,nova-services,nova-server \
		horizon:horizon-login; do
		controlplane_services "${case%%:*}" keystone
		rm -f -- "$BATS_TEST_TMPDIR/curl.log"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 0 ]
		[ "$(check_ids)" = "keystone-token,keystone-catalog,${case#*:}" ]
		checks=$((${#lines[@]} - 1))
		[ "${lines[-1]}" = "verify: $checks of $checks checks passed" ]
		if [ "${case%%:*}" != horizon ]; then
			[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
		fi
	done
}

@test "verify.sh creates the resources of upstream's Step 7 under sandbox-verify names, and maps the fake compute into the cell" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ -n "$(logged 'image create --disk-format raw --container-format bare --file */image.raw -f value -c id sandbox-verify-image')" ]
	[ -n "$(logged 'secret store --name sandbox-verify-secret --payload sandbox-verify-payload -f value -c Secret href')" ]
	[ -n "$(logged 'network create -f value -c id sandbox-verify-net')" ]
	[ -n "$(logged 'subnet create --network id-sandbox-verify-net --subnet-range 192.0.2.0/24 -f value -c id sandbox-verify-subnet')" ]
	[ -n "$(logged 'volume create --size 1 -f value -c id sandbox-verify-volume')" ]
	[ -n "$(logged 'flavor create --vcpus 1 --ram 128 --disk 1 -f value -c id sandbox-verify-flavor')" ]
	[ -n "$(logged 'image create --disk-format raw --container-format bare --file */boot.raw -f value -c id sandbox-verify-boot')" ]
	[ -n "$(logged '--os-compute-api-version 2.37 server create --image id-sandbox-verify-boot --flavor sandbox-verify-flavor --nic none --wait -f value -c id sandbox-verify-server')" ]
	# The server create alone asks for compute API 2.37, which --nic none
	# needs.
	[ "$(grep -c -- --os-compute-api-version "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
	runs_before 'compute service list --service nova-compute --host sandbox-management-control-plane -f value -c State' 'flavor create *'
	[ "$(grep -c ' exec ' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ]
	grep -qx -- "--kubeconfig $BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml -n openstack exec deploy/controlplane-nova-conductor -c conductor -- nova-manage --config-dir /etc/nova/nova.conf.d cell_v2 discover_hosts" \
		"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh uploads a 1 KiB image as sandbox-verify-image and a 1 MiB image as sandbox-verify-boot" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(<"$BATS_TEST_TMPDIR/image-size.sandbox-verify-image")" -eq 1024 ]
	[ "$(<"$BATS_TEST_TMPDIR/image-size.sandbox-verify-boot")" -eq 1048576 ]
}

@test "verify.sh passes no --insecure and no -k to openstack or curl, and curl trusts OS_CACERT" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	run ! grep -E -e '(^| )(--insecure|-[a-zA-Z]*k)( |$)' "$BATS_TEST_TMPDIR/openstack.log"
	run ! grep -E -e '^(--insecure|-[a-zA-Z]*k[a-zA-Z]*)$' "$BATS_TEST_TMPDIR/curl.log"
	[ "$(grep -cx -- -- "$BATS_TEST_TMPDIR/curl.log")" -eq 2 ]
	[ "$(curl_call 1 | grep -A 1 -x -- --cacert | tail -n 1)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
	[ "$(curl_call 2 | grep -A 1 -x -- --cacert | tail -n 1)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "verify.sh gives curl the admin password from a file of mode 600 in its temporary directory, never as an argument" {
	local encoded
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	for encoded in "$PASSWORD" 'p%20w%24' 'p+w%24' "$(printf '%s' "$PASSWORD" | base64 -w 0)"; do
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/curl.log"
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/openstack.log"
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/kubectl.log"
	done
	# The file holds the password alone, without a newline, and is gone
	# with the temporary directory, which also held the cookie jar.
	[ "$(<"$BATS_TEST_TMPDIR/posted-password")" = "$PASSWORD" ]
	[ "$(wc -c <"$BATS_TEST_TMPDIR/posted-password")" -eq "${#PASSWORD}" ]
	[ "$(<"$BATS_TEST_TMPDIR/posted-password.mode")" = 600 ]
	[ ! -e "$(<"$BATS_TEST_TMPDIR/posted-password.path")" ]
	[ "$(curl_call 2 | grep -A 1 -x -- --cookie | tail -n 1)" = "$(dirname -- "$(<"$BATS_TEST_TMPDIR/posted-password.path")")/cookies" ]
}

@test "verify.sh posts the hidden inputs of the login form back unchanged with the user, the domain and the password, and follows the redirects" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	# The GET reads the login page into the cookie jar.
	[ "$(curl_call 1 | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	curl_call 1 | grep -qx -- --cookie-jar
	run ! grep -qx -- --data-urlencode <<<"$(curl_call 1)"
	# The POST sends the cookies and names the login page as its referer.
	[ "$(curl_call 2 | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	[ "$(curl_call 2 | grep -A 1 -x -- --referer | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	curl_call 2 | grep -qx -- --location
	run --separate-stderr awk 'prev == "--data-urlencode" { print } { prev = $0 }' <<<"$(curl_call 2)"
	[ "${#lines[@]}" -eq 6 ]
	[ "${lines[0]}" = csrfmiddlewaretoken=Zx9pQcsrfTokenOfTheForm ]
	[ "${lines[1]}" = region=default ]
	[ "${lines[2]}" = next=/project/ ]
	[ "${lines[3]}" = username=admin ]
	[ "${lines[4]}" = domain=Default ]
	[[ ${lines[5]} == password@/*/password ]]
}

@test "verify.sh fails glance-catalog for a glance block without a hostname" {
	healthy_cloud
	hub_edit 'del(.spec.services.glance.gateway)'
	verify_fails "FAIL glance-catalog: the ControlPlane publishes no hostname for glance" 15
	hub_edit '.spec.services.glance.gateway = {parentRef: {name: "openstack-gw"}, hostname: ""}'
	verify_fails "FAIL glance-catalog: the ControlPlane publishes no hostname for glance" 15
}

@test "verify.sh fails glance-catalog without a public image endpoint at the hostname, and for an empty catalog" {
	local case
	healthy_cloud
	for case in no-row internal-only other-host other-port; do
		healthy_catalog
		case $case in
		no-row) catalog_edit 'map(select(.Type != "image"))' ;;
		internal-only) catalog_edit 'map(if .Type == "image" then .Endpoints |= map(select(.interface != "public")) else . end)' ;;
		other-host) catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io.example.org/" else . end)' ;;
		other-port) catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io:8443" else . end)' ;;
		esac
		echo "$case"
		verify_fails "FAIL glance-catalog: no public image endpoint at https://glance.172-30-255-10.nip.io in the catalog" 15
	done

	echo '[]' >"$BATS_TEST_TMPDIR/catalog.json"
	verify_fails "FAIL glance-catalog: no public image endpoint at https://glance.172-30-255-10.nip.io in the catalog" 9
	[ "$(grep -c -- '-catalog: ' <<<"$output")" -eq 7 ]
	[ "$(grep -c '^FAIL ' <<<"$output")" -eq 7 ]
}

@test "verify.sh passes a catalog check for an endpoint under the hostname" {
	healthy_cloud
	catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io/" else . end)'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${lines[2]}" = "ok glance-catalog: the catalog holds a public image endpoint at https://glance.172-30-255-10.nip.io" ]
}

@test "verify.sh fails each catalog check without the hostname of its service or the endpoint of its type" {
	local pair service type
	healthy_cloud
	for pair in glance:image placement:placement barbican:key-manager neutron:network cinder:block-storage nova:compute; do
		service=${pair%:*}
		type=${pair#*:}
		controlplane_services horizon nova cinder neutron barbican placement glance keystone
		hub_edit "del(.spec.services.$service.gateway.hostname)"
		verify_fails "FAIL $service-catalog: the ControlPlane publishes no hostname for $service" 15

		controlplane_services horizon nova cinder neutron barbican placement glance keystone
		healthy_catalog
		catalog_edit "map(select(.Type != \"$type\"))"
		verify_fails "FAIL $service-catalog: no public $type endpoint at https://$service.172-30-255-10.nip.io in the catalog" 15
		healthy_catalog
	done
}

@test "verify.sh fails every catalog check with the first line of the error of the one catalog read" {
	healthy_cloud
	export STUB_FAILS='catalog list -f json' STUB_ERROR="Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)
Max retries exceeded with url: /v3/auth/catalog"
	verify_fails "FAIL nova-catalog: Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)" 9
	[ "$(grep -c "^FAIL [a-z]*-catalog: Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: " <<<"$output")" -eq 7 ]
	[ "$(grep -cxF 'catalog list -f json' "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
}

@test "verify.sh fails each check with the first line of the error when openstack exits non-zero" {
	local case
	healthy_cloud
	export STUB_ERROR="Unable to establish connection to https://glance.172-30-255-10.nip.io/v2/images: HTTPSConnectionPool(host='glance.172-30-255-10.nip.io', port=443)
Max retries exceeded with url: /v2/images"
	for case in \
		'image create * sandbox-verify-image|glance-image' \
		'image show id-sandbox-verify-image *|glance-image' \
		'resource class list *|placement-classes' \
		'secret store *|barbican-secret' \
		'secret get *|barbican-secret' \
		'network create *|neutron-network' \
		'subnet create *|neutron-network' \
		'network show *|neutron-network' \
		'volume create *|cinder-volume' \
		'volume show *|cinder-volume' \
		'compute service list -f json|nova-services' \
		'compute service list --service *|nova-server' \
		'flavor create *|nova-server' \
		'image create * sandbox-verify-boot|nova-server' \
		'image show id-sandbox-verify-boot *|nova-server' \
		'*server *|nova-server'; do
		export STUB_FAILS=${case%|*}
		echo "$STUB_FAILS"
		verify_fails "FAIL ${case#*|}: Unable to establish connection to https://glance.172-30-255-10.nip.io/v2/images: HTTPSConnectionPool(host='glance.172-30-255-10.nip.io', port=443)" 15
	done
}

@test "verify.sh reports '' as the status when openstack prints nothing" {
	local case
	healthy_cloud
	export FAULT='No valid host was found. There are not enough hosts available.'
	for case in \
		"image show id-sandbox-verify-image *|FAIL glance-image: the image sandbox-verify-image is '' after 60 s, expected active" \
		"network show *|FAIL neutron-network: the network sandbox-verify-net is '', expected ACTIVE" \
		"volume show *|FAIL cinder-volume: the volume sandbox-verify-volume is '' after 120 s, expected available" \
		"compute service list --service *|FAIL nova-server: the compute service of sandbox-management-control-plane is '' after 120 s, expected up" \
		"image show id-sandbox-verify-boot *|FAIL nova-server: the image sandbox-verify-boot is '' after 60 s, expected active" \
		"server show sandbox-verify-server -f value -c status|FAIL nova-server: the server sandbox-verify-server is '', expected ACTIVE: No valid host was found. There are not enough hosts available."; do
		export STUB_SILENT=${case%%|*}
		echo "$STUB_SILENT"
		verify_fails "${case#*|}" 15
	done
}

@test "verify.sh fails glance-image when the image is not active after 60 s, polling every 2 s" {
	healthy_cloud
	export IMAGE_STATUS=saving
	verify_fails "FAIL glance-image: the image sandbox-verify-image is 'saving' after 60 s, expected active" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 30 ]
	[ "$(sort -u "$BATS_TEST_TMPDIR/sleep.log")" = 2 ]
	[ "$(logged 'image show id-sandbox-verify-image *' | grep -c '')" -eq 31 ]
}

@test "verify.sh fails placement-classes for each standard class the list lacks" {
	local class
	healthy_cloud
	for class in VCPU MEMORY_MB DISK_GB; do
		export CLASSES
		CLASSES=$(printf '%s\n' VCPU MEMORY_MB DISK_GB PCI_DEVICE | grep -vx -- "$class")
		verify_fails "FAIL placement-classes: resource class list holds no $class" 15
	done
}

@test "verify.sh fails barbican-secret when the payload comes back changed" {
	healthy_cloud
	export PAYLOAD=sandbox-verify-payload-changed
	verify_fails "FAIL barbican-secret: the payload of sandbox-verify-secret came back changed" 15
}

@test "verify.sh fails neutron-network when the network is not ACTIVE" {
	healthy_cloud
	export NETWORK_STATUS=DOWN
	verify_fails "FAIL neutron-network: the network sandbox-verify-net is 'DOWN', expected ACTIVE" 15
}

@test "verify.sh fails cinder-volume when the volume is not available after 120 s, polling every 2 s" {
	healthy_cloud
	export VOLUME_STATUS=creating
	verify_fails "FAIL cinder-volume: the volume sandbox-verify-volume is 'creating' after 120 s, expected available" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 60 ]
	[ "$(logged 'volume show id-sandbox-verify-volume *' | grep -c '')" -eq 61 ]
}

@test "verify.sh fails nova-services when no nova-scheduler or no nova-conductor is up" {
	healthy_cloud
	compute_services down up
	verify_fails "FAIL nova-services: no nova-scheduler service is up" 15
	compute_services up down
	verify_fails "FAIL nova-services: no nova-conductor service is up" 15
	echo '[]' >"$BATS_TEST_TMPDIR/services.json"
	verify_fails "FAIL nova-services: no nova-scheduler service is up" 15
}

@test "verify.sh reports two checks for nova without the Deployment controlplane-fake-compute" {
	healthy_cloud
	rm -- "$BATS_TEST_TMPDIR/hub/fake-compute.json"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,horizon-login ]
	[ "${lines[-1]}" = "verify: 15 of 15 checks passed" ]
	[ -z "$(logged '*server *')" ]
	[ -z "$(logged 'flavor *')" ]
	[ -z "$(logged '* sandbox-verify-boot')" ]
	run ! grep -q ' exec ' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh fails nova-server with the last line of kubectl when it cannot read the Deployment" {
	healthy_cloud
	export KUBECTL_FAILS=fake-compute.json
	verify_fails "FAIL nova-server: cannot read the Deployment openstack/controlplane-fake-compute: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
}

@test "verify.sh fails nova-server with the last line of kubectl when it cannot read the pods of the Deployment" {
	healthy_cloud
	export KUBECTL_FAILS=fake-compute-pods.json
	verify_fails "FAIL nova-server: cannot read the pods of the Deployment openstack/controlplane-fake-compute: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
	[ -z "$(logged 'compute service list --service *')" ]
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the Deployment controlplane-fake-compute has no pod" {
	healthy_cloud
	echo '{"apiVersion": "v1", "kind": "List", "items": []}' >"$BATS_TEST_TMPDIR/hub/fake-compute-pods.json"
	verify_fails "FAIL nova-server: the Deployment controlplane-fake-compute has no pod" 15
	[ -z "$(logged 'compute service list --service *')" ]
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the compute service is not up after 120 s, polling every 2 s" {
	healthy_cloud
	export COMPUTE_STATE=down
	verify_fails "FAIL nova-server: the compute service of sandbox-management-control-plane is 'down' after 120 s, expected up" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 60 ]
	[ "$(logged 'compute service list --service *' | grep -c '')" -eq 61 ]
	[ -z "$(logged 'flavor create *')" ]
	run ! grep -q ' exec ' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh fails nova-server with the last line of kubectl when discover_hosts cannot run in the conductor" {
	healthy_cloud
	export KUBECTL_FAILS=discover-hosts
	verify_fails "FAIL nova-server: cannot run nova-manage cell_v2 discover_hosts in deploy/controlplane-nova-conductor: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the boot image is not active after 60 s" {
	healthy_cloud
	export BOOT_STATUS=queued
	verify_fails "FAIL nova-server: the image sandbox-verify-boot is 'queued' after 60 s, expected active" 15
	[ -z "$(logged '* server create *')" ]
}

@test "verify.sh fails nova-server when the server is not ACTIVE, with the first line of its fault" {
	healthy_cloud
	export SERVER_STATUS=ERROR FAULT='No valid host was found. There are not enough hosts available.
Traceback (most recent call last):'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found. There are not enough hosts available." 15

	# server create --wait fails for a server in ERROR; its status and fault
	# are the message.
	export STUB_FAILS='* server create *' STUB_ERROR='Error creating server: sandbox-verify-server'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found. There are not enough hosts available." 15
}

@test "verify.sh fails nova-server with the first line of the error of server create when there is no server to show, else with that of server show" {
	local refused='--os-compute-api-version 2.37 or greater is required to support explicit auto-allocation of a network or to disable network allocation'
	healthy_cloud
	export SERVER_ABSENT=1
	verify_fails "FAIL nova-server: No Server found for sandbox-verify-server" 15

	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export STUB_FAILS='* server create *' STUB_ERROR="$refused
Usage: openstack server create [-h]"
	verify_fails "FAIL nova-server: $refused" 15
	[ -n "$(logged 'server show sandbox-verify-server -f value -c status')" ]
}

@test "verify.sh fails horizon-login for a horizon block without a hostname, and calls no curl" {
	healthy_cloud
	hub_edit 'del(.spec.services.horizon.gateway)'
	verify_fails "FAIL horizon-login: the ControlPlane publishes no hostname for horizon" 15
	[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "verify.sh fails horizon-login without curl in PATH" {
	local tool
	access_host
	controlplane_services keystone horizon
	catalog_with "$AUTH_URL"
	openstack_logs
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	for tool in dirname mktemp rm grep cat jq mkdir mv tail; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
ok keystone-catalog: the catalog holds the public identity endpoint $AUTH_URL
FAIL horizon-login: curl not found in PATH
verify: 2 of 3 checks passed" ]
}

@test "verify.sh fails horizon-login when the login ends on the login page or without status 200" {
	healthy_cloud
	export HORIZON_PATH='/auth/login/?next=/project/'
	verify_fails "FAIL horizon-login: the login of admin ended on /auth/login/ with status 200" 15
	export HORIZON_PATH=/auth/login/ HORIZON_STATUS=403
	verify_fails "FAIL horizon-login: the login of admin ended on /auth/login/ with status 403" 15
	export HORIZON_PATH=/project/ HORIZON_STATUS=500
	verify_fails "FAIL horizon-login: the login of admin ended on /project/ with status 500" 15
}

@test "verify.sh fails horizon-login with the first line of the error of curl" {
	healthy_cloud
	export CURL_ERROR='curl: (60) SSL certificate problem: unable to get local issuer certificate
More details here: https://curl.se/docs/sslcerts.html'
	verify_fails "FAIL horizon-login: curl: (60) SSL certificate problem: unable to get local issuer certificate" 15
}

@test "verify.sh deletes what an earlier run left of its sandbox-verify names before it creates" {
	healthy_cloud
	export SECRET_LEFTOVERS='https://barbican.172-30-255-10.nip.io/v1/secrets/0ld1
https://barbican.172-30-255-10.nip.io/v1/secrets/0ld2'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	runs_before 'image delete sandbox-verify-image' 'image create * sandbox-verify-image'
	runs_before 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/0ld1' 'secret store *'
	runs_before 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/0ld2' 'secret store *'
	runs_before 'subnet delete sandbox-verify-subnet' 'network create *'
	runs_before 'network delete sandbox-verify-net' 'network create *'
	runs_before 'volume delete sandbox-verify-volume' 'volume create *'
	runs_before 'server delete --wait sandbox-verify-server' 'flavor create *'
	runs_before 'image delete sandbox-verify-boot' 'flavor create *'
	runs_before 'flavor delete sandbox-verify-flavor' 'flavor create *'
}

@test "verify.sh deletes every sandbox-verify resource a failed check created" {
	healthy_cloud
	export IMAGE_STATUS=saving PAYLOAD=changed NETWORK_STATUS=DOWN VOLUME_STATUS=error SERVER_STATUS=ERROR \
		FAULT='No valid host was found.'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found." 11
	[ "$(grep -c '^FAIL ' <<<"$output")" -eq 5 ]
	runs_before 'image create * sandbox-verify-image' 'image delete id-sandbox-verify-image'
	runs_before 'secret store *' 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe'
	runs_before 'subnet create * sandbox-verify-subnet' 'subnet delete id-sandbox-verify-subnet'
	runs_before 'subnet delete id-sandbox-verify-subnet' 'network delete id-sandbox-verify-net'
	runs_before 'volume create * sandbox-verify-volume' 'volume delete id-sandbox-verify-volume'
	runs_before '* server create * sandbox-verify-server' 'server delete --wait sandbox-verify-server'
	runs_before 'server delete --wait sandbox-verify-server' 'image delete id-sandbox-verify-boot'
	runs_before 'image delete id-sandbox-verify-boot' 'flavor delete sandbox-verify-flavor'

	# A boot image that never becomes active leaves no flavor and no image.
	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export BOOT_STATUS=killed SERVER_STATUS=ACTIVE
	verify_fails "FAIL nova-server: the image sandbox-verify-boot is 'killed' after 60 s, expected active" 11
	runs_before 'image create * sandbox-verify-boot' 'image delete id-sandbox-verify-boot'
	runs_before 'flavor create *' 'flavor delete sandbox-verify-flavor'
}

@test "verify.sh exits 1 with 15 of 16 checks passed when one check failed" {
	healthy_cloud
	export PAYLOAD=changed
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${#lines[@]}" -eq 17 ]
	[ "$(grep -c '^ok ' <<<"$output")" -eq 15 ]
	[ "${lines[7]}" = "FAIL barbican-secret: the payload of sandbox-verify-secret came back changed" ]
	[ "${lines[16]}" = "verify: 15 of 16 checks passed" ]
}

@test "verify.sh does not report a failed delete" {
	healthy_cloud
	export STUB_FAILS='* delete *' STUB_ERROR='No image found for sandbox-verify-image'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 17 ]
	[ "${lines[16]}" = "verify: 16 of 16 checks passed" ]
	[ -n "$(logged '* delete *')" ]
}
