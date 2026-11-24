# shellcheck shell=bash
# Shared setup of the unit tests. They need bash, yq, jq and bats, and call
# neither Docker nor kind.

# shellcheck source=../../scripts/lib/common.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/common.sh"

# Every test starts without a configuration, whatever the caller exported.
unset SANDBOX_CONFIG SANDBOX_SUBNET SANDBOX_GATEWAY_ADDRESS \
	SANDBOX_REGISTRY_IMAGE SANDBOX_HYPERVISOR_NODES

# A unit test that reaches Docker or kind fails instead of touching the host.
docker() {
	echo "unit test called docker $*" >&2
	return 1
}
kind() {
	echo "unit test called kind $*" >&2
	return 1
}

# config_with <yq expression>: writes config.yaml, changed by the expression,
# into the test's directory and points SANDBOX_CONFIG at the copy.
config_with() {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/config.yaml
	yq "$1" "$SANDBOX_ROOT/config.yaml" >"$SANDBOX_CONFIG"
}
