#!/usr/bin/env bash
# The runner of the Job controlplane-database-tenant (tenant.yaml beside this
# file). It onboards the ControlPlane controlplane in the namespace openstack
# as a database tenant of the shared OpenBao with the script
# setup-database-tenant.sh of the upstream base shared-openbao/bootstrap, in
# these steps:
#
#   1. It waits until the Ready condition of the MariaDB openstack-db in the
#      namespace openstack is True.
#   2. It reads the root token from the Secret openbao-init-keys in the
#      namespace shared-services into BAO_TOKEN.
#   3. It runs setup-database-tenant.sh openstack controlplane, which writes
#      the database-engine connection and role of Keystone. It fails when
#      OpenBao is sealed.
#
# A second run is safe: the upstream script upserts the connection and the
# role. The runner prints its progress as "controlplane-database-tenant:
# <message>" on stdout, and one error as "controlplane-database-tenant: error:
# <message>" on stderr, then exits 1. It never prints the root token.
#
# Environment (the Job sets none of these; tests/unit/controlplane-tenant.bats
# does):
#   SCRIPTS_DIR       the upstream scripts, by default /scripts
#   TENANT_TIMEOUT    seconds to wait for the MariaDB, by default 1500
#   TENANT_INTERVAL   seconds between two tries, by default 5
#
# README.md, section "The database tenant onboarding", says how to run the Job
# again.
set -euo pipefail

scripts_dir=${SCRIPTS_DIR:-/scripts}
timeout=${TENANT_TIMEOUT:-1500}
interval=${TENANT_INTERVAL:-5}
# The setting of the upstream scripts: the namespace of the shared OpenBao.
export OPENBAO_NAMESPACE=shared-services

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

say() {
	printf 'controlplane-database-tenant: %s\n' "$*"
}

die() {
	printf 'controlplane-database-tenant: error: %s\n' "$*" >&2
	exit 1
}

# errline: prints the last non-empty line the last kubectl call printed on
# stderr.
errline() {
	awk 'NF { last = $0 } END { if (last != "") print last; else print "kubectl printed no error" }' "$tmp/err"
}

# mariadb_ready: succeeds when the Ready condition of the MariaDB openstack-db
# is True. Otherwise it sets detail to why not: the last error line of
# kubectl, or the status of the condition.
detail=''
mariadb_ready() {
	local ready
	if ! ready=$(kubectl -n openstack get mariadbs.k8s.mariadb.com openstack-db \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>"$tmp/err"); then
		detail=$(errline)
		return 1
	fi
	[ "$ready" != True ] || return 0
	detail="its Ready condition is '$ready'"
	return 1
}

say "waiting for MariaDB openstack/openstack-db to be Ready"
deadline=$((SECONDS + timeout))
until mariadb_ready; do
	[ "$SECONDS" -lt "$deadline" ] || die "MariaDB openstack/openstack-db is not Ready within $timeout s: $detail"
	sleep "$interval"
done

# setup-database-tenant.sh reads the root token from BAO_TOKEN, as its usage
# says.
token=$(kubectl -n "$OPENBAO_NAMESPACE" get secret openbao-init-keys -o jsonpath='{.data.init-output}' 2>/dev/null |
	base64 -d 2>/dev/null | jq -r '.root_token // empty' 2>/dev/null) || token=''
[ -n "$token" ] || die "Secret $OPENBAO_NAMESPACE/openbao-init-keys holds no root_token"
export BAO_TOKEN=$token

say "running setup-database-tenant.sh openstack controlplane"
bash "$scripts_dir/setup-database-tenant.sh" openstack controlplane ||
	die "setup-database-tenant.sh failed with exit status $?"
say done
