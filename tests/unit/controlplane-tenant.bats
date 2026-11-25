#!/usr/bin/env bats
# controlplane/tenant.sh, the runner of the Job controlplane-database-tenant,
# as a process against a stub kubectl and a stub setup-database-tenant.sh, with
# and without the TENANT_SERVICE_ variables of the service components. The
# stub kubectl is a file first in PATH: the runner is a child process, which
# does not see the kubectl function of helpers.bash.

bats_require_minimum_version 1.5.0

setup() {
	load helpers
	RUNNER=$SANDBOX_ROOT/controlplane/tenant.sh
	STUB=$BATS_TEST_TMPDIR/stub
	mkdir -p -- "$STUB/bin" "$STUB/scripts"
	export STUB_LOG=$STUB/kubectl.log STUB_RAN=$STUB/ran
	export STUB_READY=True STUB_MARIADB_EXIT=0 STUB_CONTROLPLANE_EXIT=0
	export STUB_INIT_OUTPUT='{"root_token":"t"}'
	unset STUB_MARIADB_ERROR STUB_MARIADB_DELAY STUB_SECRET_ERROR STUB_CONTROLPLANE_ERROR STUB_DECLARE_AT
	# The runner waits for the service of every TENANT_SERVICE_ variable, so
	# none of the caller's reaches it.
	unset "${!TENANT_SERVICE_@}"

	# The three calls of the runner: the Ready condition of the MariaDB
	# openstack-db, a block under spec.services of the ControlPlane
	# controlplane and the Secret openbao-init-keys. The MariaDB answers one
	# word of STUB_READY per call, and its last word once the list is used up,
	# after STUB_MARIADB_DELAY seconds if set. It waits with /bin/sleep, which
	# a stub sleep in $STUB/bin does not replace. The ControlPlane answers an
	# empty block before its call number STUB_DECLARE_AT, counted over all
	# services, and a block from then on; without STUB_DECLARE_AT it never
	# declares one.
	cat >"$STUB/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in
*" -n openstack get mariadbs.k8s.mariadb.com openstack-db "*)
	if [ -n "${STUB_MARIADB_DELAY:-}" ]; then
		/bin/sleep "$STUB_MARIADB_DELAY"
	fi
	if [ -n "${STUB_MARIADB_ERROR:-}" ]; then
		printf '%s\n' "$STUB_MARIADB_ERROR" >&2
	fi
	if [ "$STUB_MARIADB_EXIT" != 0 ]; then
		exit "$STUB_MARIADB_EXIT"
	fi
	read -r -a answers <<<"$STUB_READY"
	calls=$(grep -c ' get mariadbs\.k8s\.mariadb\.com ' "$STUB_LOG")
	if [ "${#answers[@]}" -gt 0 ]; then
		if [ "$calls" -gt "${#answers[@]}" ]; then
			calls=${#answers[@]}
		fi
		printf '%s' "${answers[calls - 1]}"
	fi
	;;
*" -n openstack get controlplanes.c5c3.io controlplane "*)
	if [ -n "${STUB_CONTROLPLANE_ERROR:-}" ]; then
		printf '%s\n' "$STUB_CONTROLPLANE_ERROR" >&2
	fi
	if [ "$STUB_CONTROLPLANE_EXIT" != 0 ]; then
		exit "$STUB_CONTROLPLANE_EXIT"
	fi
	calls=$(grep -c ' get controlplanes\.c5c3\.io ' "$STUB_LOG")
	if [ -n "${STUB_DECLARE_AT:-}" ] && [ "$calls" -ge "$STUB_DECLARE_AT" ]; then
		printf '%s' '{"gateway":{"parentRef":{"name":"openstack-gw"}}}'
	fi
	;;
*" -n shared-services get secret openbao-init-keys "*)
	if [ -n "${STUB_SECRET_ERROR:-}" ]; then
		printf '%s\n' "$STUB_SECRET_ERROR" >&2
		exit 1
	fi
	printf '%s' "$STUB_INIT_OUTPUT" | base64 | tr -d '\n'
	;;
*)
	echo "stub kubectl: unexpected call: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$STUB/bin/kubectl"
	stub_script 0
}

# stub_script <status>: writes the upstream script setup-database-tenant.sh,
# which appends its arguments, each in angle brackets, and the settings it
# sees to $STUB_RAN and exits with the status.
stub_script() {
	cat >"$STUB/scripts/setup-database-tenant.sh" <<EOF
printf 'setup-database-tenant.sh' >>"\$STUB_RAN"
printf ' <%s>' "\$@" >>"\$STUB_RAN"
printf ' BAO_TOKEN=%s OPENBAO_NAMESPACE=%s\n' "\${BAO_TOKEN-}" "\${OPENBAO_NAMESPACE-}" >>"\$STUB_RAN"
exit $1
EOF
}

