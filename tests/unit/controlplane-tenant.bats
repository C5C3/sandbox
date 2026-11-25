#!/usr/bin/env bats
# controlplane/tenant.sh, the runner of the Job controlplane-database-tenant,
# as a process against a stub kubectl and a stub setup-database-tenant.sh. The
# stub kubectl is a file first in PATH: the runner is a child process, which
# does not see the kubectl function of helpers.bash.

setup() {
	load helpers
	RUNNER=$SANDBOX_ROOT/controlplane/tenant.sh
	STUB=$BATS_TEST_TMPDIR/stub
	mkdir -p -- "$STUB/bin" "$STUB/scripts"
	export STUB_LOG=$STUB/kubectl.log STUB_RAN=$STUB/ran
	export STUB_READY=True STUB_MARIADB_EXIT=0
	export STUB_INIT_OUTPUT='{"root_token":"t"}'
	unset STUB_MARIADB_ERROR STUB_SECRET_ERROR

	# The two calls of the runner: the Ready condition of the MariaDB
	# openstack-db and the Secret openbao-init-keys. The MariaDB answers one
	# word of STUB_READY per call, and its last word once the list is used up.
	cat >"$STUB/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in
*" -n openstack get mariadbs.k8s.mariadb.com openstack-db "*)
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

# run_runner [<name>=<value>...]: runs the runner with the stubs, without a
# BAO_TOKEN of the caller, and with the settings given. The timeout of 10 s
# stops a runner that misses the stub instead of waiting 1500 s; a setting
# given overrides it.
run_runner() {
	run env -u BAO_TOKEN PATH="$STUB/bin:$PATH" SCRIPTS_DIR="$STUB/scripts" TENANT_INTERVAL=0 TENANT_TIMEOUT=10 "$@" \
		bash "$RUNNER"
}

# ran: prints the lines setup-database-tenant.sh appended, one per run.
ran() {
	if [ -f "$STUB_RAN" ]; then
		cat "$STUB_RAN"
	fi
}

# The two kubectl calls of one try each, as the stub logs them.
mariadb_call='-n openstack get mariadbs.k8s.mariadb.com openstack-db -o jsonpath={.status.conditions[?(@.type=="Ready")].status}'
secret_call='-n shared-services get secret openbao-init-keys -o jsonpath={.data.init-output}'

@test "the tenant of a Ready MariaDB is onboarded once with the root token, also when Ready turns True after two tries" {
	run_runner
	[ "$status" -eq 0 ]
	[ "$(ran)" = "setup-database-tenant.sh <openstack> <controlplane> BAO_TOKEN=t OPENBAO_NAMESPACE=shared-services" ]
	# The stub logs every call, so the log holds no call it did not expect.
	[ "$(cat "$STUB_LOG")" = "$mariadb_call
$secret_call" ]
	[ "${lines[-1]}" = "controlplane-database-tenant: done" ]
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
