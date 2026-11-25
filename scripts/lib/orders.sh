# shellcheck shell=bash
# The order checks of make verify. Source scripts/lib/hub.sh first; the
# functions use report, poll, os_error, errfile and controlplane of
# scripts/verify.sh, which sources this file.
#
# They run when the ControlPlane assigns a namespace on the management
# cluster, an entry of spec.namespaceAssignments without targetClusterRef,
# after the checks of the services and in this order:
#
#   orders-ready     every order of the seven kinds in the assigned
#                    namespaces is Ready; on a bus without clusterRef, which
#                    serves no vhost orders, a RabbitMQVhost passes when its
#                    VhostReady names the refusal of that bus
#   orders-secrets   each Ready order of a kind that delivers credentials has
#                    the Secret <name>-credentials beside it, controlled by the
#                    order, with a value for each key of its kind
#   orders-converge  the scratch orders, sandbox-verify and the names that
#                    start with it, are Ready within 300 s, with their Secrets
#   orders-rotation  sandbox-verify-appcred rotates to generation 2 on its
#                    schedule of 3m, generation 1 authenticates inside its
#                    grace period of 2m and is refused after it
#   orders-teardown  the scratch orders, deleted in the order of their holds,
#                    leave no Secret, no labelled child and no user, project
#                    or catalog row in Keystone
#
# The scratch orders live in the first assigned namespace that allows the
# role member and catalog entries; the vhost is ordered on a managed bus
# only. Before the first check the scratch orders of an earlier run are
# deleted, and orders-teardown deletes them whenever they were applied. A
# token by application credential is issued with the id and the secret in
# the environment of openstack, never as an argument, and no line prints a
# value of a Secret.

# The seven order kinds, as one argument of kubectl get.
ORDER_RESOURCES=keystoneusers.c5c3.io,keystoneprojects.c5c3.io,keystoneroleassignments.c5c3.io,keystonecatalogentries.c5c3.io,keystoneapplicationcredentials.c5c3.io,mariadbdatabases.c5c3.io,rabbitmqvhosts.c5c3.io
# The kinds of the objects the operator creates for an order and labels with
# c5c3.io/<kind>-namespace and c5c3.io/<kind>-name, the delivered Secret
# among them.
ORDER_CHILDREN=secrets,pushsecrets.external-secrets.io,externalsecrets.external-secrets.io,vaultdynamicsecrets.generators.external-secrets.io,users.openstack.k-orc.cloud,projects.openstack.k-orc.cloud,roles.openstack.k-orc.cloud,roleassignments.openstack.k-orc.cloud,services.openstack.k-orc.cloud,endpoints.openstack.k-orc.cloud,regions.openstack.k-orc.cloud,applicationcredentials.openstack.k-orc.cloud,databases.k8s.mariadb.com,vhosts.rabbitmq.com,users.rabbitmq.com,permissions.rabbitmq.com
# The scratch orders as kind, resource and name, in the order of the holds of
# Step 10 of upstream's Quick Start (Orders): a credential holds its user and
# project, an assignment its user and project.
ORDER_SCRATCH=(
	'KeystoneApplicationCredential keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred'
	'KeystoneRoleAssignment keystoneroleassignments.c5c3.io sandbox-verify-member'
	'KeystoneCatalogEntry keystonecatalogentries.c5c3.io sandbox-verify-catalog'
	'KeystoneProject keystoneprojects.c5c3.io sandbox-verify-project'
	'KeystoneUser keystoneusers.c5c3.io sandbox-verify'
	'MariaDBDatabase mariadbdatabases.c5c3.io sandbox-verify-db'
	'RabbitMQVhost rabbitmqvhosts.c5c3.io sandbox-verify-bus'
)

# What check_orders read from the ControlPlane: the assigned namespaces,
# separated by spaces, the namespace of the scratch orders, the reason with
# which a RabbitMQVhost is refused, empty on a managed bus, and the scratch
# orders of that bus.
orders_namespaces=
orders_scratch_ns=
orders_refusal=
orders_scratch=()
# What orders-ready read: the orders of the assigned namespaces as orders_read
# prints them, or the line of the check that could not read them.
orders_items=
orders_read_error=
# The number of Secrets that the last orders_secrets passed.
orders_secret_count=0
# What appcred_keys read last, or why it could not, and every value it read,
# which appcred_error hides.
appcred_id=
appcred_secret=
appcred_failure=
appcred_values=()

