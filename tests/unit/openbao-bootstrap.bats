#!/usr/bin/env bats
# infrastructure/openbao/bootstrap.sh, the runner of the Job
# openbao-bootstrap, as a process against a stub kubectl and stub upstream
# scripts. The stub kubectl is a file first in PATH: the runner is a child
# process, which does not see the kubectl function of helpers.bash.

setup() {
	load helpers
	RUNNER=$SANDBOX_ROOT/infrastructure/openbao/bootstrap.sh
	STUB=$BATS_TEST_TMPDIR/stub
	mkdir -p -- "$STUB/bin" "$STUB/scripts"
	export STUB_LOG=$STUB/kubectl.log STUB_RAN=$STUB/ran
	export STUB_STATUS='{"initialized":false,"sealed":true}' STUB_STATUS_EXIT=2
	export STUB_INIT_OUTPUT='{"root_token":"t"}'
	unset STUB_EXEC_ERROR STUB_SECRET_ERROR STUB_ANNOTATE_ERROR

	# The three calls of the runner: bao status in openbao-0, the Secret
	# openbao-init-keys, and the annotation of the ClusterSecretStore.
	cat >"$STUB/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in
*" exec "*" bao status "*)
	if [ -n "${STUB_EXEC_ERROR:-}" ]; then
		printf '%s\n' "$STUB_EXEC_ERROR" >&2
		exit 1
	fi
	printf '%s\n' "$STUB_STATUS"
	exit "$STUB_STATUS_EXIT"
	;;
*" get secret openbao-init-keys "*)
	if [ -n "${STUB_SECRET_ERROR:-}" ]; then
		printf '%s\n' "$STUB_SECRET_ERROR" >&2
		exit 1
	fi
	printf '%s' "$STUB_INIT_OUTPUT" | base64 | tr -d '\n'
	;;
" annotate "*)
	if [ -n "${STUB_ANNOTATE_ERROR:-}" ]; then
		printf '%s\n' "$STUB_ANNOTATE_ERROR" >&2
		exit 1
	fi
	echo "clustersecretstore.external-secrets.io/openbao-cluster-store annotated"
	;;
*)
	echo "stub kubectl: unexpected call: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$STUB/bin/kubectl"
	for script in init-unseal setup-secret-engines setup-auth setup-policies write-bootstrap-secrets; do
		stub_script "$script" 0
	done
}

# stub_script <name> <status>: writes the upstream script <name>.sh, which
# appends its name and the settings it sees to $STUB_RAN and exits with the
# status.
stub_script() {
	cat >"$STUB/scripts/$1.sh" <<EOF
printf '%s BAO_TOKEN=%s OPENBAO_PODS=%s OPENBAO_NAMESPACE=%s\n' $1 "\${BAO_TOKEN-}" "\${OPENBAO_PODS-}" "\${OPENBAO_NAMESPACE-}" >>"\$STUB_RAN"
exit $2
EOF
}

# run_runner [<name>=<value>...]: runs the runner with the stubs, without a
# BAO_TOKEN of the caller, and with the settings given.
run_runner() {
	run env -u BAO_TOKEN PATH="$STUB/bin:$PATH" SCRIPTS_DIR="$STUB/scripts" OPENBAO_BOOTSTRAP_INTERVAL=0 "$@" \
		bash "$RUNNER"
}

# ran: prints the names of the upstream scripts that ran, in order.
ran() {
	if [ -f "$STUB_RAN" ]; then
		cut -d ' ' -f 1 "$STUB_RAN"
	fi
}

@test "a sealed, uninitialised OpenBao is initialised, set up with the root token, and the store is annotated once" {
	run_runner
	[ "$status" -eq 0 ]
	[ "$(cat "$STUB_RAN")" = "init-unseal BAO_TOKEN= OPENBAO_PODS=openbao-0 OPENBAO_NAMESPACE=shared-services
setup-secret-engines BAO_TOKEN=t OPENBAO_PODS=openbao-0 OPENBAO_NAMESPACE=shared-services
setup-auth BAO_TOKEN=t OPENBAO_PODS=openbao-0 OPENBAO_NAMESPACE=shared-services
setup-policies BAO_TOKEN=t OPENBAO_PODS=openbao-0 OPENBAO_NAMESPACE=shared-services
write-bootstrap-secrets BAO_TOKEN=t OPENBAO_PODS=openbao-0 OPENBAO_NAMESPACE=shared-services" ]
	[ "$(grep -cE '^annotate clustersecretstore\.external-secrets\.io/openbao-cluster-store sandbox\.c5c3\.io/bootstrapped=[0-9]+ --overwrite$' "$STUB_LOG")" = 1 ]
	[[ $output != *"cannot annotate"* ]]
	[ "${lines[-1]}" = "openbao-bootstrap: done" ]
	# The token is one letter, so the check looks for it as a word.
	[ "$(grep -cwF t <<<"$output")" = 0 ]
	[[ $output != *root_token* ]]
}

@test "the runner stops when openbao-0 does not answer bao status within the timeout, and runs no script" {
	export STUB_EXEC_ERROR='Error from server (NotFound): pods "openbao-0" not found'
	run_runner OPENBAO_BOOTSTRAP_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'openbao-bootstrap: error: openbao-0 did not answer bao status within 1 s: Error from server (NotFound): pods "openbao-0" not found' ]
	[ "$(ran)" = "" ]

	# An exec that fails without a word on stderr.
	unset STUB_EXEC_ERROR
	export STUB_STATUS='' STUB_STATUS_EXIT=1
	run_runner OPENBAO_BOOTSTRAP_TIMEOUT=1
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = 'openbao-bootstrap: error: openbao-0 did not answer bao status within 1 s: kubectl printed no error' ]
	[ "$(ran)" = "" ]
}

@test "a failed init-unseal.sh stops the runner before any setup script" {
	stub_script init-unseal 1
	run_runner
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "openbao-bootstrap: error: init-unseal.sh failed with exit status 1" ]
	[ "$(ran)" = init-unseal ]
}

@test "an empty init output, one without root_token and a missing Secret stop the runner before any setup script" {
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
		[ "${lines[-1]}" = "openbao-bootstrap: error: Secret shared-services/openbao-init-keys holds no root_token" ]
		[ "$(ran)" = init-unseal ]
	done
}

@test "a failed setup script stops the runner before the next one and before the annotation" {
	stub_script setup-auth 3
	run_runner
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "openbao-bootstrap: error: setup-auth.sh failed with exit status 3" ]
	[ "$(ran | paste -sd ' ')" = "init-unseal setup-secret-engines setup-auth" ]
	[ "$(grep -c '^annotate ' "$STUB_LOG")" = 0 ]
}

@test "a failed annotation is reported and the runner still succeeds" {
	export STUB_ANNOTATE_ERROR='Error from server (NotFound): clustersecretstores.external-secrets.io "openbao-cluster-store" not found'
	run_runner
	[ "$status" -eq 0 ]
	[ "${lines[-2]}" = "openbao-bootstrap: cannot annotate ClusterSecretStore openbao-cluster-store, External Secrets validates it at its next retry: $STUB_ANNOTATE_ERROR" ]
	[ "${lines[-1]}" = "openbao-bootstrap: done" ]
}
