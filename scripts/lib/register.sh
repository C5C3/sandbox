# shellcheck shell=bash
# The registration of a cluster with the CobaltCore operators of
# sandbox-management. Source scripts/lib/common.sh, scripts/lib/profile.sh
# and scripts/lib/hub.sh first.
#
# A registration is the Secret c5c3-clusters/<name> on sandbox-management
# with the label sigs.k8s.io/multicluster-runtime-kubeconfig: "true". Its
# key kubeconfig is how the operators reach the cluster, its key namespaces
# the comma-separated namespaces they may use there, and its name the
# cluster name that a targetClusterRef names. make up registers the compute
# cluster of the sandbox with the kubeconfig of the ServiceAccount of the
# access chart; scripts/register.sh registers a cluster the sandbox did not
# create.

# register_cluster <name> <namespaces> [<role>]: reads a kubeconfig on stdin
# and applies the Namespace c5c3-clusters and the Secret c5c3-clusters/<name>
# with the keys kubeconfig and namespaces on sandbox-management. With a role,
# the Secret also carries the label sandbox.c5c3.io/cluster: <role>, by which
# ensure_registrations finds the registrations make up wrote. It checks the
# name, the list and the kubeconfig before it writes anything. The operators
# refuse a kubeconfig whose user runs a credential plugin, and upstream then
# leaves the cluster unresolvable without a message on any object. The
# kubeconfig reaches no file and no argument list.
register_cluster() {
	local name=$1 namespaces=$2 role=${3:-} label='[a-z0-9]([-a-z0-9]*[a-z0-9])?' kubeconfig entry json out manifest errfile
	local -a entries=()
	[[ ${#name} -le 253 && $name =~ ^$label(\.$label)*$ ]] ||
		die "register: '$name' is not a cluster name, expected a DNS-1123 subdomain"
	[ -n "$namespaces" ] || die "register: no namespace given"
	# mapfile splits at commas alone, a newline included in an entry, and
	# the comma appended keeps the empty entry of a list that ends with one.
	mapfile -t -d , entries < <(printf '%s,' "$namespaces")
	for entry in "${entries[@]}"; do
		[[ ${#entry} -le 63 && $entry =~ ^$label$ ]] || die "register: '$entry' is not a namespace name"
	done

	kubeconfig=$(cat)
	[ -n "$kubeconfig" ] || die "register: the kubeconfig of $name is empty"
	errfile=$(mktemp)
	if ! json=$(printf '%s\n' "$kubeconfig" | yq -o=json -I=0 '.' 2>"$errfile"); then
		out=$(_first_line "$(<"$errfile")")
		rm -f -- "$errfile"
		die "register: the kubeconfig of $name: ${out#Error: }"
	fi
	rm -f -- "$errfile"
	out=$(printf '%s\n' "$json" | jq -rs '.[0] as $k
		| if ($k | type) != "object" or (($k.clusters[0]?.cluster?.server? // "") == "") then "server"
		  elif [$k.users[]?.user? | objects | select(has("exec") or has("auth-provider"))] | length > 0 then "plugin"
		  else "" end')
	case $out in
	server) die "register: the kubeconfig of $name names no server" ;;
	plugin) die "register: the kubeconfig of $name uses a credential plugin, which the operators refuse; use a token or a client certificate" ;;
	esac

	manifest=$(printf '%s\n' "$kubeconfig" 2>/dev/null | _hub_json -n c5c3-clusters create secret generic "$name" \
		--from-file=kubeconfig=/dev/stdin --dry-run=client) ||
		die "cannot write the Secret c5c3-clusters/$name on sandbox-management: $manifest"
	manifest=$(printf '%s\n' "$manifest" | jq --arg namespaces "$namespaces" --arg role "$role" '
		.metadata.labels["sigs.k8s.io/multicluster-runtime-kubeconfig"] = "true"
		| if $role == "" then . else .metadata.labels["sandbox.c5c3.io/cluster"] = $role end
		| .data.namespaces = ($namespaces | @base64)
		| {apiVersion: "v1", kind: "List",
		   items: [{apiVersion: "v1", kind: "Namespace", metadata: {name: "c5c3-clusters"}}, .]}')
	printf '%s\n' "$manifest" 2>/dev/null |
		_hub_apply "cannot write the Secret c5c3-clusters/$name on sandbox-management" || exit 1
}

# registration_kubeconfig <role>: prints, as JSON, the kubeconfig of the
# ServiceAccount target-cluster-access of the access chart on the role's
# cluster: the server of kind get kubeconfig --internal, and token and
# ca.crt of the Secret c5c3-access/target-cluster-access-token, which it
# reads with the kubeconfig file of the role. The cluster and the context
# are named after the kind cluster, and the one user target-cluster-access
# holds the token alone. It returns 1 without output while the Secret is
# absent or its token or ca.crt is empty, and 2 with the last line of
# kubectl's error when kubectl cannot read it. It writes to stderr only when
# it dies, which it does when kind cannot give the server. The token is
# never an argument of a command.
registration_kubeconfig() {
	local name secret errfile rc=0 internal server
	name=$(cluster_name "$1")
	errfile=$(mktemp)
	secret=$(kubectl --kubeconfig "$(kubeconfig_path "$1")" -n c5c3-access get secret target-cluster-access-token \
		--ignore-not-found -o json 2>"$errfile") || rc=$?
	if [ "$rc" -ne 0 ]; then
		_last_line "$(<"$errfile")"
		rm -f -- "$errfile"
		return 2
	fi
	rm -f -- "$errfile"
	[ -n "$secret" ] &&
		printf '%s\n' "$secret" | jq -e '(.data.token // "") != "" and (.data["ca.crt"] // "") != ""' >/dev/null ||
		return 1
	internal=$(kind get kubeconfig --internal --name "$name" 2>/dev/null) ||
		die "register: cannot read the internal kubeconfig of $name"
	server=$(printf '%s\n' "$internal" | yq '.clusters[0].cluster.server')
	printf '%s\n' "$secret" | jq --arg name "$name" --arg server "$server" '{
		apiVersion: "v1", kind: "Config",
		clusters: [{name: $name, cluster: {server: $server, "certificate-authority-data": .data["ca.crt"]}}],
		users: [{name: "target-cluster-access", user: {token: (.data.token | @base64d)}}],
		contexts: [{name: $name, context: {cluster: $name, user: "target-cluster-access"}}],
		"current-context": $name}'
}

# ensure_registrations: registers or unregisters the cluster of every
# attached role but management. When cluster_modules lists access for the
# role, it restores the kubeconfig file of the role when it is missing,
# polls registration_kubeconfig every 2 s, for at most SANDBOX_STAGE_TIMEOUT
# seconds, by default 600, until the stage <role>-access has installed the
# access chart and the token Secret holds a token, and registers the cluster
# under its kind name for the namespace openstack, with the label of the
# role. Otherwise it deletes the registrations with the label of the role,
# and logs it when one was there. A registration without that label, as
# scripts/register.sh writes it, is never touched, and a missing namespace
# c5c3-clusters is nothing to delete. A second run applies the same Secret
# and changes nothing.
ensure_registrations() {
	local timeout attached role name modules kubeconfig rc failed out errfile start
	timeout=$(_timeout SANDBOX_STAGE_TIMEOUT 600) || exit 1
	attached=$(attached_roles) || exit 1
	for role in $attached; do
		[ "$role" != management ] || continue
		name=$(cluster_name "$role")
		modules=$(cluster_modules "$role") || exit 1
		errfile=$(mktemp)
		if ! grep -qxF access <<<"$modules"; then
			if ! out=$(hub_kubectl -n c5c3-clusters delete secret -l "sandbox.c5c3.io/cluster=$role" \
				--ignore-not-found -o name 2>"$errfile"); then
				out=$(_last_line "$(<"$errfile")")
				rm -f -- "$errfile"
				die "cannot remove the registration of $name: $out"
			fi
			rm -f -- "$errfile"
			# kubectl prints "No resources found" when nothing matched.
			if grep -q '^secret/' <<<"$out"; then
				log "removed the registration of $name"
			fi
			continue
		fi

		log "registering $name in c5c3-clusters for the namespaces openstack"
		# registration_kubeconfig reads the token with the kubeconfig file
		# of the role, which make up writes only for the roles it is given.
		restore_kubeconfig "$role"
		failed=''
		start=$SECONDS
		while :; do
			rc=0
			kubeconfig=$(registration_kubeconfig "$role" 2>"$errfile") || rc=$?
			if [ -s "$errfile" ]; then
				# registration_kubeconfig died, and its message says why.
				cat -- "$errfile" >&2
				rm -f -- "$errfile"
				exit 1
			fi
			case $rc in
			0) break ;;
			2) failed=$kubeconfig ;;
			*) failed='' ;;
			esac
			if [ $((SECONDS - start)) -ge "$timeout" ]; then
				rm -f -- "$errfile"
				die "register: the Secret c5c3-access/target-cluster-access-token on $name holds no token after $timeout s; make status shows the stage $role-access${failed:+; kubectl: $failed}"
			fi
			sleep 2
		done
		rm -f -- "$errfile"
		printf '%s\n' "$kubeconfig" 2>/dev/null | register_cluster "$name" openstack "$role" || exit 1
	done
}