# order_keys <kind>: prints the keys of the Secret that an order of the kind
# delivers, separated by spaces, or nothing for a kind without a Secret.
order_keys() {
	case $1 in
	KeystoneUser) echo clouds.yaml password ;;
	KeystoneApplicationCredential) echo clouds.yaml application_credential_id application_credential_secret ;;
	MariaDBDatabase) echo host port database username password ;;
	RabbitMQVhost) echo transport_url host port username password vhost ;;
	esac
}

# orders_read <namespace>: prints the orders of the namespace as a JSON array
# of {kind, namespace, name, uid, ready, refused, failure}. refused is true
# for a RabbitMQVhost whose VhostReady names orders_refusal; failure is
# <Type>=<Status> (<Reason>) of the first condition other than Ready that is
# not True, else of Ready, or "has no condition". A namespace that does not
# exist holds no order. When kubectl fails, it prints the last line of its
# error and returns 1.
orders_read() {
	local out
	if ! out=$(_hub_json -n "$1" get "$ORDER_RESOURCES"); then
		printf '%s\n' "$out"
		return 1
	fi
	jq -c --arg refusal "$orders_refusal" '[.items[]? | (.status.conditions // []) as $c | {
		kind, namespace: .metadata.namespace, name: .metadata.name, uid: .metadata.uid,
		ready: any($c[]; .type == "Ready" and .status == "True"),
		refused: (.kind == "RabbitMQVhost" and $refusal != "" and any($c[]; .type == "VhostReady" and .reason == $refusal)),
		failure: ([$c[] | select(.type != "Ready" and .status != "True")] + [$c[] | select(.type == "Ready")]
			| if length == 0 then "has no condition" else .[0] | "\(.type)=\(.status) (\(.reason // ""))" end)}]' <<<"$out"
}

# orders_secrets <id> <orders>: checks the Secret of each Ready order of a
# kind that delivers one, in the JSON array of orders_read, and reports the
# first failure under the check id. It sets orders_secret_count to the
# number of Secrets that passed, and returns 1 after a failure.
orders_secrets() {
	local id=$1 kind ns name uid keys secret key
	orders_secret_count=0
	while IFS=$'\t' read -r kind ns name uid <&3; do
		keys=$(order_keys "$kind")
		if [ -z "$keys" ]; then
			continue
		fi
		secret=$(_hub_json -n "$ns" get secret "$name-credentials" --ignore-not-found) || {
			report FAIL "$id" "cannot read the Secret $ns/$name-credentials: $secret"
			return 1
		}
		if [ -z "$secret" ]; then
			report FAIL "$id" "the Secret $ns/$name-credentials is missing"
			return 1
		fi
		if ! jq -e --arg uid "$uid" 'any(.metadata.ownerReferences[]?; .controller == true and .uid == $uid)' >/dev/null <<<"$secret"; then
			report FAIL "$id" "the Secret $ns/$name-credentials is not controlled by $kind $name"
			return 1
		fi
		for key in $keys; do
			if ! jq -e --arg key "$key" '(.data[$key] // "") != ""' >/dev/null <<<"$secret"; then
				report FAIL "$id" "the Secret $ns/$name-credentials holds no $key"
				return 1
			fi
		done
		orders_secret_count=$((orders_secret_count + 1))
	done 3< <(jq -r '.[] | select(.ready) | [.kind, .namespace, .name, .uid] | @tsv' <<<"$2")
}

