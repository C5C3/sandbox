#!/usr/bin/env bash
# The runner of the Job openbao-remote-auth (job.yaml beside this file). It
# configures the shared OpenBao in the namespace shared-services for the
# storage and compute clusters, with the helpers of upstream's
# shared-openbao/bootstrap/common.sh, which run every bao command in
# openbao-0, in these steps:
#
#   1. It checks the API server and CA of each remote cluster in its
#      environment: both or neither, and the CA base64 of a PEM certificate.
#   2. It reads the root token from the init output in the Secret
#      openbao-init-keys into BAO_TOKEN, as bootstrap.sh of the module
#      openbao does.
#   3. It writes the policy read-ceph-client-cinder from
#      read-ceph-client-cinder.hcl beside this file.
#   4. It lists the auth mounts once and enables kubernetes/storage or
#      kubernetes/hypervisor when one is missing.
#   5. It writes the role push-ceph-keys on kubernetes/storage for the
#      ServiceAccount rook-ceph/ceph-keys-push, and the role
#      read-ceph-client-cinder on kubernetes/hypervisor for the
#      ServiceAccount openstack/ceph-keys-read.
#   6. For the storage cluster (mount kubernetes/storage) and the compute
#      cluster (mount kubernetes/hypervisor) it writes
#      auth/kubernetes/<mount>/config with the API server and the CA of the
#      cluster, or leaves it as it is when the environment names no API
#      server. disable_local_ca_jwt=true without a token_reviewer_jwt makes
#      OpenBao review a login with the token of the login itself (ADR-0038).
#
# Every step is safe to run again. The runner prints its progress as
# "openbao-remote-auth: <message>" on stdout, and one error as
# "openbao-remote-auth: error: <message>" on stderr, then exits 1. It never
# prints the init output or the root token.
#
# Environment (the stage substitutes the first four from the ConfigMap
# flux-system/openbao-remote-auth that make up writes):
#   STORAGE_API_SERVER, STORAGE_API_CA_B64  the API server of sandbox-storage
#                                           and base64 of the PEM of its CA
#   COMPUTE_API_SERVER, COMPUTE_API_CA_B64  the same for sandbox-compute
#   SCRIPTS_DIR                             the directory of upstream's
#                                           common.sh, by default /runner
set -euo pipefail

dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export OPENBAO_NAMESPACE=shared-services
# shellcheck source=../../vendor/cobaltcore/deploy/bases/shared-openbao/bootstrap/common.sh
. "${SCRIPTS_DIR:-/runner}/common.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

say() {
	printf 'openbao-remote-auth: %s\n' "$*"
}

die() {
	printf 'openbao-remote-auth: error: %s\n' "$*" >&2
	exit 1
}

# errline: prints the last non-empty line the last bao call printed on
# stderr.
errline() {
	awk 'NF { last = $0 } END { if (last != "") print last; else print "bao printed no error" }' "$tmp/err"
}

# bao_write <path> <argument>...: writes the path with bao in openbao-0, and
# stops the runner when that fails.
bao_write() {
	bao_exec bao write "$@" >/dev/null 2>"$tmp/err" || die "writing $1 failed: $(errline)"
}

# The remote clusters: the role, the prefix of its variables and its mount.
remotes=(storage:STORAGE:storage compute:COMPUTE:hypervisor)
declare -A servers=() pems=()
for remote in "${remotes[@]}"; do
	IFS=: read -r role prefix mount <<<"$remote"
	server_var=${prefix}_API_SERVER ca_var=${prefix}_API_CA_B64
	server=${!server_var:-} ca=${!ca_var:-}
	if [ -z "$server" ] && [ -z "$ca" ]; then
		continue
	fi
	[ -n "$server" ] && [ -n "$ca" ] || die "$server_var and $ca_var are given together or not at all"
	pem=$(printf '%s' "$ca" | base64 -d 2>/dev/null) || pem=''
	[[ $pem == "-----BEGIN CERTIFICATE-----"* ]] || die "$ca_var is not base64 of a PEM certificate"
	servers[$role]=$server pems[$role]=$pem
done

token=$(kubectl -n "$OPENBAO_NAMESPACE" get secret openbao-init-keys -o jsonpath='{.data.init-output}' 2>/dev/null |
	base64 -d 2>/dev/null | jq -r '.root_token // empty' 2>/dev/null) || token=''
[ -n "$token" ] || die "Secret $OPENBAO_NAMESPACE/openbao-init-keys holds no root_token"
export BAO_TOKEN=$token

say "writing policy read-ceph-client-cinder"
bao_exec_stdin bao policy write read-ceph-client-cinder - <"$dir/read-ceph-client-cinder.hcl" >/dev/null 2>"$tmp/err" ||
	die "writing policy read-ceph-client-cinder failed: $(errline)"

# The list is read once into a variable, never piped into grep -q: see
# auth_mounts in upstream's setup-auth.sh.
out=$(bao_exec bao auth list -format=json 2>"$tmp/err") || die "listing the auth mounts failed: $(errline)"
mounts=$(jq -r 'keys[]' <<<"$out" 2>"$tmp/err") || die "listing the auth mounts failed: $(errline)"
for mount in kubernetes/storage kubernetes/hypervisor; do
	if ! grep -qxF "$mount/" <<<"$mounts"; then
		say "enabling $mount"
		bao_exec bao auth enable -path="$mount" kubernetes >/dev/null 2>"$tmp/err" ||
			die "enabling $mount failed: $(errline)"
	fi
done

say "writing auth/kubernetes/storage/role/push-ceph-keys"
bao_write auth/kubernetes/storage/role/push-ceph-keys \
	bound_service_account_names=ceph-keys-push bound_service_account_namespaces=rook-ceph \
	token_policies=push-ceph-keys token_ttl=1h token_max_ttl=4h
say "writing auth/kubernetes/hypervisor/role/read-ceph-client-cinder"
bao_write auth/kubernetes/hypervisor/role/read-ceph-client-cinder \
	bound_service_account_names=ceph-keys-read bound_service_account_namespaces=openstack \
	token_policies=read-ceph-client-cinder token_ttl=1h token_max_ttl=4h

for remote in "${remotes[@]}"; do
	IFS=: read -r role prefix mount <<<"$remote"
	path=auth/kubernetes/$mount/config
	if [ -z "${servers[$role]:-}" ]; then
		say "no API server of sandbox-$role, leaving $path as it is"
		continue
	fi
	printf '%s\n' "${pems[$role]}" |
		bao_exec_stdin bao write "$path" kubernetes_host="${servers[$role]}" kubernetes_ca_cert=- \
			disable_local_ca_jwt=true >/dev/null 2>"$tmp/err" ||
		die "writing $path failed: $(errline)"
	say "wrote $path for ${servers[$role]}"
done
say done
