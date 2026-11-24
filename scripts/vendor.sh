#!/usr/bin/env bash
# Usage: vendor.sh
#
# Checks out C5C3/cobaltcore at the commit upstream.cobaltcore of the
# configuration into vendor/cobaltcore, with the paths of
# SANDBOX_VENDOR_PATHS only, and discards every local change there. It reads
# no profile and needs no Docker. SANDBOX_UPSTREAM_URL names another
# repository than https://github.com/C5C3/cobaltcore.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/vendor.sh
. "$SANDBOX_ROOT/scripts/lib/vendor.sh"

command -v git >/dev/null || die 'git not found in PATH, see "Host requirements" in the README'
config_load
vendor_fetch "$SANDBOX_UPSTREAM_COMMIT"
files=$(find "$SANDBOX_VENDOR_DIR" -path "$SANDBOX_VENDOR_DIR/.git" -prune -o -type f -print | wc -l)
log "vendor/cobaltcore is at $SANDBOX_UPSTREAM_COMMIT, $files files"
