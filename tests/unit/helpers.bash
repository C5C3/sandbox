# shellcheck shell=bash
# Shared setup of the unit tests. They need bash, yq, jq, git and bats, and
# call neither Docker nor kind. git runs only on repositories in the test's
# directory.

# shellcheck source=../../scripts/lib/common.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/preflight.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/preflight.sh"
# shellcheck source=../../scripts/lib/profile.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/profile.sh"
# shellcheck source=../../scripts/lib/hub.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/hub.sh"
# shellcheck source=../../scripts/lib/vendor.sh
. "$BATS_TEST_DIRNAME/../../scripts/lib/vendor.sh"

# Every test starts without a configuration, a profile, a revision and an
# upstream repository, whatever the caller exported, so no test reaches
# GitHub. git reads no configuration of the user.
unset SANDBOX_CONFIG SANDBOX_SUBNET SANDBOX_GATEWAY_ADDRESS \
	SANDBOX_ADDRESS_POOL SANDBOX_DNS_ADDRESS SANDBOX_RESOLVER_FALLBACK \
	SANDBOX_REGISTRY_IMAGE SANDBOX_HYPERVISOR_NODES SANDBOX_FLUX_OPERATOR_VERSION \
	SANDBOX_PROFILE SANDBOX_PROFILE_FILE SANDBOX_PROFILE_DIR SANDBOX_PROFILE_CLUSTERS \
	SANDBOX_REVISION SANDBOX_STAGE_TIMEOUT SANDBOX_SOURCE_TIMEOUT \
	SANDBOX_UPSTREAM_COMMIT SANDBOX_UPSTREAM_RECORD SANDBOX_UPSTREAM_URL \
	SANDBOX_VALIDATE_CACHE SANDBOX_CRD_SOURCES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# test_git <argument>...: runs git with an identity and the branch main.
test_git() {
	git -c user.name=test -c user.email=test@example.org -c init.defaultBranch=main "$@"
}

# upstream_repo: creates the repository upstream in the test's directory with
# deploy/, operators/x/, docs/ and a .gitignore of *.out in the commit
# UPSTREAM_FIRST and a change of deploy/README.md in UPSTREAM_SECOND on main,
# and points SANDBOX_UPSTREAM_URL at it. It serves fetches with a filter, as
# GitHub does, so a checkout lacks the content of the files outside its
# paths.
upstream_repo() {
	local repo=$BATS_TEST_TMPDIR/upstream
	test_git init --quiet -- "$repo"
	git -C "$repo" config uploadpack.allowFilter true
	mkdir -p -- "$repo/deploy/bases/demo" "$repo/operators/x/config/crd/bases" "$repo/docs"
	echo '*.out' >"$repo/.gitignore"
	echo first >"$repo/deploy/README.md"
	echo 'resources: []' >"$repo/deploy/bases/demo/kustomization.yaml"
	echo 'kind: CustomResourceDefinition' >"$repo/operators/x/config/crd/bases/x.yaml"
	echo operator >"$repo/operators/x/README.md"
	echo docs >"$repo/docs/index.md"
	test_git -C "$repo" add -A
	test_git -C "$repo" commit --quiet -m first
	UPSTREAM_FIRST=$(git -C "$repo" rev-parse HEAD)
	echo second >"$repo/deploy/README.md"
	test_git -C "$repo" commit --quiet -am second
	UPSTREAM_SECOND=$(git -C "$repo" rev-parse HEAD)
	export UPSTREAM_FIRST UPSTREAM_SECOND SANDBOX_UPSTREAM_URL=file://$repo
}

# vendor_checkout: makes vendor/cobaltcore in the test's directory, the
# checkout a copy of scripts/ there uses, a checkout of UPSTREAM_FIRST.
vendor_checkout() {
	if [ -z "${UPSTREAM_FIRST:-}" ]; then
		upstream_repo
	fi
	SANDBOX_VENDOR_DIR=$BATS_TEST_TMPDIR/vendor/cobaltcore
	vendor_fetch "$UPSTREAM_FIRST" >/dev/null
}

# tool_version <name>: prints a version line of the tool as probe_tool does.
tool_version() {
	case $1 in
	docker) echo "Docker version 27.3.1, build ce12230" ;;
	kind) echo "kind v0.33.0 go1.26.7 linux/amd64" ;;
	kubectl) echo "Client Version: v1.37.0" ;;
	helm) echo "v3.22.0+g144ca65" ;;
	flux) echo "flux version 2.9.5" ;;
	git) echo "git version 2.43.0" ;;
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
