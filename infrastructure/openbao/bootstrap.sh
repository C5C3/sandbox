#!/usr/bin/env bash
# The runner of the Job openbao-bootstrap (bootstrap.yaml beside this file).
# It initialises, unseals and configures the shared OpenBao in the namespace
# shared-services with the scripts of the upstream base
# shared-openbao/bootstrap, in these steps:
#
#   1. It waits until openbao-0 answers bao status with JSON that says
#      whether OpenBao is initialised. A sealed server answers too.
#   2. It runs init-unseal.sh, which initialises OpenBao once with 5 Shamir
#      shares and threshold 3, keeps the init output with the root token in
#      the Secret openbao-init-keys, and unseals openbao-0 from that Secret.
#   3. It reads the root token from that Secret into BAO_TOKEN.
#   4. It runs setup-secret-engines.sh, setup-auth.sh, setup-policies.sh and
#      write-bootstrap-secrets.sh, in this order.
#   5. It annotates the ClusterSecretStore openbao-cluster-store, so that
#      External Secrets validates the store at once instead of after the
#      back-off of the validations that failed while OpenBao was sealed.
#
# Every step is safe to run again: the upstream scripts skip what exists. The
# runner prints its progress as "openbao-bootstrap: <message>" on stdout, and
# one error as "openbao-bootstrap: error: <message>" on stderr, then exits 1.
# It never prints the init output or the root token.
#
# Environment (the Job sets none of these; tests/unit/openbao-bootstrap.bats
# does):
#   SCRIPTS_DIR                 the upstream scripts, by default /scripts
#   POLICIES_DIR                the upstream policies, by default /policies
#   OPENBAO_BOOTSTRAP_TIMEOUT   seconds to wait for bao status, by default 600
#   OPENBAO_BOOTSTRAP_INTERVAL  seconds between two tries, by default 5
#
# README.md, section "The shared OpenBao", says how to run the Job again.
set -euo pipefail

scripts_dir=${SCRIPTS_DIR:-/scripts}
timeout=${OPENBAO_BOOTSTRAP_TIMEOUT:-600}
interval=${OPENBAO_BOOTSTRAP_INTERVAL:-5}
# The settings of the upstream scripts: the namespace and the one pod of the
# server, and the directory of the policies.
export OPENBAO_NAMESPACE=shared-services OPENBAO_PODS=openbao-0
export POLICIES_DIR=${POLICIES_DIR:-/policies}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

say() {
	printf 'openbao-bootstrap: %s\n' "$*"
}

die() {
	printf 'openbao-bootstrap: error: %s\n' "$*" >&2
	exit 1
}

# errline: prints the last non-empty line the last kubectl call printed on
# stderr.
errline() {
	awk 'NF { last = $0 } END { if (last != "") print last; else print "kubectl printed no error" }' "$tmp/err"
}

# bao_answers: succeeds when bao status in openbao-0, run without a token and
# with the environment of bao_exec in upstream's common.sh, prints JSON whose
# initialized is a boolean. A sealed server exits 2 and still prints it.
bao_answers() {
	local out
	out=$(kubectl exec -n "$OPENBAO_NAMESPACE" openbao-0 -- env BAO_ADDR=https://127.0.0.1:8200 \
		VAULT_CACERT=/openbao/tls/ca.crt VAULT_CLIENT_CERT=/openbao/client-tls/tls.crt \
		VAULT_CLIENT_KEY=/openbao/client-tls/tls.key bao status -format=json 2>"$tmp/err") || true
	jq -e '.initialized | type == "boolean"' <<<"$out" >/dev/null 2>&1
}

say "waiting for openbao-0 to answer bao status"
deadline=$((SECONDS + timeout))
until bao_answers; do
	[ "$SECONDS" -lt "$deadline" ] || die "openbao-0 did not answer bao status within $timeout s: $(errline)"
	sleep "$interval"
done

say "running init-unseal.sh"
bash "$scripts_dir/init-unseal.sh" || die "init-unseal.sh failed with exit status $?"

# The setup scripts read the root token from BAO_TOKEN, as upstream's
# deploy/README.md runs them.
token=$(kubectl -n "$OPENBAO_NAMESPACE" get secret openbao-init-keys -o jsonpath='{.data.init-output}' 2>/dev/null |
	base64 -d 2>/dev/null | jq -r '.root_token // empty' 2>/dev/null) || token=''
[ -n "$token" ] || die "Secret $OPENBAO_NAMESPACE/openbao-init-keys holds no root_token"
export BAO_TOKEN=$token

for script in setup-secret-engines setup-auth setup-policies write-bootstrap-secrets; do
	say "running $script.sh"
	bash "$scripts_dir/$script.sh" || die "$script.sh failed with exit status $?"
done

if ! kubectl annotate clustersecretstore.external-secrets.io/openbao-cluster-store \
	"sandbox.c5c3.io/bootstrapped=$(date +%s)" --overwrite >/dev/null 2>"$tmp/err"; then
	say "cannot annotate ClusterSecretStore openbao-cluster-store, External Secrets validates it at its next retry: $(errline)"
fi
say done
