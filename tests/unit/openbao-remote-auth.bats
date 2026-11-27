#!/usr/bin/env bats
# infrastructure/openbao-remote-auth/remote-auth.sh, the runner of the Job
# openbao-remote-auth, as a process against a stub kubectl and upstream's
# common.sh of the checkout of make vendor. The stub kubectl is a file first
# in PATH: the runner is a child process, which does not see the kubectl
# function of helpers.bash.

setup() {
	load helpers
	RUNNER=$SANDBOX_ROOT/infrastructure/openbao-remote-auth/remote-auth.sh
	HCL=$SANDBOX_ROOT/infrastructure/openbao-remote-auth/read-ceph-client-cinder.hcl
	STUB=$BATS_TEST_TMPDIR/stub
	mkdir -p -- "$STUB/bin" "$STUB/stdin"
	export STUB_LOG=$STUB/bao.log STUB_TOKENS=$STUB/tokens STUB_STDIN=$STUB/stdin
	export STUB_INIT_OUTPUT='{"root_token":"s.sandboxroot"}'
	export STUB_MOUNTS='{"kubernetes/management/":{},"kubernetes/storage/":{},"kubernetes/hypervisor/":{},"token/":{}}'
	unset STUB_SECRET_ERROR STUB_FAIL STUB_FAIL_LINE
	STORAGE_PEM=$'-----BEGIN CERTIFICATE-----\nMIIBstorage\n-----END CERTIFICATE-----'
	COMPUTE_PEM=$'-----BEGIN CERTIFICATE-----\nMIIBcompute\n-----END CERTIFICATE-----'
	STORAGE_CA=$(printf '%s\n' "$STORAGE_PEM" | base64 -w 0)
	COMPUTE_CA=$(printf '%s\n' "$COMPUTE_PEM" | base64 -w 0)

	# The Secret openbao-init-keys, and bao in openbao-0. Each bao call goes
	# to bao.log as "bao <arguments>", the token it carries to tokens, and
	# the stdin of an exec -i to stdin/<number of the call>. A call that
	# starts with STUB_FAIL fails with STUB_FAIL_LINE as the last line of
	# its stderr.
	cat >"$STUB/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*" get secret openbao-init-keys "*)
	if [ -n "${STUB_SECRET_ERROR:-}" ]; then
		printf '%s\n' "$STUB_SECRET_ERROR" >&2
		exit 1
	fi
	printf '%s' "$STUB_INIT_OUTPUT" | base64 | tr -d '\n'
	;;
*" exec "*" openbao-0 -- env "*" bao "*)
	args=" $* "
	call="bao ${args#* bao }"
	call=${call% }
	printf '%s\n' "$call" >>"$STUB_LOG"
	token=${args#* BAO_TOKEN=}
	printf '%s\n' "${token%% *}" >>"$STUB_TOKENS"
	if [[ $args == " exec -i "* ]]; then
		cat >"$STUB_STDIN/$(grep -c '' "$STUB_LOG")"
	fi
	if [ -n "${STUB_FAIL:-}" ] && [[ $call == "$STUB_FAIL"* ]]; then
		printf 'Error writing data\n%s\n' "$STUB_FAIL_LINE" >&2
		exit 2
	fi
	case $call in
	"bao auth list -format=json") printf '%s\n' "$STUB_MOUNTS" ;;
	*) echo "Success!" ;;
	esac
	;;
*)
	echo "stub kubectl: unexpected call: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$STUB/bin/kubectl"
}

# run_runner [<name>=<value>...]: runs the runner with the stub, upstream's
# common.sh, without a BAO_TOKEN or an API variable of the caller, and with
# the settings given.
run_runner() {
	run env -u BAO_TOKEN -u STORAGE_API_SERVER -u STORAGE_API_CA_B64 -u COMPUTE_API_SERVER -u COMPUTE_API_CA_B64 \
		PATH="$STUB/bin:$PATH" SCRIPTS_DIR="$SANDBOX_ROOT/vendor/cobaltcore/deploy/bases/shared-openbao/bootstrap" \
		"$@" bash "$RUNNER"
}

