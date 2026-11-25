#!/usr/bin/env bash
# Usage: verify.sh
#
# Checks the services of the ControlPlane openstack/controlplane on
# sandbox-management with the OpenStack CLI and the variables that make env
# prints. Each key of spec.services adds the checks of its service:
#
#   keystone   keystone-token     openstack token issue prints a token id
#              keystone-catalog   the catalog holds a public identity endpoint
#                                 at OS_AUTH_URL
#
# A key without checks adds none. It prints one line per check,
# ok <id>: <detail> or FAIL <id>: <first line of the error>, then
# verify: <passed> of <total> checks passed, and exits 1 when a check failed.
# Without a ControlPlane it runs no check and exits 0. It reads the hub only,
# no configuration and no profile, and no call passes --insecure: the CLI
# trusts the CA of the sandbox through OS_CACERT.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/access.sh
. "$SANDBOX_ROOT/scripts/lib/access.sh"

errfile=$(mktemp)
trap 'rm -f -- "$errfile"' EXIT

passed=0
total=0

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

	if ! out=$(openstack catalog list -f json 2>"$errfile"); then
		report FAIL keystone-catalog "$(os_error "$out")"
	elif jq -e --arg url "$OS_AUTH_URL" 'any(.[]?; .Type == "identity"
		and any(.Endpoints[]?; .interface == "public" and .url == $url))' >/dev/null 2>&1 <<<"$out"; then
		report ok keystone-catalog "the catalog holds the public identity endpoint $OS_AUTH_URL"
	else
		report FAIL keystone-catalog "no public identity endpoint $OS_AUTH_URL in the catalog"
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

# The checks of the service <key> are the function check_<key>; a later
# service adds its own function.
for service in $(jq -r '.spec.services // {} | keys_unsorted[]' <<<"$controlplane"); do
	if declare -F "check_$service" >/dev/null; then
		"check_$service"
	fi
done

echo "verify: $passed of $total checks passed"
if [ "$passed" -ne "$total" ]; then
	exit 1
fi
