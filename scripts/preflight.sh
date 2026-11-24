#!/usr/bin/env bash
# Checks the host requirements of the given cluster roles, or of all three
# when none is given. Exits 1 when a check failed.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$SANDBOX_ROOT/scripts/lib/preflight.sh"

require_roles "$@"
if [ "$#" -eq 0 ]; then
	set -- "${SANDBOX_ROLES[@]}"
fi
preflight_run "$@"