# calls: prints the bao calls, one per line, in order.
calls() {
	if [ -f "$STUB_LOG" ]; then
		cat -- "$STUB_LOG"
	fi
}

# all_four: the API servers and CAs of both remote clusters.
all_four() {
	echo STORAGE_API_SERVER=https://sandbox-storage-control-plane:6443 "STORAGE_API_CA_B64=$STORAGE_CA" \
		COMPUTE_API_SERVER=https://sandbox-compute-control-plane:6443 "COMPUTE_API_CA_B64=$COMPUTE_CA"
}

ROLES='bao write auth/kubernetes/storage/role/push-ceph-keys bound_service_account_names=ceph-keys-push bound_service_account_namespaces=rook-ceph token_policies=push-ceph-keys token_ttl=1h token_max_ttl=4h
bao write auth/kubernetes/hypervisor/role/read-ceph-client-cinder bound_service_account_names=ceph-keys-read bound_service_account_namespaces=openstack token_policies=read-ceph-client-cinder token_ttl=1h token_max_ttl=4h'

@test "with both remote clusters the runner writes the policy, lists the mounts, writes both roles and both configs once each, in order, with the root token" {
	# shellcheck disable=SC2046
	run_runner $(all_four)
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(calls)" = "bao policy write read-ceph-client-cinder -
bao auth list -format=json
$ROLES
bao write auth/kubernetes/storage/config kubernetes_host=https://sandbox-storage-control-plane:6443 kubernetes_ca_cert=- disable_local_ca_jwt=true
bao write auth/kubernetes/hypervisor/config kubernetes_host=https://sandbox-compute-control-plane:6443 kubernetes_ca_cert=- disable_local_ca_jwt=true" ]
	# The policy and both CAs go in on stdin, and nothing else does.
	cmp -- "$HCL" "$STUB_STDIN/1"
	[ "$(<"$STUB_STDIN/5")" = "$STORAGE_PEM" ]
	[ "$(<"$STUB_STDIN/6")" = "$COMPUTE_PEM" ]
	[ "$(cd -- "$STUB_STDIN" && ls | paste -sd ' ')" = "1 5 6" ]
	[ "$(sort -u "$STUB_TOKENS")" = s.sandboxroot ]
	[[ $output == *$'\n'"openbao-remote-auth: wrote auth/kubernetes/storage/config for https://sandbox-storage-control-plane:6443"$'\n'* ]]
	[[ $output == *$'\n'"openbao-remote-auth: wrote auth/kubernetes/hypervisor/config for https://sandbox-compute-control-plane:6443"$'\n'* ]]
	[ "${lines[-1]}" = "openbao-remote-auth: done" ]
	[[ $output != *s.sandboxroot* ]]
	[[ $output != *root_token* ]]
}

@test "without an API server the runner writes the policy and both roles, leaves both configs as they are and succeeds" {
	run_runner STORAGE_API_SERVER= STORAGE_API_CA_B64= COMPUTE_API_SERVER= COMPUTE_API_CA_B64=
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(calls)" = "bao policy write read-ceph-client-cinder -
bao auth list -format=json
$ROLES" ]
	[[ $output == *$'\n'"openbao-remote-auth: no API server of sandbox-storage, leaving auth/kubernetes/storage/config as it is"$'\n'* ]]
	[[ $output == *$'\n'"openbao-remote-auth: no API server of sandbox-compute, leaving auth/kubernetes/hypervisor/config as it is"$'\n'* ]]
	[ "${lines[-1]}" = "openbao-remote-auth: done" ]
}

@test "an API server without its CA, or a CA without its server, stops the runner before any config is written" {
	local case
	for case in "STORAGE_API_SERVER=https://sandbox-storage-control-plane:6443" "STORAGE_API_CA_B64=$STORAGE_CA"; do
		rm -f -- "$STUB_LOG"
		run_runner "$case"
		echo "$case: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "openbao-remote-auth: error: STORAGE_API_SERVER and STORAGE_API_CA_B64 are given together or not at all" ]
		! calls | grep -q '/config '
	done
}