# run_runner [--separate-stderr] [<name>=<value>...]: runs the runner with the
# stubs, without a BAO_TOKEN of the caller, and with the settings given. The
# timeout of 10 s stops a runner that misses the stub instead of waiting
# 1500 s; a setting given overrides it. With --separate-stderr, output and
# lines hold what the runner printed on stdout, and stderr what it printed
# there.
run_runner() {
	local flags=()
	if [ "${1-}" = --separate-stderr ]; then
		flags=("$1")
		shift
	fi
	run "${flags[@]}" env -u BAO_TOKEN PATH="$STUB/bin:$PATH" SCRIPTS_DIR="$STUB/scripts" TENANT_INTERVAL=0 TENANT_TIMEOUT=10 "$@" \
		bash "$RUNNER"
}

# ran: prints the lines setup-database-tenant.sh appended, one per run.
ran() {
	if [ -f "$STUB_RAN" ]; then
		cat "$STUB_RAN"
	fi
}

# The kubectl calls of one try each, as the stub logs them.
mariadb_call='-n openstack get mariadbs.k8s.mariadb.com openstack-db -o jsonpath={.status.conditions[?(@.type=="Ready")].status}'
glance_call='-n openstack get controlplanes.c5c3.io controlplane -o jsonpath={.spec.services.glance}'
placement_call='-n openstack get controlplanes.c5c3.io controlplane -o jsonpath={.spec.services.placement}'
secret_call='-n shared-services get secret openbao-init-keys -o jsonpath={.data.init-output}'

@test "the tenant of a Ready MariaDB is onboarded once with the root token, also when Ready turns True after two tries, and without a TENANT_SERVICE_ variable no ControlPlane is read" {
	run_runner
	[ "$status" -eq 0 ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
	# The stub logs every call, so the log holds no call it did not expect,
	# and no read of the ControlPlane.
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$secret_call" ]
	[ "$output" = "controlplane-database-tenant: waiting for MariaDB openstack/openstack-db to be Ready
controlplane-database-tenant: running setup-database-tenant.sh openstack controlplane
controlplane-database-tenant: done" ]
	# The token is one letter, so the check looks for it as a word.
	[ "$(grep -cwF t <<<"$output")" = 0 ]
	[[ $output != *root_token* ]]

	# A MariaDB that answers False twice, then True.
	rm -f -- "$STUB_LOG" "$STUB_RAN"
	export STUB_READY='False False True'
	run_runner
	[ "$status" -eq 0 ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$mariadb_call
$mariadb_call
$secret_call" ]
	[ "${lines[-1]}" = "controlplane-database-tenant: done" ]
}

@test "the runner stops when kubectl cannot read the MariaDB within the timeout, and runs no script" {
	export STUB_MARIADB_ERROR='Error from server (NotFound): mariadbs.k8s.mariadb.com "openstack-db" not found' STUB_MARIADB_EXIT=1
	run_runner TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'controlplane-database-tenant: error: MariaDB openstack/openstack-db is not Ready within 1 s: Error from server (NotFound): mariadbs.k8s.mariadb.com "openstack-db" not found' ]
	[ "$(ran)" = "" ]

	# The last line of a longer error.
	export STUB_MARIADB_ERROR='E1125 memcache.go:265] "Unhandled Error" err="couldn'"'"'t get current server API group list"
Error from server (NotFound): mariadbs.k8s.mariadb.com "openstack-db" not found'
	run_runner TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'controlplane-database-tenant: error: MariaDB openstack/openstack-db is not Ready within 1 s: Error from server (NotFound): mariadbs.k8s.mariadb.com "openstack-db" not found' ]
	[ "$(ran)" = "" ]

	# A kubectl that fails without a word on stderr.
	unset STUB_MARIADB_ERROR
	run_runner TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'controlplane-database-tenant: error: MariaDB openstack/openstack-db is not Ready within 1 s: kubectl printed no error' ]
	[ "$(ran)" = "" ]
}

@test "the runner stops when the Ready condition of the MariaDB stays False or empty within the timeout, and runs no script" {
	export STUB_READY=False
	run_runner TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "controlplane-database-tenant: error: MariaDB openstack/openstack-db is not Ready within 1 s: its Ready condition is 'False'" ]
	[ "$(ran)" = "" ]

	# A MariaDB without a Ready condition.
	export STUB_READY=''
	run_runner TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "controlplane-database-tenant: error: MariaDB openstack/openstack-db is not Ready within 1 s: its Ready condition is ''" ]
	[ "$(ran)" = "" ]
}

