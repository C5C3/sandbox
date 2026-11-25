# shellcheck shell=bash
# The access of the OpenStack CLI to the ControlPlane openstack/controlplane
# on sandbox-management, for make env and make verify. Source
# scripts/lib/common.sh and scripts/lib/hub.sh first.
#
# Both functions read the hub only, so they work with any configuration and
# any profile. Every failure goes through die: it exits 1, prints nothing on
# stdout, and no message holds the admin password.

# access_controlplane: prints the ControlPlane openstack/controlplane of
# sandbox-management as JSON, or nothing when the CRD controlplanes.c5c3.io
# or the object is absent. It restores the kubeconfig of sandbox-management
# when the file is missing, with the message on stderr.
access_controlplane() {
	local out
	sandbox_cluster management || die "access: sandbox-management does not exist; run make up"
	restore_kubeconfig management >&2
	# --ignore-not-found makes a missing object an empty answer.
	out=$(_hub_json get crd controlplanes.c5c3.io --ignore-not-found) ||
		die "access: cannot read the CRD controlplanes.c5c3.io: $out"
	if [ -z "$out" ]; then
		return 0
	fi
	out=$(_hub_json -n openstack get controlplanes.c5c3.io controlplane --ignore-not-found) ||
		die "access: cannot read the ControlPlane openstack/controlplane: $out"
	if [ -n "$out" ]; then
		printf '%s\n' "$out"
	fi
}

# access_load: exports the variables of the OpenStack CLI for the admin of
# the ControlPlane openstack/controlplane: OS_AUTH_URL, the Keystone hostname
# of its Gateway with /v3, OS_USERNAME, OS_PASSWORD from the Secret
# openstack/controlplane-keystone-admin-credentials, OS_PROJECT_NAME,
# OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME and OS_CACERT. OS_CACERT names
# SANDBOX_STATE_DIR/sandbox-ca.pem, which it writes from the key tls.crt of
# the Secret cert-manager/sandbox-ca through a temporary file in the same
# directory. It reads everything before it writes the file and exports all
# seven or none.
access_load() {
	local controlplane hostname secret password ca tmp
	controlplane=$(access_controlplane) || exit 1
	[ -n "$controlplane" ] ||
		die "access: no ControlPlane openstack/controlplane on sandbox-management; the profile runs no control plane"
	hostname=$(jq -r '.spec.services.keystone.gateway.hostname // empty' <<<"$controlplane")
	[ -n "$hostname" ] || die "access: the ControlPlane openstack/controlplane publishes no Keystone hostname"

	secret=$(_hub_json -n openstack get secret controlplane-keystone-admin-credentials --ignore-not-found) ||
		die "access: cannot read the Secret openstack/controlplane-keystone-admin-credentials: $secret"
	password=$(jq -r '.data.password // empty | @base64d' <<<"$secret")
	[ -n "$password" ] ||
		die "access: the Secret openstack/controlplane-keystone-admin-credentials holds no password; the ControlPlane is not Ready, make status shows its stage"

	secret=$(_hub_json -n cert-manager get secret sandbox-ca --ignore-not-found) ||
		die "access: cannot read the Secret cert-manager/sandbox-ca: $secret"
	ca=$(jq -r '.data["tls.crt"] // empty | @base64d' <<<"$secret")
	[ -n "$ca" ] || die "access: the Secret cert-manager/sandbox-ca holds no tls.crt"

	# A reader of sandbox-ca.pem sees the old file or the new one, never a
	# part of it.
	mkdir -p -- "$SANDBOX_STATE_DIR"
	tmp=$(mktemp -- "$SANDBOX_STATE_DIR/sandbox-ca.pem.XXXXXX")
	printf '%s\n' "$ca" >"$tmp"
	mv -f -- "$tmp" "$SANDBOX_STATE_DIR/sandbox-ca.pem"

	export OS_AUTH_URL=https://$hostname/v3
	export OS_USERNAME=admin
	export OS_PASSWORD=$password
	export OS_PROJECT_NAME=admin
	export OS_USER_DOMAIN_NAME=Default
	export OS_PROJECT_DOMAIN_NAME=Default
	export OS_CACERT=$SANDBOX_STATE_DIR/sandbox-ca.pem
}