@test "a CA that is not base64 of a PEM certificate stops the runner before any config is written" {
	local ca
	for ca in bm90IGEgY2VydA== 'not base64!'; do
		rm -f -- "$STUB_LOG"
		run_runner STORAGE_API_SERVER=https://sandbox-storage-control-plane:6443 "STORAGE_API_CA_B64=$STORAGE_CA" \
			COMPUTE_API_SERVER=https://sandbox-compute-control-plane:6443 "COMPUTE_API_CA_B64=$ca"
		echo "$ca: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "openbao-remote-auth: error: COMPUTE_API_CA_B64 is not base64 of a PEM certificate" ]
		! calls | grep -q '/config '
	done
}

@test "an absent Secret openbao-init-keys, an empty init output and one without root_token stop the runner before any bao call" {
	local case
	for case in missing empty no-token; do
		rm -f -- "$STUB_LOG"
		case $case in
		missing) export STUB_SECRET_ERROR='Error from server (NotFound): secrets "openbao-init-keys" not found' ;;
		empty) export STUB_INIT_OUTPUT='' ;;
		no-token) export STUB_INIT_OUTPUT='{"unseal_keys_b64":["k"]}' ;;
		esac
		# shellcheck disable=SC2046
		run_runner $(all_four)
		echo "$case: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "openbao-remote-auth: error: Secret shared-services/openbao-init-keys holds no root_token" ]
		[ "$(calls)" = "" ]
	done
}

@test "a mount missing from the list is enabled before its role is written, and a listed one is not" {
	export STUB_MOUNTS='{"kubernetes/management/":{},"kubernetes/storage/":{},"token/":{}}'
	# shellcheck disable=SC2046
	run_runner $(all_four)
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(calls | sed -n '2,5p' | cut -d ' ' -f 1-3)" = "bao auth list
bao auth enable
bao write auth/kubernetes/storage/role/push-ceph-keys
bao write auth/kubernetes/hypervisor/role/read-ceph-client-cinder" ]
	[ "$(calls | sed -n 3p)" = "bao auth enable -path=kubernetes/hypervisor kubernetes" ]
	[ "$(calls | grep -c '^bao auth enable ')" = 1 ]
	[[ $output == *$'\n'"openbao-remote-auth: enabling kubernetes/hypervisor"$'\n'* ]]
}

@test "a failed role write stops the runner with the last line of bao and makes no later bao call" {
	export STUB_FAIL='bao write auth/kubernetes/storage/role/push-ceph-keys' STUB_FAIL_LINE='Code: 403. Errors: * permission denied'
	# shellcheck disable=SC2046
	run_runner $(all_four)
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "openbao-remote-auth: error: writing auth/kubernetes/storage/role/push-ceph-keys failed: Code: 403. Errors: * permission denied" ]
	[ "$(calls | tail -n 1 | cut -d ' ' -f 1-3)" = "bao write auth/kubernetes/storage/role/push-ceph-keys" ]
}

@test "a failed policy write, mount list, enable or config write names its step and the last line of bao" {
	local fail message
	export STUB_MOUNTS='{"kubernetes/storage/":{}}' STUB_FAIL_LINE='Code: 500. Errors: * internal error'
	while IFS='|' read -r fail message; do
		rm -f -- "$STUB_LOG"
		export STUB_FAIL=$fail
		# shellcheck disable=SC2046
		run_runner $(all_four)
		echo "$fail: $output"
		[ "$status" -eq 1 ]
		[ "${lines[-1]}" = "openbao-remote-auth: error: $message failed: Code: 500. Errors: * internal error" ]
		[[ $(calls | tail -n 1) == "$fail"* ]]
	done <<'EOF'
bao policy write|writing policy read-ceph-client-cinder
bao auth list|listing the auth mounts
bao auth enable -path=kubernetes/hypervisor|enabling kubernetes/hypervisor
bao write auth/kubernetes/storage/config|writing auth/kubernetes/storage/config
EOF
}
