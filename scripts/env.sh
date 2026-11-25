#!/usr/bin/env bash
# Usage: env.sh
#
# Prints the variables of the OpenStack CLI for the admin of the ControlPlane
# openstack/controlplane on sandbox-management as seven lines
# export <NAME>=<value>, each value quoted for bash, so that
#
#   eval "$(make --no-print-directory env)"
#
# loads them: OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME,
# OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME and OS_CACERT. It writes the CA
# of the sandbox to .sandbox/sandbox-ca.pem, the file OS_CACERT names. It
# reads the hub only, no configuration and no profile. It prints all seven
# lines or none, and nothing else on stdout; its messages go to stderr, and
# none holds the admin password.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/access.sh
. "$SANDBOX_ROOT/scripts/lib/access.sh"

access_load

args=()
for name in OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_CACERT; do
	args+=("$name" "${!name}")
done
# One printf writes all seven lines.
printf 'export %s=%q\n' "${args[@]}"