# check_orders_ready: the check orders-ready. It reads the orders of every
# assigned namespace into orders_items.
check_orders_ready() {
	local ns items line count refused
	local list=${orders_namespaces// /, }
	orders_items='[]'
	for ns in $orders_namespaces; do
		if ! items=$(orders_read "$ns"); then
			orders_read_error="cannot read the orders of $ns: $items"
			report FAIL orders-ready "$orders_read_error"
			return
		fi
		orders_items=$(jq -c --argjson items "$items" '. + $items' <<<"$orders_items")
	done

	line=$(jq -r '[.[] | select((.ready or .refused) | not)][0] // empty
		| "\(.kind) \(.namespace)/\(.name) is not Ready: \(.failure)"' <<<"$orders_items")
	if [ -n "$line" ]; then
		report FAIL orders-ready "$line"
	elif [ "$orders_items" = '[]' ]; then
		report ok orders-ready "no order in $list"
	else
		count=$(jq '[.[] | select(.ready)] | length' <<<"$orders_items")
		refused=$(jq -r --arg reason "$orders_refusal" '[.[] | select(.refused)
			| ", RabbitMQVhost \(.namespace)/\(.name) reports \($reason) on a bus that serves no vhost orders"] | join("")' <<<"$orders_items")
		report ok orders-ready "$count orders in $list are Ready$refused"
	fi
}

# check_orders_secrets: the check orders-secrets, on the orders that
# orders-ready read.
check_orders_secrets() {
	if [ -n "$orders_read_error" ]; then
		report FAIL orders-secrets "$orders_read_error"
	elif orders_secrets orders-secrets "$orders_items"; then
		report ok orders-secrets "$orders_secret_count credentials Secrets sit beside their orders in ${orders_namespaces// /, }"
	fi
}

# orders_manifest: prints the scratch orders in orders_scratch_ns, the vhost
# only on a managed bus.
orders_manifest() {
	local ref="  controlPlaneRef: {name: controlplane, namespace: openstack}"
	cat <<EOF
apiVersion: c5c3.io/v1alpha1
kind: KeystoneUser
metadata: {name: sandbox-verify, namespace: $orders_scratch_ns}
spec:
$ref
---
apiVersion: c5c3.io/v1alpha1
kind: KeystoneProject
metadata: {name: sandbox-verify-project, namespace: $orders_scratch_ns}
spec:
$ref
---
apiVersion: c5c3.io/v1alpha1
kind: KeystoneRoleAssignment
metadata: {name: sandbox-verify-member, namespace: $orders_scratch_ns}
spec:
$ref
  userRef: {name: sandbox-verify}
  projectRef: {name: sandbox-verify-project}
  role: member
---
apiVersion: c5c3.io/v1alpha1
kind: KeystoneCatalogEntry
metadata: {name: sandbox-verify-catalog, namespace: $orders_scratch_ns}
spec:
$ref
  serviceType: sandbox-verify
  serviceName: sandbox-verify
  endpoints:
    - {interface: public, url: https://sandbox-verify.example.test/v1}
---
apiVersion: c5c3.io/v1alpha1
kind: KeystoneApplicationCredential
metadata: {name: sandbox-verify-appcred, namespace: $orders_scratch_ns}
spec:
$ref
  userRef: {name: sandbox-verify}
  projectRef: {name: sandbox-verify-project}
  rotation: {interval: 3m, gracePeriod: 2m}
---
apiVersion: c5c3.io/v1alpha1
kind: MariaDBDatabase
metadata: {name: sandbox-verify-db, namespace: $orders_scratch_ns}
spec:
$ref
  deletionPolicy: Delete
EOF
	if [ -z "$orders_refusal" ]; then
		cat <<EOF
---
apiVersion: c5c3.io/v1alpha1
kind: RabbitMQVhost
metadata: {name: sandbox-verify-bus, namespace: $orders_scratch_ns}
spec:
$ref
  deletionPolicy: Delete
EOF
	fi
}

# orders_pending: prints ready when every scratch order is Ready, else
# <Kind> <name>: <failure> of the first that is not. When the read fails, it
# prints the line of the check and returns 1.
orders_pending() {
	local items entry kind name failure
	items=$(orders_read "$orders_scratch_ns") || {
		echo "cannot read the orders of $orders_scratch_ns: $items"
		return 1
	}
	for entry in "${orders_scratch[@]}"; do
		read -r kind _ name <<<"$entry"
		failure=$(jq -r --arg kind "$kind" --arg name "$name" '[.[] | select(.kind == $kind and .name == $name)][0]
			| if . == null then "not found" elif .ready then "" else .failure end' <<<"$items")
		if [ -n "$failure" ]; then
			echo "$kind $name: $failure"
			return 0
		fi
	done
	echo ready
}

# orders_converge: the check orders-converge. It returns 1 when it failed.
orders_converge() {
	local out rc=0
	# A kubectl that fails before it reads the manifest closes the pipe; the
	# write error of the manifest, printed where SIGPIPE is ignored, would
	# land beside the lines of the checks, and kubectl's own error says why.
	if ! out=$(orders_manifest 2>/dev/null | hub_kubectl apply -f - 2>&1); then
		report FAIL orders-converge "cannot order in $orders_scratch_ns: $(_last_line "$out")"
		return 1
	fi
	poll ready 150 orders_pending || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL orders-converge "${polled%%: *} is not Ready after 300 s: ${polled#*: }"
		return 1
		;;
	*)
		report FAIL orders-converge "$polled"
		return 1
		;;
	esac
	out=$(orders_read "$orders_scratch_ns") || {
		report FAIL orders-converge "cannot read the orders of $orders_scratch_ns: $out"
		return 1
	}
	# The namespace also holds the orders of its owner.
	out=$(jq -c '[.[] | select(.name | startswith("sandbox-verify"))]' <<<"$out")
	orders_secrets orders-converge "$out" || return 1
	report ok orders-converge "the ${#orders_scratch[@]} scratch orders in $orders_scratch_ns are Ready with their Secrets"
}

# appcred_keys: reads the id and the secret of the Secret
# sandbox-verify-appcred-credentials into appcred_id and appcred_secret and
# adds them to appcred_values. When it cannot, it sets appcred_failure to the
# line of the check and returns 1.
appcred_keys() {
	local secret name=sandbox-verify-appcred-credentials
	if ! secret=$(_hub_json -n "$orders_scratch_ns" get secret "$name" --ignore-not-found); then
		appcred_failure="cannot read the Secret $orders_scratch_ns/$name: $secret"
		return 1
	fi
	if [ -z "$secret" ]; then
		appcred_failure="the Secret $orders_scratch_ns/$name is missing"
		return 1
	fi
	appcred_id=$(jq -r '.data.application_credential_id // empty | @base64d' <<<"$secret")
	appcred_secret=$(jq -r '.data.application_credential_secret // empty | @base64d' <<<"$secret")
	if [ -z "$appcred_id" ] || [ -z "$appcred_secret" ]; then
		appcred_failure="the Secret $orders_scratch_ns/$name holds no application credential"
		return 1
	fi
	appcred_values+=("$appcred_id" "$appcred_secret")
}

# appcred_status: prints the status of sandbox-verify-appcred as JSON, or the
# line of the failure and returns 1.
appcred_status() {
	local out
	out=$(_hub_json -n "$orders_scratch_ns" get keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred) || {
		echo "cannot read the KeystoneApplicationCredential $orders_scratch_ns/sandbox-verify-appcred: $out"
		return 1
	}
	jq -c '.status // {}' <<<"$out"
}

# appcred_token <id> <secret>: issues a token with the application
# credential. The two values reach openstack through its environment, without
# the user, the password and the scope of the admin; OS_AUTH_URL and
# OS_CACERT stay. It succeeds when openstack prints a token id, and leaves
# the error in errfile.
appcred_token() {
	local out
	out=$(
		unset OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME
		export OS_AUTH_TYPE=v3applicationcredential OS_APPLICATION_CREDENTIAL_ID=$1 OS_APPLICATION_CREDENTIAL_SECRET=$2
		openstack token issue -f value -c id 2>"$errfile"
	) || return 1
	if [ -z "$(_first_line "$out")" ]; then
		echo 'openstack token issue printed no token id' >"$errfile"
		return 1
	fi
}

# appcred_error: prints the first line of the error of the last appcred_token,
# with each value of appcred_values replaced, since Keystone names the id of
# a credential it cannot find.
appcred_error() {
	local line value
	line=$(os_error '')
	for value in "${appcred_values[@]}"; do
		line=${line//"$value"/<redacted>}
	done
	printf '%s\n' "$line"
}

# appcred_switched: prints switched when the Secret holds the credential of
# status.credentialID, else waiting, or the line of a failure and returns 1.
appcred_switched() {
	local status
	status=$(appcred_status) || { echo "$status"; return 1; }
	appcred_keys || { echo "$appcred_failure"; return 1; }
	if [ "$appcred_id" = "$(jq -r '.credentialID // empty' <<<"$status")" ]; then
		echo switched
	else
		echo waiting
	fi
}

# appcred_deleted: prints deleted when status.previousCredentialID is empty,
# else kept, or the line of a failure and returns 1.
appcred_deleted() {
	local status
	status=$(appcred_status) || { echo "$status"; return 1; }
	if [ -z "$(jq -r '.previousCredentialID // empty' <<<"$status")" ]; then
		echo deleted
	else
		echo kept
	fi
}

# orders_rotation: the check orders-rotation, the scheduled rotation of
# Step 7 of upstream's Quick Start (Orders).
orders_rotation() {
	local id1 secret1 status generation previous out error i rc=0
	# Generation 1 authenticates.
	if ! appcred_keys; then
		report FAIL orders-rotation "$appcred_failure"
		return
	fi
	id1=$appcred_id secret1=$appcred_secret
	if ! appcred_token "$id1" "$secret1"; then
		report FAIL orders-rotation "generation 1 does not authenticate: $(appcred_error)"
		return
	fi

	# The schedule mints generation 2 and keeps generation 1 as the previous.
	for ((i = 0; ; i++)); do
		status=$(appcred_status) || {
			report FAIL orders-rotation "$status"
			return
		}
		generation=$(jq -r '.credentialGeneration // 0' <<<"$status")
		previous=$(jq -r '.previousCredentialID // empty' <<<"$status")
		if [ "$generation" -gt 2 ] || { [ "$generation" -eq 2 ] && [ "$previous" != "$id1" ]; }; then
			report FAIL orders-rotation "generation 1 was superseded before verify read generation 2"
			return
		fi
		if [ "$generation" -eq 2 ]; then
			break
		fi
		if [ "$i" -ge 150 ]; then
			report FAIL orders-rotation "sandbox-verify-appcred is at generation $generation after 300 s, expected 2"
			return
		fi
		sleep 2
	done

	# Generation 1 authenticates inside its grace period.
	if ! appcred_token "$id1" "$secret1"; then
		report FAIL orders-rotation "generation 1 is refused inside its grace period: $(appcred_error)"
		return
	fi

	# No generation 3 comes while the rest runs.
	if ! out=$(hub_kubectl -n "$orders_scratch_ns" patch keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred \
		--type merge -p '{"spec":{"rotation":{"interval":"0s"}}}' 2>&1); then
		report FAIL orders-rotation "cannot turn the schedule off: $(_last_line "$out")"
		return
	fi

	# The Secret takes generation 2, which authenticates.
	poll switched 90 appcred_switched || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL orders-rotation "the Secret did not take generation 2 within 180 s"
		return
		;;
	*)
		report FAIL orders-rotation "$polled"
		return
		;;
	esac
	if ! appcred_keys; then
		report FAIL orders-rotation "$appcred_failure"
		return
	fi
	if ! appcred_token "$appcred_id" "$appcred_secret"; then
		report FAIL orders-rotation "generation 2 does not authenticate: $(appcred_error)"
		return
	fi

	# Generation 1 is deleted once its grace period has passed, and refused.
	rc=0
	poll deleted 150 appcred_deleted || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL orders-rotation "generation 1 is not deleted 300 s after the switch"
		return
		;;
	*)
		report FAIL orders-rotation "$polled"
		return
		;;
	esac
	if appcred_token "$id1" "$secret1"; then
		report FAIL orders-rotation "generation 1 still authenticates after its grace period"
		return
	fi
	error=$(appcred_error)
	if [[ $error != *"(HTTP 404)"* && $error != *"(HTTP 401)"* ]]; then
		report FAIL orders-rotation "$error"
		return
	fi
	report ok orders-rotation "sandbox-verify-appcred rotated to generation 2 on its schedule, generation 1 authenticated inside the grace period and was refused after it"
}

# orders_delete: deletes the scratch orders of orders_scratch in
# orders_scratch_ns, in that order, each waiting at most 180 s. It prints the
# first failure, after the other deletes ran, and returns 1.
orders_delete() {
	local entry kind resource name out failure=
	for entry in "${orders_scratch[@]}"; do
		read -r kind resource name <<<"$entry"
		if ! out=$(hub_kubectl -n "$orders_scratch_ns" delete "$resource" "$name" --ignore-not-found --timeout=180s 2>&1) &&
			[ -z "$failure" ]; then
			failure="$kind $name is not deleted after 180 s: $(_last_line "$out")"
		fi
	done
	if [ -n "$failure" ]; then
		printf '%s\n' "$failure"
		return 1
	fi
}

# keystone_left <what> <name> <argument>...: runs openstack with the
# arguments as the admin. When it fails or lists the name, it reports
# orders-teardown as failed and succeeds; otherwise it returns 1.
keystone_left() {
	local out
	if ! out=$(openstack "${@:3}" 2>"$errfile"); then
		report FAIL orders-teardown "$(os_error "$out")"
		return 0
	fi
	if grep -qxF -- "$2" <<<"$out"; then
		report FAIL orders-teardown "the $1 $2 is left in Keystone"
		return 0
	fi
	return 1
}

# orders_teardown: the check orders-teardown.
orders_teardown() {
	local out entry kind name label left
	if ! out=$(orders_delete); then
		report FAIL orders-teardown "$out"
		return
	fi
	for entry in "${orders_scratch[@]}"; do
		read -r kind _ name <<<"$entry"
		label=c5c3.io/${kind,,}
		if ! out=$(_hub_json get "$ORDER_CHILDREN" -A -l "$label-namespace=$orders_scratch_ns,$label-name=$name"); then
			report FAIL orders-teardown "$out"
			return
		fi
		left=$(jq -r '.items[0] // empty | "\(.kind) \(.metadata.namespace // "")/\(.metadata.name)"' <<<"$out")
		if [ -n "$left" ]; then
			report FAIL orders-teardown "$left is left after the teardown"
			return
		fi
	done
	keystone_left user sandbox-verify user list -f value -c Name && return
	keystone_left project sandbox-verify-project project list -f value -c Name && return
	keystone_left service sandbox-verify service list -f value -c Type && return
	report ok orders-teardown "the ${#orders_scratch[@]} scratch orders are gone with their Secrets, their children and their user, project and catalog row"
}

# check_orders: the order checks, after the checks of the services. Without
# a namespace assigned on the management cluster it reports nothing.
check_orders() {
	local id
	orders_namespaces=$(jq -r '[.spec.namespaceAssignments // [] | .[] | select(.targetClusterRef == null) | .namespace] | join(" ")' <<<"$controlplane")
	if [ -z "$orders_namespaces" ]; then
		return 0
	fi
	orders_scratch_ns=$(jq -r 'first(.spec.namespaceAssignments[] | select(.targetClusterRef == null
		and ((.allowedRoles // []) | index("member")) != null and .allowCatalogEntries == true) | .namespace) // empty' <<<"$controlplane")
	# Upstream serves vhost orders on a bus with clusterRef alone.
	orders_refusal=$(jq -r '.spec.infrastructure.messaging as $m
		| if ($m.clusterRef.name // "") != "" then "" elif $m == null then "MessagingNotDeclared" else "MessagingNotManaged" end' <<<"$controlplane")
	orders_scratch=("${ORDER_SCRATCH[@]}")
	if [ -n "$orders_refusal" ]; then
		orders_scratch=("${ORDER_SCRATCH[@]:0:6}")
	fi

	if [ -n "$orders_scratch_ns" ]; then
		orders_delete >/dev/null || :
	fi
	check_orders_ready
	check_orders_secrets
	if [ -z "$orders_scratch_ns" ]; then
		for id in orders-converge orders-rotation orders-teardown; do
			report FAIL "$id" "no namespace assigned on the management cluster allows the role member and catalog entries"
		done
		return
	fi
	if orders_converge; then
		orders_rotation
	else
		report FAIL orders-rotation "the scratch orders did not converge"
	fi
	orders_teardown
}
