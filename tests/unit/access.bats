#!/usr/bin/env bats
# make env and make verify: scripts/env.sh and scripts/verify.sh with docker,
# kind, kubectl and openstack replaced by exported functions. The scripts run
# from a copy of scripts/, so the .sandbox they read and write is the copy's
# and not the repository's.

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
# and a kubectl that answers the four reads of scripts/lib/access.sh from the
# files of hub/ in the test's directory, a missing file as a missing object.
# The hub has the CRD, a ControlPlane with the Keystone hostname of AUTH_URL,
# the admin password PASSWORD and the CA CA_PEM. kubectl fails like an
# unreachable server for the read whose file name KUBECTL_FAILS names.
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
		case $* in
		*" get crd controlplanes.c5c3.io --ignore-not-found -o json") file=crd ;;
		*" -n openstack get controlplanes.c5c3.io controlplane --ignore-not-found -o json") file=controlplane.json ;;
		*" -n openstack get secret controlplane-keystone-admin-credentials --ignore-not-found -o json") file=admin.json ;;
		*" -n cert-manager get secret sandbox-ca --ignore-not-found -o json") file=ca.json ;;
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
# arguments to openstack.log in the test's directory and answers token issue
# with TOKEN_ERROR on stderr and status 1 when it is set, with a token
# otherwise, and catalog list with catalog.json.
openstack_logs() {
	openstack() {
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/openstack.log"
		case $* in
		"token issue -f value -c id")
			if [ -n "${TOKEN_ERROR:-}" ]; then
				printf '%s\n' "$TOKEN_ERROR" >&2
				return 1
			fi
			echo gAAAAABsandboxtoken
			;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		*) return 1 ;;
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
