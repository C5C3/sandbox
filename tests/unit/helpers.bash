# shellcheck shell=bash
# Shared setup of the unit tests. They need bash, yq, jq and bats, and call
# neither Docker nor kind.

# shellcheck source=../../scripts/lib/common.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/preflight.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/preflight.sh"
# shellcheck source=../../scripts/lib/profile.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/profile.sh"
# shellcheck source=../../scripts/lib/hub.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/hub.sh"

# Every test starts without a configuration, a profile and a revision,
# whatever the caller exported.
unset SANDBOX_CONFIG SANDBOX_SUBNET SANDBOX_GATEWAY_ADDRESS \
	SANDBOX_REGISTRY_IMAGE SANDBOX_HYPERVISOR_NODES SANDBOX_FLUX_OPERATOR_VERSION \
	SANDBOX_PROFILE SANDBOX_PROFILE_FILE SANDBOX_PROFILE_DIR SANDBOX_PROFILE_CLUSTERS \
	SANDBOX_REVISION SANDBOX_STAGE_TIMEOUT SANDBOX_SOURCE_TIMEOUT

# A unit test that reaches Docker, kind, a cluster, Helm or Flux fails instead
# of touching the host.
docker() {
	echo "unit test called docker $*" >&2
	return 1
}
kind() {
	echo "unit test called kind $*" >&2
	return 1
}
kubectl() {
	echo "unit test called kubectl $*" >&2
	return 1
}
helm() {
	echo "unit test called helm $*" >&2
	return 1
}
flux() {
	echo "unit test called flux $*" >&2
	return 1
}

# config_with <yq expression>: writes config.yaml, changed by the expression,
# into the test's directory and points SANDBOX_CONFIG at the copy.
config_with() {
	export SANDBOX_CONFIG=$BATS_TEST_TMPDIR/config.yaml
	yq "$1" "$SANDBOX_ROOT/config.yaml" >"$SANDBOX_CONFIG"
}

# profile_with <yaml>: writes the text as the profile case into the test's
# directory and selects it.
profile_with() {
	mkdir -p -- "$BATS_TEST_TMPDIR/profiles"
	printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/profiles/case.yaml"
	export SANDBOX_PROFILE_DIR=$BATS_TEST_TMPDIR/profiles SANDBOX_PROFILE=case
}

# tool_version <name>: prints a version line of the tool as probe_tool does.
tool_version() {
	case $1 in
	docker) echo "Docker version 27.3.1, build ce12230" ;;
	kind) echo "kind v0.33.0 go1.26.7 linux/amd64" ;;
	kubectl) echo "Client Version: v1.37.0" ;;
	helm) echo "v3.22.0+g144ca65" ;;
	flux) echo "flux version 2.9.5" ;;
	yq) echo "yq (https://github.com/mikefarah/yq/) version v4.44.3" ;;
	jq) echo "jq-1.7.1" ;;
	openstack) echo "openstack 7.1.0" ;;
	*) return 1 ;;
	esac
}

# healthy_host: replaces every probe of the host check so that every check
# passes, with the committed config.yaml. A test then replaces the one probe
# it is about.
healthy_host() {
	probe_os() { echo "Linux x86_64"; }
	probe_cgroup_fstype() { echo cgroup2fs; }
	probe_docker_security() { echo '["name=seccomp,profile=builtin","name=cgroupns"]'; }
	probe_inotify_instances() { echo 512; }
	probe_tool() { tool_version "$1"; }
	probe_openstack_plugin() { return 0; }
	probe_module() { return 0; }
	probe_kvm() { return 0; }
	probe_resolve() { echo 172.30.255.10; }
	export SANDBOX_CONFIG=$SANDBOX_ROOT/config.yaml
}

# check_ids: prints the ids of the check lines in $output, comma-separated.
check_ids() {
	local line ids=()
	for line in "${lines[@]}"; do
		if [[ $line =~ ^(ok|warn|FAIL)\ ([^:]+): ]]; then
			ids+=("${BASH_REMATCH[2]}")
		fi
	done
	local IFS=,
	printf '%s\n' "${ids[*]}"
}