@test "the runner waits until the ControlPlane declares the service of TENANT_SERVICE_GLANCE, pausing TENANT_INTERVAL seconds between two tries, says so on stdout and then onboards the tenant once" {
	export STUB_DECLARE_AT=3 STUB_SLEPT=$STUB/slept
	# A stub sleep, first in PATH, which appends its argument to $STUB_SLEPT
	# and returns at once.
	cat >"$STUB/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_SLEPT"
EOF
	chmod +x "$STUB/bin/sleep"
	run_runner --separate-stderr TENANT_SERVICE_GLANCE=glance TENANT_INTERVAL=7
	[ "$status" -eq 0 ]
	# Two pauses, before the second and the third read of the ControlPlane.
	[ "$(cat "$STUB_SLEPT")" = "7
7" ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$glance_call
$glance_call
$glance_call
$secret_call" ]
	[ "$output" = "controlplane-database-tenant: waiting for MariaDB openstack/openstack-db to be Ready
controlplane-database-tenant: the ControlPlane declares glance
controlplane-database-tenant: running setup-database-tenant.sh openstack controlplane
controlplane-database-tenant: done" ]
	[ "$stderr" = "" ]

	# Two services, waited for in the order of their variable names and
	# named in that order.
	rm -f -- "$STUB_LOG" "$STUB_RAN"
	run_runner TENANT_SERVICE_PLACEMENT=placement TENANT_SERVICE_GLANCE=glance
	[ "$status" -eq 0 ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$glance_call
$glance_call
$glance_call
$placement_call
$secret_call" ]
	[ "${lines[1]}" = "controlplane-database-tenant: the ControlPlane declares glance placement" ]
}

@test "the runner stops when the ControlPlane does not declare the service within the timeout, and runs no script" {
	run_runner TENANT_SERVICE_GLANCE=glance TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "controlplane-database-tenant: error: ControlPlane openstack/controlplane does not declare the service glance within 1 s: spec.services.glance is empty" ]
	[[ $output != *declares* ]]
	[ "$(ran)" = "" ]
	# The MariaDB once, then the block of glance until the timeout, and no
	# Secret.
	[ "$(head -n 1 "$STUB_LOG")" = "$mariadb_call" ]
	[ "$(sed 1d "$STUB_LOG" | sort -u)" = "$glance_call" ]
}

@test "the wait for the services shares the deadline of the wait for the MariaDB, so a MariaDB Ready after the timeout leaves one read of the ControlPlane" {
	# The MariaDB answers True after 2 s, past the deadline of 1 s. A runner
	# that started a new deadline for the services would read the block of
	# glance for another second, TENANT_INTERVAL being 0.
	export STUB_MARIADB_DELAY=2
	run_runner TENANT_SERVICE_GLANCE=glance TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "controlplane-database-tenant: error: ControlPlane openstack/controlplane does not declare the service glance within 1 s: spec.services.glance is empty" ]
	[ "$(ran)" = "" ]
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$glance_call" ]
}

@test "the runner stops when kubectl cannot read the ControlPlane within the timeout, with the last line of its error, and runs no script" {
	export STUB_CONTROLPLANE_ERROR='Error from server (NotFound): controlplanes.c5c3.io "controlplane" not found' STUB_CONTROLPLANE_EXIT=1
	run_runner TENANT_SERVICE_GLANCE=glance TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'controlplane-database-tenant: error: ControlPlane openstack/controlplane does not declare the service glance within 1 s: Error from server (NotFound): controlplanes.c5c3.io "controlplane" not found' ]
	[ "$(ran)" = "" ]
	[ "$(sed 1d "$STUB_LOG" | sort -u)" = "$glance_call" ]

	# The last line of a longer error.
	export STUB_CONTROLPLANE_ERROR='E1125 memcache.go:265] "Unhandled Error" err="couldn'"'"'t get current server API group list"
Error from server (Forbidden): controlplanes.c5c3.io "controlplane" is forbidden'
	run_runner TENANT_SERVICE_GLANCE=glance TENANT_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'controlplane-database-tenant: error: ControlPlane openstack/controlplane does not declare the service glance within 1 s: Error from server (Forbidden): controlplanes.c5c3.io "controlplane" is forbidden' ]
	[ "$(ran)" = "" ]
}

@test "a TENANT_SERVICE_ value that is not a service name stops the runner at once, before any read of the ControlPlane" {
	local value
	# TENANT_SERVICE_GLANCE is valid and sorts before TENANT_SERVICE_X. The
	# runner reads no block of glance, because it checks every value before
	# its first read.
	for value in '' Glance nova-api; do
		rm -f -- "$STUB_LOG" "$STUB_RAN"
		run_runner TENANT_SERVICE_GLANCE=glance TENANT_SERVICE_X="$value"
		echo "'$value': $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "controlplane-database-tenant: error: TENANT_SERVICE_X names '$value', which is not a service name" ]
		[ "$(cat "$STUB_LOG")" = "$mariadb_call" ]
		[ "$(ran)" = "" ]
	done
}

@test "an empty init output, one without root_token and a missing Secret stop the runner before the script" {
	local case
	for case in empty no-token missing; do
		rm -f -- "$STUB_RAN"
		case $case in
		empty) export STUB_INIT_OUTPUT='' ;;
		no-token) export STUB_INIT_OUTPUT='{"unseal_keys_b64":["k"]}' ;;
		missing) export STUB_SECRET_ERROR='Error from server (NotFound): secrets "openbao-init-keys" not found' ;;
		esac
		run_runner
		echo "$case: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "controlplane-database-tenant: error: Secret shared-services/openbao-init-keys holds no root_token" ]
		[ "$(ran)" = "" ]
	done
}

@test "a failed setup-database-tenant.sh stops the runner with its exit status" {
	stub_script 3
	run_runner
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "controlplane-database-tenant: error: setup-database-tenant.sh failed with exit status 3" ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
}
