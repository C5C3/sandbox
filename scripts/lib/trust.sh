# shellcheck shell=bash
# The sandbox CA on the hub, for the stages of the compute cluster that need
# it. Source scripts/lib/common.sh, scripts/lib/profile.sh and
# scripts/lib/hub.sh first.
#
# The Secret cert-manager/sandbox-ca on sandbox-management holds the CA,
# which the stage management-pki creates, and no stage can read a Secret of
# another namespace. The command layer copies its tls.crt into the ConfigMap
# flux-system/sandbox-trust, from which the stage compute-trust substitutes
# the CA into the Secrets of the module trust on sandbox-compute.

# ensure_trust: writes the ConfigMap flux-system/sandbox-trust when
# cluster_modules lists trust for an attached role other than management,
# and does nothing otherwise. It polls the Secret cert-manager/sandbox-ca
# every 2 s, for at most SANDBOX_STAGE_TIMEOUT seconds, by default 600, until
# its key tls.crt is not empty; an absent Secret counts as an empty key. It
# then applies the ConfigMap with the label reconcile.fluxcd.io/watch and the
# one key SANDBOX_CA_B64, the value of tls.crt as the API server serves it,
# base64 of the PEM. A second run applies the same ConfigMap and changes
# nothing. A profile without trust leaves a ConfigMap of an earlier run in
# place: it holds a public certificate, and no stage reads it then.
ensure_trust() {
	local timeout attached role modules wanted=false start secret ca failed manifest
	timeout=$(_timeout SANDBOX_STAGE_TIMEOUT 600) || exit 1
	attached=$(attached_roles) || exit 1
	for role in $attached; do
		[ "$role" != management ] || continue
		modules=$(cluster_modules "$role") || exit 1
		if grep -qxF trust <<<"$modules"; then
			wanted=true
		fi
	done
	$wanted || return 0

	log "waiting for the sandbox CA of sandbox-management"
	start=$SECONDS
	while :; do
		failed=''
		ca=''
		if secret=$(_hub_json -n cert-manager get secret sandbox-ca --ignore-not-found); then
			if [ -n "$secret" ]; then
				ca=$(jq -r '.data["tls.crt"] // empty' <<<"$secret")
			fi
		else
			failed=$secret
		fi
		[ -z "$ca" ] || break
		[ $((SECONDS - start)) -lt "$timeout" ] ||
			die "trust: the Secret cert-manager/sandbox-ca on sandbox-management holds no tls.crt after $timeout s; make status shows the stage management-pki${failed:+; kubectl: $failed}"
		sleep 2
	done

	log "writing the ConfigMap flux-system/sandbox-trust"
	manifest=$(jq -n --arg ca "$ca" '{apiVersion: "v1", kind: "ConfigMap",
		metadata: {name: "sandbox-trust", namespace: "flux-system", labels: {"reconcile.fluxcd.io/watch": "Enabled"}},
		data: {SANDBOX_CA_B64: $ca}}')
	printf '%s\n' "$manifest" 2>/dev/null |
		_hub_apply "cannot write the ConfigMap flux-system/sandbox-trust on sandbox-management" || exit 1
}
