# shellcheck shell=bash
# What the key hand-off needs on the hub from outside Flux. Source
# scripts/lib/common.sh, scripts/lib/profile.sh and scripts/lib/hub.sh first.
#
# The module openbao-remote-auth on sandbox-management lets OpenBao review
# the tokens of the storage and compute clusters, and issues their client
# certificates. Two things cross the cluster boundary that no stage can
# carry: the API server and CA of each remote cluster, which only kind
# knows, and the client certificates, whose Secrets lie in shared-services,
# where no stage can read them, under keys such as tls.crt, which cannot be
# a Flux variable. The command layer copies both into flux-system, from
# where the stages substitute them (ADR-0038, ADR-0039).

# ensure_remote_auth: when cluster_modules lists openbao-remote-auth for
# management, it applies the ConfigMap flux-system/openbao-remote-auth with
# the label reconcile.fluxcd.io/watch and, for each attached role among
# storage and compute, <ROLE>_API_SERVER and <ROLE>_API_CA_B64 from the
# server and certificate-authority-data of kind's internal kubeconfig of the
# role's cluster, or with no data when none is attached. For each of those
# roles it then polls the Secret shared-services/openbao-client-<role> every
# 2 s, for at most SANDBOX_STAGE_TIMEOUT seconds, by default 600, until its
# tls.crt, tls.key and ca.crt are not empty; an absent Secret counts as
# empty. It applies the Secret flux-system/openbao-client-<role> with the
# labels reconcile.fluxcd.io/watch and sandbox.c5c3.io/openbao-client and
# the stringData OPENBAO_CLIENT_CRT_B64, OPENBAO_CLIENT_KEY_B64 and
# OPENBAO_CA_B64, the three values as the API server serves them, base64 of
# the PEM. The key goes from kubectl's output through jq into kubectl's
# stdin and reaches no file and no argument list. A second run applies the
# same objects and changes nothing.
#
# Without the module it deletes the Secrets of flux-system with the label
# sandbox.c5c3.io/openbao-client, and logs it when one was there. A
# ConfigMap of an earlier run stays: it holds public CAs, and no stage reads
# it then.
ensure_remote_auth() {
	local timeout modules attached role roles='' names='' kubeconfig fields server ca data errfile out
	local start secret missing failed manifest
	timeout=$(_timeout SANDBOX_STAGE_TIMEOUT 600) || exit 1
	modules=$(cluster_modules management) || exit 1
	if ! grep -qxF openbao-remote-auth <<<"$modules"; then
		errfile=$(mktemp)
		if ! out=$(hub_kubectl -n flux-system delete secret -l sandbox.c5c3.io/openbao-client \
			--ignore-not-found -o name 2>"$errfile"); then
			out=$(_last_line "$(<"$errfile")")
			rm -f -- "$errfile"
			die "openbao-remote-auth: cannot remove the OpenBao client certificates of the hub: $out"
		fi
		rm -f -- "$errfile"
		# kubectl prints "No resources found" when nothing matched.
		if grep -q '^secret/' <<<"$out"; then
			log "removed the OpenBao client certificates of the hub"
		fi
		return 0
	fi

	attached=$(attached_roles) || exit 1
	for role in $attached; do
		case $role in
		storage | compute)
			roles+=${roles:+ }$role
			names+=${names:+ and }$(cluster_name "$role")
			;;
		esac
	done

	data='{}'
	for role in $roles; do
		# The kubeconfig holds the key of the cluster's admin, so it goes to
		# yq on stdin too.
		kubeconfig=$(kind get kubeconfig --internal --name "$(cluster_name "$role")" 2>/dev/null) ||
			die "openbao-remote-auth: cannot read the internal kubeconfig of $(cluster_name "$role")"
		fields=$(printf '%s\n' "$kubeconfig" |
			yq '[.clusters[0].cluster.server // "", .clusters[0].cluster["certificate-authority-data"] // ""] | join(" ")' 2>/dev/null) ||
			fields=''
		server=${fields%% *} ca=${fields#* }
		[ -n "$server" ] && [ -n "$ca" ] ||
			die "openbao-remote-auth: the internal kubeconfig of $(cluster_name "$role") names no server or no CA"
		data=$(jq -c --arg prefix "${role^^}" --arg server "$server" --arg ca "$ca" \
			'. + {($prefix + "_API_SERVER"): $server, ($prefix + "_API_CA_B64"): $ca}' <<<"$data")
	done
	log "writing the ConfigMap flux-system/openbao-remote-auth for ${names:-no remote cluster}"
	manifest=$(jq --argjson data "$data" -n '{apiVersion: "v1", kind: "ConfigMap",
		metadata: {name: "openbao-remote-auth", namespace: "flux-system", labels: {"reconcile.fluxcd.io/watch": "Enabled"}},
		data: $data}')
	printf '%s\n' "$manifest" |
		_hub_apply "cannot write the ConfigMap flux-system/openbao-remote-auth on sandbox-management" || exit 1

	for role in $roles; do
		log "waiting for the OpenBao client certificate of $(cluster_name "$role")"
		start=$SECONDS
		while :; do
			failed=''
			if ! secret=$(_hub_json -n shared-services get secret "openbao-client-$role" --ignore-not-found); then
				failed=$secret
				secret=''
			fi
			# The first of the three keys that is absent or empty; all three
			# for an absent Secret.
			missing=tls.crt
			if [ -n "$secret" ]; then
				missing=$(printf '%s\n' "$secret" |
					jq -r '[("tls.crt", "tls.key", "ca.crt") as $key | select((.data[$key] // "") == "") | $key][0] // empty')
			fi
			[ -n "$missing" ] || break
			[ $((SECONDS - start)) -lt "$timeout" ] ||
				die "openbao-remote-auth: the Secret shared-services/openbao-client-$role on sandbox-management holds no $missing after $timeout s; make status shows the stage management-openbao-remote-auth${failed:+; kubectl: $failed}"
			sleep 2
		done

		log "writing the Secret flux-system/openbao-client-$role"
		printf '%s\n' "$secret" |
			jq --arg role "$role" '{apiVersion: "v1", kind: "Secret",
				metadata: {name: ("openbao-client-" + $role), namespace: "flux-system",
					labels: {"reconcile.fluxcd.io/watch": "Enabled", "sandbox.c5c3.io/openbao-client": $role}},
				stringData: {OPENBAO_CLIENT_CRT_B64: .data["tls.crt"], OPENBAO_CLIENT_KEY_B64: .data["tls.key"],
					OPENBAO_CA_B64: .data["ca.crt"]}}' |
			_hub_apply "cannot write the Secret flux-system/openbao-client-$role on sandbox-management" || exit 1
	done
}
