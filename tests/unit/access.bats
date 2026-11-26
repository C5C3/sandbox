#!/usr/bin/env bats
# make env and make verify: scripts/env.sh and scripts/verify.sh with docker,
# kind, kubectl, openstack, curl and sleep replaced by exported functions.
# The scripts run from a copy of scripts/, so the .sandbox they read and
# write is the copy's and not the repository's.

bats_require_minimum_version 1.5.0

setup() {
	load helpers
}

PASSWORD='p w$'
CA_PEM='-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIQc2FuZGJveCBjYSBvZiBhIHRlc3Q=
-----END CERTIFICATE-----'
AUTH_URL=https://keystone.172-30-255-10.nip.io/v3

# controlplane <hostname>: writes the ControlPlane of the hub with the
# Keystone hostname.
controlplane() {
	jq -n --arg hostname "$1" '{apiVersion: "c5c3.io/v1alpha1", kind: "ControlPlane",
		metadata: {name: "controlplane", namespace: "openstack"},
		spec: {services: {keystone: {gateway: {hostname: $hostname}}}}}' >"$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# secret <file> <key> <value>: writes a Secret of the hub whose key holds the
# value, base64-encoded as the API server serves it.
secret() {
	jq -n --arg key "$2" --arg value "$(printf '%s' "$3" | base64 -w 0)" \
		'{apiVersion: "v1", kind: "Secret", data: {($key): $value}}' >"$BATS_TEST_TMPDIR/hub/$1"
}

# access_host: a copy of scripts/ with a kubeconfig file for management,
# docker and kind answering for a sandbox-management on the sandbox network,
# and a kubectl that appends its arguments to kubectl.log in the test's
# directory and answers from the files of hub/ there, a missing file as a
# missing object: the four reads of scripts/lib/access.sh, for nova-server
# the reads of the Deployment controlplane-fake-compute and its pods and the
# exec of discover_hosts, and for the compute checks the reads of the CRD of
# NovaCompute, of the NovaComputes, OVNChassis and metadata agents of
# openstack, and of the Hypervisor <node> on sandbox-compute from the files
# novacompute-crd, novacomputes.json, ovnchassis.json, metadataagents.json
# and hypervisor.<node>. The calls of the order checks go to
# fake_hub, under the names orders.<namespace>, secret.<namespace>.<name>,
# apply, appcred, patch, delete.<name> and children.<name>; a patch appends
# its merge patch to patch.log. The hub has the CRD, a ControlPlane with the
# Keystone hostname of AUTH_URL, the admin password PASSWORD and the CA
# CA_PEM. kubectl fails like an unreachable server for the call whose file
# name KUBECTL_FAILS names.
access_host() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig" "$BATS_TEST_TMPDIR/hub"
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	echo '{"kind": "CustomResourceDefinition", "metadata": {"name": "controlplanes.c5c3.io"}}' >"$BATS_TEST_TMPDIR/hub/crd"
	controlplane keystone.172-30-255-10.nip.io
	secret admin.json password "$PASSWORD"
	secret ca.json tls.crt "$CA_PEM"
	kind() {
		case $* in
		"get clusters") echo sandbox-management ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		*) return 1 ;;
		esac
	}
	docker() { echo 'cobaltcore-sandbox '; }
	kubectl() {
		local file
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/kubectl.log"
		case $* in
		*" get crd controlplanes.c5c3.io --ignore-not-found -o json") file=crd ;;
		*" -n openstack get controlplanes.c5c3.io controlplane --ignore-not-found -o json") file=controlplane.json ;;
		*" -n openstack get secret controlplane-keystone-admin-credentials --ignore-not-found -o json") file=admin.json ;;
		*" -n cert-manager get secret sandbox-ca --ignore-not-found -o json") file=ca.json ;;
		*" -n openstack get deployment controlplane-fake-compute --ignore-not-found -o json") file=fake-compute.json ;;
		*" -n openstack get pods -l app.kubernetes.io/name=nova-fake-compute -o json") file=fake-compute-pods.json ;;
		*" -n openstack exec deploy/controlplane-nova-conductor -c conductor -- nova-manage --config-dir /etc/nova/nova.conf.d cell_v2 discover_hosts")
			file=discover-hosts
			;;
		*" get crd novacomputes.nova.openstack.c5c3.io --ignore-not-found -o json") file=novacompute-crd ;;
		*" -n openstack get novacomputes.nova.openstack.c5c3.io -o json") file=novacomputes.json ;;
		*" -n openstack get ovnchassis.ovn.openstack.c5c3.io -o json") file=ovnchassis.json ;;
		*" -n openstack get neutronmetadataagents.neutron.openstack.c5c3.io -o json") file=metadataagents.json ;;
		*" get hypervisors.kvm.cloud.sap "*" --ignore-not-found -o json") file=hypervisor.$5 ;;
		# The arguments after --kubeconfig <file>: -n <namespace> <verb> ...,
		# or get <resources> -A -l <selector> for the children.
		*" get keystoneusers.c5c3.io,keystoneprojects.c5c3.io,keystoneroleassignments.c5c3.io,keystonecatalogentries.c5c3.io,keystoneapplicationcredentials.c5c3.io,mariadbdatabases.c5c3.io,rabbitmqvhosts.c5c3.io -o json")
			file=orders.$4
			;;
		*" get secret "*"-credentials --ignore-not-found -o json") file=secret.$4.$7 ;;
		*" apply -f -") file=apply ;;
		*" get keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred -o json") file=appcred ;;
		*" patch keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred --type merge -p "*) file=patch ;;
		*" delete "*" --ignore-not-found --timeout=180s") file=delete.$7 ;;
		*" get secrets,"*" -A -l "*" -o json") file=children.${7##*-name=} ;;
		*)
			echo "unexpected kubectl $*" >&2
			return 1
			;;
		esac
		if [ "$file" = "${KUBECTL_FAILS:-}" ]; then
			printf 'E1125 memcache.go\nThe connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?\n' >&2
			return 1
		fi
		case $file in
		orders.* | secret.* | apply | appcred | patch | delete.* | children.*)
			fake_hub "$file" "$@"
			return
			;;
		esac
		if [ -f "$BATS_TEST_TMPDIR/hub/$file" ]; then
			cat -- "$BATS_TEST_TMPDIR/hub/$file"
		fi
	}
	export -f kind docker kubectl fake_hub fake_apply fake_rotation fake_mint fake_retire fake_delete
}

# The fake hub of the orders lives in hub/orders/ of the test's directory:
# orders.json, secrets.json and children.json hold the orders, the delivered
# Secrets and the labelled children of every namespace as JSON arrays, and
# keystone the application credentials that Keystone accepts, one line
# "<id> <secret>" each. An application credential <name> has the id
# id-<name>-<generation> and the secret S3cr3t-<name>-<generation>.

# fake_hub <call> <argument of kubectl>...: answers the call of the order
# checks that access_host named. A list of orders holds those of the
# namespace, in the order verify.sh names the resources; the label query
# finds Secrets and children.
fake_hub() {
	local call=$1 dir=$BATS_TEST_TMPDIR/hub/orders n file
	shift
	mkdir -p -- "$dir"
	for file in orders secrets children; do
		[ -f "$dir/$file.json" ] || echo '[]' >"$dir/$file.json"
	done
	case $call in
	orders.*)
		jq --arg ns "${call#orders.}" '{apiVersion: "v1", kind: "List", items: map(select(.metadata.namespace == $ns))
			| sort_by(.kind | {KeystoneUser: 0, KeystoneProject: 1, KeystoneRoleAssignment: 2, KeystoneCatalogEntry: 3,
				KeystoneApplicationCredential: 4, MariaDBDatabase: 5, RabbitMQVhost: 6}[.])}' "$dir/orders.json"
		;;
	secret.*)
		jq --arg ns "$4" --arg name "$7" 'map(select(.metadata.namespace == $ns and .metadata.name == $name))[0] // empty' "$dir/secrets.json"
		;;
	apply)
		n=$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'applied.*.yaml' | wc -l)
		cat >"$BATS_TEST_TMPDIR/applied.$((n + 1)).yaml"
		fake_apply <"$BATS_TEST_TMPDIR/applied.$((n + 1)).yaml"
		;;
	appcred) fake_rotation "$4" ;;
	patch)
		printf '%s\n' "${11}" >>"$BATS_TEST_TMPDIR/patch.log"
		: >"$dir/patched"
		;;
	delete.*) fake_delete "$4" "$6" "$7" ;;
	children.*)
		jq -s --arg selector "$7" '($selector | split(",") | map(split("=") | {key: .[0], value: .[1]}) | from_entries) as $want
			| {apiVersion: "v1", kind: "List", items: (add | map(select(.metadata.labels as $l | $want | to_entries | all(.value == $l[.key]))))}' \
			"$dir/secrets.json" "$dir/children.json"
		;;
	esac
}

# fake_apply: the operator of the fake hub. It applies the orders of the YAML
# stream on stdin. Each gets the uid uid-<name> and turns Ready with the
# sub-condition of its kind, or not Ready with reason Provisioning when
# NOT_READY names it; a Ready one gets its Secret <name>-credentials. A
# RabbitMQVhost on a bus of the ControlPlane without clusterRef reports
# MessagingNotManaged, or MessagingNotDeclared without a messaging block,
# and gets no Secret. Every order gets one labelled child in openstack. An
# application credential starts at generation 1, which Keystone accepts.
fake_apply() {
	local dir=$BATS_TEST_TMPDIR/hub/orders file out
	mkdir -p -- "$dir"
	for file in orders secrets children; do
		[ -f "$dir/$file.json" ] || echo '[]' >"$dir/$file.json"
	done
	out=$(yq -o=json -I=0 ea '[.]' - | jq -c --arg notready "${NOT_READY:-}" --slurpfile cp "$BATS_TEST_TMPDIR/hub/controlplane.json" '
		def sub: {KeystoneUser: "UserReady", KeystoneProject: "ProjectReady", KeystoneRoleAssignment: "AssignmentReady",
			KeystoneCatalogEntry: "CatalogReady", KeystoneApplicationCredential: "CredentialReady",
			MariaDBDatabase: "DatabaseReady", RabbitMQVhost: "VhostReady"}[.kind];
		def keys: {KeystoneUser: ["clouds.yaml", "password"],
			KeystoneApplicationCredential: ["clouds.yaml", "application_credential_id", "application_credential_secret"],
			MariaDBDatabase: ["host", "port", "database", "username", "password"],
			RabbitMQVhost: ["transport_url", "host", "port", "username", "password", "vhost"]}[.kind] // [];
		def child: {KeystoneUser: "User", KeystoneProject: "Project", KeystoneRoleAssignment: "RoleAssignment",
			KeystoneCatalogEntry: "Service", KeystoneApplicationCredential: "ApplicationCredential",
			MariaDBDatabase: "Database", RabbitMQVhost: "Vhost"}[.kind];
		def labels: ("c5c3.io/" + (.kind | ascii_downcase)) as $k
			| {($k + "-namespace"): .metadata.namespace, ($k + "-name"): .metadata.name};
		$cp[0].spec.infrastructure.messaging as $m
		| (if ($m.clusterRef.name // "") != "" then null elif $m == null then "MessagingNotDeclared" else "MessagingNotManaged" end) as $refusal
		| [.[] | .metadata.uid = "uid-" + .metadata.name
			| .status.conditions = (if .kind == "RabbitMQVhost" and $refusal != null then
					[{type: "VhostReady", status: "False", reason: $refusal}, {type: "DeliveryReady", status: "False", reason: $refusal},
					 {type: "Ready", status: "False", reason: "NotAllReady"}]
				elif .metadata.name == $notready then
					[{type: sub, status: "False", reason: "Provisioning"}, {type: "Ready", status: "False", reason: "NotAllReady"}]
				else [{type: sub, status: "True", reason: "Provisioned"}, {type: "Ready", status: "True", reason: "AllReady"}] end)
			| if .kind == "KeystoneApplicationCredential"
				then .status += {credentialGeneration: 1, credentialID: ("id-" + .metadata.name + "-1")} else . end] as $orders
		| {orders: $orders,
		   secrets: [$orders[] | select(.status.conditions[-1].status == "True" and (keys | length) > 0) | . as $o
			| {apiVersion: "v1", kind: "Secret",
			   metadata: {name: (.metadata.name + "-credentials"), namespace: .metadata.namespace, labels: labels,
				ownerReferences: [{apiVersion: "c5c3.io/v1alpha1", kind: .kind, name: .metadata.name, uid: .metadata.uid, controller: true}]},
			   data: (keys | map({key: ., value: (if . == "application_credential_id" then $o.status.credentialID
				elif . == "application_credential_secret" then "S3cr3t-" + $o.metadata.name + "-1"
				else . + "-of-" + $o.metadata.name end | @base64)}) | from_entries)}],
		   children: [$orders[] | {apiVersion: "v1", kind: child, metadata: {name: .metadata.name, namespace: "openstack", labels: labels}}],
		   keystone: [$orders[] | select(.kind == "KeystoneApplicationCredential") | "\(.status.credentialID) S3cr3t-\(.metadata.name)-1"]}')
	for file in orders secrets children; do
		jq --argjson new "$(jq -c ".$file" <<<"$out")" 'map(. as $x | select($new | any(.kind == $x.kind
			and .metadata.namespace == $x.metadata.namespace and .metadata.name == $x.metadata.name) | not)) + $new' \
			"$dir/$file.json" >"$dir/$file.new"
		mv -- "$dir/$file.new" "$dir/$file.json"
	done
	jq -r '.keystone[]' <<<"$out" >>"$dir/keystone"
}

# fake_mint <namespace> <generation> <previous id>: gives
# sandbox-verify-appcred the generation and the previous id. Keystone accepts
# the new credential, and the Secret takes it unless ROTATION is secret-lag.
fake_mint() {
	local dir=$BATS_TEST_TMPDIR/hub/orders name=sandbox-verify-appcred
	jq --arg ns "$1" --arg name "$name" --argjson generation "$2" --arg previous "$3" '
		map(if .metadata.namespace == $ns and .metadata.name == $name then .status += {credentialGeneration: $generation,
			credentialID: "id-\($name)-\($generation)", previousCredentialID: $previous} else . end)' "$dir/orders.json" >"$dir/orders.new"
	mv -- "$dir/orders.new" "$dir/orders.json"
	printf 'id-%s-%s S3cr3t-%s-%s\n' "$name" "$2" "$name" "$2" >>"$dir/keystone"
	if [ "${ROTATION:-}" != secret-lag ]; then
		jq --arg ns "$1" --arg name "$name-credentials" --arg id "id-$name-$2" --arg secret "S3cr3t-$name-$2" '
			map(if .metadata.namespace == $ns and .metadata.name == $name then .data += {application_credential_id: ($id | @base64),
				application_credential_secret: ($secret | @base64)} else . end)' "$dir/secrets.json" >"$dir/secrets.new"
		mv -- "$dir/secrets.new" "$dir/secrets.json"
	fi
}

# fake_retire <namespace>: ends the grace period of generation 1 of
# sandbox-verify-appcred: the previous id is gone from the status and,
# unless GEN1_ALIVE is set, from Keystone.
fake_retire() {
	local dir=$BATS_TEST_TMPDIR/hub/orders name=sandbox-verify-appcred
	jq --arg ns "$1" --arg name "$name" 'map(if .metadata.namespace == $ns and .metadata.name == $name
		then del(.status.previousCredentialID) else . end)' "$dir/orders.json" >"$dir/orders.new"
	mv -- "$dir/orders.new" "$dir/orders.json"
	if [ -z "${GEN1_ALIVE:-}" ]; then
		grep -v "^id-$name-1 " "$dir/keystone" >"$dir/keystone.new" || :
		mv -- "$dir/keystone.new" "$dir/keystone"
	fi
}

# fake_rotation <namespace>: prints sandbox-verify-appcred after the schedule
# moved it on, by the number of reads. With ROTATION unset, secret-lag or
# kept, generation 2 comes at the second read, and generation 1 retires at
# the third read after the patch, except with kept. With stuck nothing
# changes; with skipped the first read finds generation 3, and with foreign
# the second finds generation 2 after a credential verify did not read.
fake_rotation() {
	local dir=$BATS_TEST_TMPDIR/hub/orders reads after=0
	reads=$(($(cat "$dir/reads" 2>/dev/null || echo 0) + 1))
	echo "$reads" >"$dir/reads"
	if [ -f "$dir/patched" ]; then
		after=$(($(cat "$dir/after" 2>/dev/null || echo 0) + 1))
		echo "$after" >"$dir/after"
	fi
	case ${ROTATION:-} in
	stuck) ;;
	skipped) [ "$reads" -ne 1 ] || fake_mint "$1" 3 id-sandbox-verify-appcred-2 ;;
	foreign) [ "$reads" -ne 2 ] || fake_mint "$1" 2 id-sandbox-verify-appcred-0 ;;
	*)
		[ "$reads" -ne 2 ] || fake_mint "$1" 2 id-sandbox-verify-appcred-1
		if [ "$after" -eq 3 ] && [ "${ROTATION:-}" != kept ]; then
			fake_retire "$1"
		fi
		;;
	esac
	jq --arg ns "$1" 'map(select(.metadata.namespace == $ns and .metadata.name == "sandbox-verify-appcred"))[0] // empty' "$dir/orders.json"
}

# fake_delete <namespace> <resource> <name>: deletes the order with its Secret
# and its children, except a child of the order LEFT_CHILD names, and for
# sandbox-verify-appcred what fake_rotation counted. For the order
# DELETE_TIMES_OUT names it fails as kubectl does after --timeout.
fake_delete() {
	local dir=$BATS_TEST_TMPDIR/hub/orders kind file
	if [ "$3" = "${DELETE_TIMES_OUT:-}" ]; then
		echo "error: timed out waiting for the condition on $2/$3" >&2
		return 1
	fi
	if [ "$3" = sandbox-verify-appcred ]; then
		rm -f -- "$dir/reads" "$dir/after" "$dir/patched"
	fi
	kind=$(jq -rn --arg resource "$2" '{"keystoneusers.c5c3.io": "KeystoneUser", "keystoneprojects.c5c3.io": "KeystoneProject",
		"keystoneroleassignments.c5c3.io": "KeystoneRoleAssignment", "keystonecatalogentries.c5c3.io": "KeystoneCatalogEntry",
		"keystoneapplicationcredentials.c5c3.io": "KeystoneApplicationCredential", "mariadbdatabases.c5c3.io": "MariaDBDatabase",
		"rabbitmqvhosts.c5c3.io": "RabbitMQVhost"}[$resource]')
	for file in orders secrets children; do
		[ -f "$dir/$file.json" ] || continue
		jq --arg ns "$1" --arg kind "$kind" --arg name "$3" --arg left "${LEFT_CHILD:-}" '
			("c5c3.io/" + ($kind | ascii_downcase)) as $k
			| map(select((.kind == $kind and .metadata.namespace == $ns and .metadata.name == $name)
				or (.metadata.labels[$k + "-namespace"] == $ns and .metadata.labels[$k + "-name"] == $name
					and (.kind == "Secret" or $name != $left)) | not))' "$dir/$file.json" >"$dir/$file.new"
		mv -- "$dir/$file.new" "$dir/$file.json"
	done
}

# openstack_logs: replaces openstack with a function that appends its
# arguments to openstack.log in the test's directory and answers every call
# of verify.sh as a healthy cloud does: token issue with a token, or with
# TOKEN_ERROR on stderr and status 1 when it is set; catalog list with
# catalog.json; compute service list -f json with services.json; a create
# with the id id-<name>, an image create after it writes the size of the file
# of --file to image-size.<name> in the test's directory; the status of the
# image sandbox-verify-image, of the image sandbox-verify-boot, of the
# network, the volume, the compute service and the server with IMAGE_STATUS,
# BOOT_STATUS, NETWORK_STATUS, VOLUME_STATUS, COMPUTE_STATE and
# SERVER_STATUS, which default to the healthy one; resource class list with
# CLASSES; secret get with PAYLOAD; the fault of the server with FAULT; the
# leftover secrets with the hrefs of SECRET_LEFTOVERS; a delete with nothing.
# As openstack 6.6.0 does, it refuses a server create with --nic none
# without --os-compute-api-version 2.37, and with SERVER_ABSENT set a server
# show of sandbox-verify-server fails as for a server that does not exist. A
# call whose arguments match the pattern STUB_FAILS prints STUB_ERROR, by
# default an unreachable endpoint, on stderr and fails, and one that matches
# STUB_SILENT prints nothing. A token issue with OS_AUTH_TYPE
# v3applicationcredential goes to stub_appcred_token, and user list, project
# list and service list print KEYSTONE_USERS, KEYSTONE_PROJECTS and
# KEYSTONE_SERVICES, which default to the rows the orders leave. For the
# compute checks it prints network agent list with agents.json, the
# aggregate sandbox with aggregate.json, the MTU of
# sandbox-verify-compute-net with COMPUTE_MTU, the status and the host of
# sandbox-verify-compute-server with COMPUTE_SERVER_STATUS and
# COMPUTE_SERVER_HOST, its console log with console.log, and its noVNC URL
# with the token CONSOLE_TOKEN. The names do not start with OS_, which
# verify.sh unsets.
openstack_logs() {
	openstack() {
		local arg prev=
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/openstack.log"
		if [[ ${OS_AUTH_TYPE:-} == v3applicationcredential && $* == "token issue -f value -c id" ]]; then
			stub_appcred_token
			return
		fi
		# shellcheck disable=SC2053 # STUB_FAILS and STUB_SILENT are patterns.
		if [[ -n ${STUB_FAILS:-} && $* == $STUB_FAILS ]]; then
			printf '%s\n' "${STUB_ERROR:-Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens}" >&2
			return 1
		elif [[ -n ${STUB_SILENT:-} && $* == $STUB_SILENT ]]; then
			return 0
		elif [[ -n ${SERVER_ABSENT:-} && $* == "server show sandbox-verify-server "* ]]; then
			echo 'No Server found for sandbox-verify-server' >&2
			return 1
		fi
		case $* in
		"token issue -f value -c id")
			if [ -n "${TOKEN_ERROR:-}" ]; then
				printf '%s\n' "$TOKEN_ERROR" >&2
				return 1
			fi
			echo gAAAAABsandboxtoken
			;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		"image show id-sandbox-verify-image -f value -c status") echo "${IMAGE_STATUS:-active}" ;;
		"image show id-sandbox-verify-boot -f value -c status") echo "${BOOT_STATUS:-active}" ;;
		"resource class list -f value -c name")
			printf '%s\n' "${CLASSES:-VCPU
MEMORY_MB
DISK_GB
PCI_DEVICE
IPV4_ADDRESS}"
			;;
		"secret list --name sandbox-verify-secret -f value -c Secret href") printf '%s' "${SECRET_LEFTOVERS:-}" ;;
		"secret store --name sandbox-verify-secret --payload sandbox-verify-payload -f value -c Secret href")
			echo https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe
			;;
		"secret get -p https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe -f value -c Payload")
			echo "${PAYLOAD:-sandbox-verify-payload}"
			;;
		"network show id-sandbox-verify-net -f value -c status") echo "${NETWORK_STATUS:-ACTIVE}" ;;
		"volume show id-sandbox-verify-volume -f value -c status") echo "${VOLUME_STATUS:-available}" ;;
		"compute service list -f json") cat -- "$BATS_TEST_TMPDIR/services.json" ;;
		"compute service list --service nova-compute --host sandbox-management-control-plane -f value -c State")
			echo "${COMPUTE_STATE:-up}"
			;;
		"user list -f value -c Name") printf '%s\n' ${KEYSTONE_USERS:-admin workflow} ;;
		"project list -f value -c Name") printf '%s\n' ${KEYSTONE_PROJECTS:-admin service workflow-project} ;;
		"service list -f value -c Type") printf '%s\n' ${KEYSTONE_SERVICES:-identity image dns} ;;
		"server show sandbox-verify-server -f value -c status") echo "${SERVER_STATUS:-ACTIVE}" ;;
		"server show "*" -f json -c fault")
			jq -n --arg message "${FAULT:-}" '{fault: {code: 500, created: "2026-11-25T10:00:00Z", message: $message}}'
			;;
		"network agent list -f json") cat -- "$BATS_TEST_TMPDIR/agents.json" ;;
		"aggregate show sandbox -f json -c hosts") cat -- "$BATS_TEST_TMPDIR/aggregate.json" ;;
		"network show id-sandbox-verify-compute-net -f value -c mtu") echo "${COMPUTE_MTU:-1442}" ;;
		"image show cirros-kvm -f value -c id") echo 5a9c1d2e-cirros ;;
		"flavor show 1 -f value -c id") echo 1 ;;
		"server show sandbox-verify-compute-server -f json -c status -c OS-EXT-SRV-ATTR:host")
			jq -n --arg status "${COMPUTE_SERVER_STATUS:-ACTIVE}" --arg host "${COMPUTE_SERVER_HOST:-sandbox-compute-worker}" \
				'{status: $status, "OS-EXT-SRV-ATTR:host": $host}'
			;;
		"console log show sandbox-verify-compute-server") cat -- "$BATS_TEST_TMPDIR/console.log" ;;
		"console url show --novnc sandbox-verify-compute-server -f value -c url")
			echo "https://nova-console.172-30-255-10.nip.io/vnc_lite.html?path=%3Ftoken%3D$CONSOLE_TOKEN"
			;;
		"image create "*)
			for arg; do
				if [ "$prev" = --file ]; then
					stat -c %s -- "$arg" >"$BATS_TEST_TMPDIR/image-size.${!#}"
				fi
				prev=$arg
			done
			printf 'id-%s\n' "${!#}"
			;;
		"server create "*" --nic none "*)
			echo '--os-compute-api-version 2.37 or greater is required to support explicit auto-allocation of a network or to disable network allocation' >&2
			return 1
			;;
		*" create "*) printf 'id-%s\n' "${!#}" ;;
		*" delete "*) : ;;
		*)
			echo "unexpected openstack $*" >&2
			return 1
			;;
		esac
	}
	export -f openstack stub_appcred_token
}

# stub_appcred_token: the answer of the openstack stub to a token issue by
# application credential. It appends the names of the OS_ variables of its
# environment and the id to appcred.log in the test's directory, one line
# per call. The call APPCRED_FAILS counts prints APPCRED_ERROR, by default an
# unreachable endpoint, and fails. Otherwise it prints a token when Keystone
# of the fake hub accepts the id and the secret, and else fails as Keystone
# does for a deleted credential, naming its id, or with HTTP 401 when
# GEN1_REFUSAL is 401.
stub_appcred_token() {
	local n
	n=$(($(grep -c '' "$BATS_TEST_TMPDIR/appcred.log" 2>/dev/null || :) + 1))
	printf '%s %s\n' "$(env | sed -n 's/^\(OS_[A-Z_]*\)=.*/\1/p' | LC_ALL=C sort | paste -sd ' ')" \
		"$OS_APPLICATION_CREDENTIAL_ID" >>"$BATS_TEST_TMPDIR/appcred.log"
	if [ "$n" = "${APPCRED_FAILS:-}" ]; then
		printf '%s\n' "${APPCRED_ERROR:-Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens}" >&2
		return 1
	fi
	if grep -qxF -- "$OS_APPLICATION_CREDENTIAL_ID $OS_APPLICATION_CREDENTIAL_SECRET" "$BATS_TEST_TMPDIR/hub/orders/keystone"; then
		echo gAAAAABappcredtoken
	elif [ "${GEN1_REFUSAL:-}" = 401 ]; then
		echo 'The request you have made requires authentication. (HTTP 401) (Request-ID: req-401)' >&2
		return 1
	else
		echo "Could not find Application Credential: $OS_APPLICATION_CREDENTIAL_ID. (HTTP 404) (Request-ID: req-404)" >&2
		return 1
	fi
}

# catalog_with <url>: writes the catalog of openstack 6.6.0 under -f json,
# with the identity service at the public URL and an internal endpoint.
catalog_with() {
	jq -n --arg url "$1" '[{Name: "keystone", Type: "identity", Endpoints: [
		{id: "a1", interface: "internal", region_id: "RegionOne", url: "http://keystone-api.openstack.svc/v3", region: "RegionOne"},
		{id: "a2", interface: "public", region_id: "RegionOne", url: $url, region: "RegionOne"}]}]' >"$BATS_TEST_TMPDIR/catalog.json"
}

# controlplane_services <service>...: writes the ControlPlane of the hub with
# the services in the order given, each published by the Gateway
# openstack-gw at <service>.172-30-255-10.nip.io.
controlplane_services() {
	jq -n '{apiVersion: "c5c3.io/v1alpha1", kind: "ControlPlane",
		metadata: {name: "controlplane", namespace: "openstack"},
		spec: {services: ($ARGS.positional | map({key: ., value: {gateway: {parentRef: {name: "openstack-gw"},
			hostname: (. + ".172-30-255-10.nip.io")}}}) | from_entries)}}' --args "$@" >"$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# hub_edit <jq filter>: changes the ControlPlane of the hub with the filter.
hub_edit() {
	jq "$1" "$BATS_TEST_TMPDIR/hub/controlplane.json" >"$BATS_TEST_TMPDIR/cp.json"
	mv -- "$BATS_TEST_TMPDIR/cp.json" "$BATS_TEST_TMPDIR/hub/controlplane.json"
}

# catalog_edit <jq filter>: changes catalog.json with the filter.
catalog_edit() {
	jq "$1" "$BATS_TEST_TMPDIR/catalog.json" >"$BATS_TEST_TMPDIR/c.json"
	mv -- "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/catalog.json"
}

# healthy_catalog: writes the catalog of the eight services, each with an
# internal endpoint and a public one at its Gateway, Cinder and Nova with
# the version that their registration appends.
healthy_catalog() {
	jq -n --arg auth "$AUTH_URL" '
		def service($name; $type; $public; $internal): {Name: $name, Type: $type, Endpoints: [
			{id: ($name + "-internal"), interface: "internal", region_id: "RegionOne", url: $internal, region: "RegionOne"},
			{id: ($name + "-public"), interface: "public", region_id: "RegionOne", url: $public, region: "RegionOne"}]};
		[service("keystone"; "identity"; $auth; "http://keystone-api.openstack.svc/v3"),
		service("glance"; "image"; "https://glance.172-30-255-10.nip.io"; "http://controlplane-glance.openstack.svc:9292"),
		service("placement"; "placement"; "https://placement.172-30-255-10.nip.io"; "http://controlplane-placement.openstack.svc:8778"),
		service("barbican"; "key-manager"; "https://barbican.172-30-255-10.nip.io"; "http://controlplane-barbican.openstack.svc:9311"),
		service("neutron"; "network"; "https://neutron.172-30-255-10.nip.io"; "http://controlplane-neutron.openstack.svc:9696"),
		service("cinder"; "block-storage"; "https://cinder.172-30-255-10.nip.io/v3"; "http://controlplane-cinder.openstack.svc:8776/v3"),
		service("nova"; "compute"; "https://nova.172-30-255-10.nip.io/v2.1"; "http://controlplane-nova.openstack.svc:8774/v2.1")]' >"$BATS_TEST_TMPDIR/catalog.json"
}

# compute_services <state of the scheduler> <state of the conductor>: writes
# services.json, the compute services of openstack 6.6.0 under -f json, with
# a nova-scheduler and a nova-conductor in the states given and a
# nova-scheduler of a replaced pod that is down.
compute_services() {
	jq -n --arg scheduler "$1" --arg conductor "$2" '[
		{ID: "1", Binary: "nova-scheduler", Host: "controlplane-nova-scheduler-5b7d9-old", Zone: "internal", Status: "enabled", State: "down", "Updated At": "2026-11-25T09:00:00.000000"},
		{ID: "2", Binary: "nova-scheduler", Host: "controlplane-nova-scheduler-5b7d9-x2k4p", Zone: "internal", Status: "enabled", State: $scheduler, "Updated At": "2026-11-25T10:00:00.000000"},
		{ID: "3", Binary: "nova-conductor", Host: "controlplane-nova-conductor-6c8f4-q7r2s", Zone: "internal", Status: "enabled", State: $conductor, "Updated At": "2026-11-25T10:00:00.000000"}]' >"$BATS_TEST_TMPDIR/services.json"
}

# login_page: writes the login page of the dashboard that the curl stub
# serves: a hidden input before the form, and in the form three hidden
# inputs in double, single and no quotes, with their attributes in other
# orders and one over two lines, beside the visible inputs.
login_page() {
	cat >"$BATS_TEST_TMPDIR/login.html" <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Login - OpenStack Dashboard</title></head>
<body>
<input type="hidden" name="outside" value="not-of-the-form">
<form id="" class="ng-pristine ng-valid" method="POST" action="/auth/login/" autocomplete="off">
<input type="hidden" name="csrfmiddlewaretoken" value="Zx9pQcsrfTokenOfTheForm">
<input name='region' type='hidden' value='default' id='id_region'>
<input id="id_next" value="/project/" type=hidden
  name="next" />
<input style="display:none" type="text" name="fake_email" value="" />
<input style="display:none" type="password" name="fake_password" value="" />
<input class="form-control" id="id_username" name="username" type="text" autofocus="autofocus" />
<input class="form-control" id="id_password" name="password" type="password" />
</form>
</body>
</html>
EOF
}

# curl_logs: replaces curl with a function that appends its arguments to
# curl.log in the test's directory, one per line and each call closed by a
# line --, and copies the file of --data-urlencode password@<file> to
# posted-password, with its mode in posted-password.mode and its path in
# posted-password.path. It answers as the dashboard of a healthy cloud
# does: a call without data writes login.html to the file of --output, and
# a call with data prints, as --write-out '%{http_code} %{url_effective}'
# does, the status HORIZON_STATUS, 200 by default, and the URL of the path
# HORIZON_PATH, /project/ by default. A call for a URL of nova-console prints
# the status CONSOLE_STATUS, 200 by default. With CURL_ERROR set it prints it
# on stderr and fails as curl does.
curl_logs() {
	curl() {
		local arg prev= output= data=
		{
			printf '%s\n' "$@"
			echo --
		} >>"$BATS_TEST_TMPDIR/curl.log"
		for arg; do
			case $prev in
			--output) output=$arg ;;
			--data-urlencode)
				data=1
				if [[ $arg == password@* ]]; then
					cp -- "${arg#password@}" "$BATS_TEST_TMPDIR/posted-password"
					stat -c %a -- "${arg#password@}" >"$BATS_TEST_TMPDIR/posted-password.mode"
					printf '%s\n' "${arg#password@}" >"$BATS_TEST_TMPDIR/posted-password.path"
				fi
				;;
			esac
			prev=$arg
		done
		if [ -n "${CURL_ERROR:-}" ]; then
			printf '%s\n' "$CURL_ERROR" >&2
			return 60
		fi
		if [[ ${!#} == https://nova-console.* ]]; then
			printf '%s' "${CONSOLE_STATUS:-200}"
		elif [ -z "$data" ]; then
			cat -- "$BATS_TEST_TMPDIR/login.html" >"$output"
		else
			echo '<html><title>Instance Overview - OpenStack Dashboard</title></html>' >"$output"
			printf '%s https://horizon.172-30-255-10.nip.io%s' "${HORIZON_STATUS:-200}" "${HORIZON_PATH:-/project/}"
		fi
	}
	export -f curl
}

# curl_call <n>: prints the arguments of the n-th call of curl, one per line.
curl_call() {
	awk -v n="$1" '$0 == "--" { call++; next } call == n - 1' "$BATS_TEST_TMPDIR/curl.log"
}

# healthy_cloud: access_host, openstack_logs and curl_logs with a hub and a
# cloud that pass every check of verify.sh. The ControlPlane declares the
# eight services in the reverse of the order of the checks, the catalog
# publishes each at its hostname, the scheduler and the conductor are up,
# the Deployment controlplane-fake-compute has a pod on
# sandbox-management-control-plane, and discover_hosts succeeds. sleep
# returns at once and appends its argument to sleep.log.
healthy_cloud() {
	access_host
	controlplane_services horizon nova cinder neutron barbican placement glance keystone
	healthy_catalog
	compute_services up up
	echo '{"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "controlplane-fake-compute", "namespace": "openstack"}}' \
		>"$BATS_TEST_TMPDIR/hub/fake-compute.json"
	jq -n '{apiVersion: "v1", kind: "List", items: [{apiVersion: "v1", kind: "Pod",
		metadata: {name: "controlplane-fake-compute-7d9f8-m4n6t", namespace: "openstack"},
		spec: {nodeName: "sandbox-management-control-plane"}}]}' >"$BATS_TEST_TMPDIR/hub/fake-compute-pods.json"
	echo 'Found 1 cell mappings.' >"$BATS_TEST_TMPDIR/hub/discover-hosts"
	login_page
	openstack_logs
	curl_logs
	sleep() { printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/sleep.log"; }
	export -f sleep
}

# orders_cloud: healthy_cloud with a ControlPlane on the managed bus
# openstack-rabbitmq that assigns workflow with the role member and catalog
# entries, and the seven orders of orders/workflow/orders.yaml applied to an
# empty fake hub, Ready with their four Secrets. It removes the logs of an
# earlier run in the same test.
orders_cloud() {
	rm -rf -- "$BATS_TEST_TMPDIR/hub/orders" "$BATS_TEST_TMPDIR"/applied.*.yaml
	rm -f -- "$BATS_TEST_TMPDIR"/{kubectl,openstack,appcred,patch,sleep,curl}.log
	healthy_cloud
	hub_edit '.spec.infrastructure.messaging = {clusterRef: {name: "openstack-rabbitmq"}}
		| .spec.namespaceAssignments = [{namespace: "workflow", allowedRoles: ["member"], allowCatalogEntries: true}]'
	fake_apply <"$SANDBOX_ROOT/orders/workflow/orders.yaml"
}

# The console token of the noVNC URL of sandbox-verify-compute-server.
CONSOLE_TOKEN=7c1e5a0f-console-token-of-sandbox-verify

# compute_parts: adds to the hub and the cloud of the test the compute pool
# of the module compute-pool on sandbox-compute, which kind lists beside
# sandbox-management with a kubeconfig file: the CRD of NovaCompute, the
# pool lab Ready with the node sandbox-compute-worker Active, up and enabled
# in the zone sandbox, the OVNChassis lab-chassis and the
# NeutronMetadataAgent lab-metadata-agent Ready, the Hypervisor of the node
# onboarded, the two agents alive on it, the aggregate sandbox with the node,
# the console proxy of Nova at nova-console.172-30-255-10.nip.io and the
# console log in which cirros read its instance id. openssl appends its
# arguments to openssl.log in the test's directory, copies its stdin to
# openssl.stdin and answers the WebSocket upgrade with the status line
# WS_STATUS, 101 by default, and a server frame with RFB_GREETING, an RFB
# greeting by default.
compute_parts() {
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/compute.yaml"
	echo '{"kind": "CustomResourceDefinition", "metadata": {"name": "novacomputes.nova.openstack.c5c3.io"}}' >"$BATS_TEST_TMPDIR/hub/novacompute-crd"
	jq -n '{apiVersion: "v1", kind: "List", items: [{apiVersion: "nova.openstack.c5c3.io/v1alpha1", kind: "NovaCompute",
		metadata: {name: "lab", namespace: "openstack"}, spec: {targetClusterRef: {name: "sandbox-compute"}},
		status: {conditions: [{type: "Ready", status: "True", reason: "AllReady", message: "All eight sub-conditions are True"}],
			nodes: [{name: "sandbox-compute-worker", phase: "Active", zone: "sandbox", serviceState: "up", serviceStatus: "enabled"}]}}]}' \
		>"$BATS_TEST_TMPDIR/hub/novacomputes.json"
	jq -n '{apiVersion: "v1", kind: "List", items: [{apiVersion: "ovn.openstack.c5c3.io/v1alpha1", kind: "OVNChassis",
		metadata: {name: "lab-chassis", namespace: "openstack"}, spec: {targetClusterRef: {name: "sandbox-compute"}},
		status: {conditions: [{type: "Ready", status: "True", reason: "Ready", message: "chassis ready"}]}}]}' \
		>"$BATS_TEST_TMPDIR/hub/ovnchassis.json"
	jq -n '{apiVersion: "v1", kind: "List", items: [{apiVersion: "neutron.openstack.c5c3.io/v1alpha1", kind: "NeutronMetadataAgent",
		metadata: {name: "lab-metadata-agent", namespace: "openstack"}, spec: {targetClusterRef: {name: "sandbox-compute"}},
		status: {conditions: [{type: "Ready", status: "True", reason: "Ready", message: "agent ready"}]}}]}' \
		>"$BATS_TEST_TMPDIR/hub/metadataagents.json"
	hypervisor_reason Succeeded
	jq -n '[{ID: "a1", "Agent Type": "OVN Controller agent", Host: "sandbox-compute-worker", "Availability Zone": "", Alive: true, State: true, Binary: "ovn-controller"},
		{ID: "a2", "Agent Type": "OVN Metadata agent", Host: "sandbox-compute-worker", "Availability Zone": "", Alive: true, State: true, Binary: "neutron-ovn-metadata-agent"}]' \
		>"$BATS_TEST_TMPDIR/agents.json"
	echo '{"hosts": ["sandbox-compute-worker"]}' >"$BATS_TEST_TMPDIR/aggregate.json"
	printf '%s\r\n' '=== cirros: current=0.6.2 uptime=5.21 ===' 'checking http://169.254.169.254/2009-04-04/instance-id' \
		'successful after 1/20 tries: up 6.32. iid=i-00000001' >"$BATS_TEST_TMPDIR/console.log"
	hub_edit '.spec.services.nova.consoleProxy = {gateway: {parentRef: {name: "openstack-gw"}, hostname: "nova-console.172-30-255-10.nip.io"}}'
	kind() {
		case $* in
		"get clusters") printf '%s\n' sandbox-management ${COMPUTE_CLUSTER_KIND-sandbox-compute} ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		"get nodes --name sandbox-compute") printf '%s\n' sandbox-compute-control-plane sandbox-compute-worker ;;
		*) return 1 ;;
		esac
	}
	openssl() {
		printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/openssl.log"
		cat >"$BATS_TEST_TMPDIR/openssl.stdin"
		printf '%s\r\n' "${WS_STATUS:-HTTP/1.1 101 Switching Protocols}" 'Upgrade: websocket' 'Connection: Upgrade' \
			'Sec-WebSocket-Protocol: binary' ''
		printf '\202\014%s' "${RFB_GREETING-RFB 003.008
}"
	}
	export CONSOLE_TOKEN
	export -f kind openssl
}

# compute_cloud: healthy_cloud with compute_parts.
compute_cloud() {
	healthy_cloud
	compute_parts
}

# hypervisor_reason <reason>: writes the Hypervisor of sandbox-compute-worker
# with the reason of its condition Onboarding.
hypervisor_reason() {
	jq -n --arg reason "$1" '{apiVersion: "kvm.cloud.sap/v1", kind: "Hypervisor", metadata: {name: "sandbox-compute-worker"},
		status: {conditions: [{type: "Onboarding", status: "False", reason: $reason, message: "onboarding"}]}}' \
		>"$BATS_TEST_TMPDIR/hub/hypervisor.sandbox-compute-worker"
}

# hub_file_edit <file> <jq filter>: changes the file of hub/ with the filter.
hub_file_edit() {
	jq "$2" "$BATS_TEST_TMPDIR/hub/$1" >"$BATS_TEST_TMPDIR/hub/$1.new"
	mv -- "$BATS_TEST_TMPDIR/hub/$1.new" "$BATS_TEST_TMPDIR/hub/$1"
}

# compute_lines: prints the lines of $output of the eight compute checks.
compute_lines() {
	grep -E '^(ok|FAIL) compute-' <<<"$output" || :
}

# orders_edit <file> <jq filter>: changes orders.json, secrets.json or
# children.json of the fake hub with the filter.
orders_edit() {
	jq "$2" "$BATS_TEST_TMPDIR/hub/orders/$1.json" >"$BATS_TEST_TMPDIR/hub/orders/$1.new"
	mv -- "$BATS_TEST_TMPDIR/hub/orders/$1.new" "$BATS_TEST_TMPDIR/hub/orders/$1.json"
}

# kubectl_calls: prints the calls of kubectl.log without their --kubeconfig.
kubectl_calls() {
	sed 's|^--kubeconfig [^ ]* ||' "$BATS_TEST_TMPDIR/kubectl.log"
}

# HOLDS: the deletes of the scratch orders in the order of their holds.
HOLDS="keystoneapplicationcredentials.c5c3.io sandbox-verify-appcred
keystoneroleassignments.c5c3.io sandbox-verify-member
keystonecatalogentries.c5c3.io sandbox-verify-catalog
keystoneprojects.c5c3.io sandbox-verify-project
keystoneusers.c5c3.io sandbox-verify
mariadbdatabases.c5c3.io sandbox-verify-db
rabbitmqvhosts.c5c3.io sandbox-verify-bus"

# verify_fails <line> <passed> [<total>]: runs verify.sh and checks that it
# exits 1, prints the line, and ends with verify: <passed> of <total> checks
# passed, by default 16.
verify_fails() {
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 1 ]
	grep -qxF -- "$1" <<<"$output"
	[ "${lines[-1]}" = "verify: $2 of ${3:-16} checks passed" ]
}

# logged <pattern>: prints the number of each line of openstack.log that
# matches the pattern, one per line.
logged() {
	local line n=0
	while IFS= read -r line; do
		n=$((n + 1))
		# shellcheck disable=SC2053 # the argument is a pattern.
		if [[ $line == $1 ]]; then
			echo "$n"
		fi
	done <"$BATS_TEST_TMPDIR/openstack.log"
}

# runs_before <pattern> <pattern>: succeeds when the first call of
# openstack.log that matches the first pattern comes before the last call
# that matches the second.
runs_before() {
	local first second
	first=$(logged "$1" | head -n 1)
	second=$(logged "$2" | tail -n 1)
	[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

# env_fails <message>: runs env.sh and checks that it exits 1 with
# error: <message> on stderr, prints nothing on stdout, and that no message
# holds the password, plain or base64-encoded.
env_fails() {
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
	[ "$stderr" = "error: $1" ]
	[[ $stderr != *"$PASSWORD"* ]]
	[[ $stderr != *"$(printf '%s' "$PASSWORD" | base64 -w 0)"* ]]
}

@test "env.sh prints seven export lines that load the admin of the ControlPlane, and writes the CA" {
	local names=(OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_CACERT) i
	access_host
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 0 ]
	[ "$stderr" = "" ]
	[ "$(grep -c '' <<<"$output")" -eq 7 ]
	for i in "${!names[@]}"; do
		[[ ${lines[i]} == "export ${names[i]}="* ]]
	done

	eval "$output"
	[ "$OS_AUTH_URL" = "$AUTH_URL" ]
	[ "$OS_USERNAME" = admin ]
	[ "$OS_PASSWORD" = "$PASSWORD" ]
	[ "$OS_PROJECT_NAME" = admin ]
	[ "$OS_USER_DOMAIN_NAME" = Default ]
	[ "$OS_PROJECT_DOMAIN_NAME" = Default ]
	[ "$OS_CACERT" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
	[ "$(<"$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem")" = "$CA_PEM" ]
	# The temporary file is renamed, not left beside it.
	[ "$(find "$BATS_TEST_TMPDIR/.sandbox" -maxdepth 1 -type f)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "env.sh restores a missing kubeconfig with its message on stderr and seven lines on stdout" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	kind() {
		case $* in
		"get clusters") echo sandbox-management ;;
		"get nodes --name sandbox-management") echo sandbox-management-control-plane ;;
		"export kubeconfig --name sandbox-management --kubeconfig "*) : >"${!#}" ;;
		*) return 1 ;;
		esac
	}
	export -f kind
	run --separate-stderr "$BATS_TEST_TMPDIR/scripts/env.sh"
	[ "$status" -eq 0 ]
	[ "$stderr" = "env: restoring $BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml" ]
	[ "$(grep -c '' <<<"$output")" -eq 7 ]
	[ "$(grep -c '^export OS_' <<<"$output")" -eq 7 ]
}

@test "env.sh fails without a management cluster" {
	access_host
	kind() { [ "$*" = "get clusters" ]; }
	export -f kind
	env_fails "access: sandbox-management does not exist; run make up"
}

@test "env.sh fails without the CRD of the ControlPlane" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/crd"
	env_fails "access: no ControlPlane openstack/controlplane on sandbox-management; the profile runs no control plane"
}

@test "env.sh fails without the ControlPlane openstack/controlplane" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/controlplane.json"
	env_fails "access: no ControlPlane openstack/controlplane on sandbox-management; the profile runs no control plane"
}

@test "env.sh fails for an empty or absent Keystone hostname" {
	access_host
	controlplane ""
	env_fails "access: the ControlPlane openstack/controlplane publishes no Keystone hostname"
	jq 'del(.spec.services.keystone.gateway)' "$BATS_TEST_TMPDIR/hub/controlplane.json" >"$BATS_TEST_TMPDIR/cp.json"
	mv -- "$BATS_TEST_TMPDIR/cp.json" "$BATS_TEST_TMPDIR/hub/controlplane.json"
	env_fails "access: the ControlPlane openstack/controlplane publishes no Keystone hostname"
}

@test "env.sh fails without the Secret of the admin password" {
	access_host
	rm -- "$BATS_TEST_TMPDIR/hub/admin.json"
	env_fails "access: the Secret openstack/controlplane-keystone-admin-credentials holds no password; the ControlPlane is not Ready, make status shows its stage"
}

@test "env.sh fails for an empty admin password" {
	access_host
	secret admin.json password ""
	env_fails "access: the Secret openstack/controlplane-keystone-admin-credentials holds no password; the ControlPlane is not Ready, make status shows its stage"
}

@test "env.sh fails for an empty or missing tls.crt and writes no CA" {
	access_host
	secret ca.json tls.crt ""
	env_fails "access: the Secret cert-manager/sandbox-ca holds no tls.crt"
	rm -- "$BATS_TEST_TMPDIR/hub/ca.json"
	env_fails "access: the Secret cert-manager/sandbox-ca holds no tls.crt"
	[ ! -e "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "env.sh fails with the object and the last line of kubectl when kubectl cannot read it" {
	local refused="The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?"
	access_host
	export KUBECTL_FAILS=crd
	env_fails "access: cannot read the CRD controlplanes.c5c3.io: $refused"
	KUBECTL_FAILS=controlplane.json
	env_fails "access: cannot read the ControlPlane openstack/controlplane: $refused"
	KUBECTL_FAILS=admin.json
	env_fails "access: cannot read the Secret openstack/controlplane-keystone-admin-credentials: $refused"
	KUBECTL_FAILS=ca.json
	env_fails "access: cannot read the Secret cert-manager/sandbox-ca: $refused"
}

@test "verify.sh without a ControlPlane passes 0 of 0 checks and never calls openstack" {
	local file
	access_host
	openstack_logs
	for file in controlplane.json crd; do
		rm -- "$BATS_TEST_TMPDIR/hub/$file"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		[ "$status" -eq 0 ]
		[ "$output" = "verify: sandbox-management runs no ControlPlane, 0 of 0 checks passed" ]
	done
	[ ! -e "$BATS_TEST_TMPDIR/openstack.log" ]
}

@test "verify.sh with a ControlPlane fails without openstack in PATH" {
	local tool
	access_host
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	for tool in dirname mktemp rm grep cat; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: verify: openstack not found in PATH, see "Host requirements" in the README' ]
}

@test "verify.sh passes the token and the catalog checks of keystone without --insecure" {
	access_host
	openstack_logs
	catalog_with "$AUTH_URL"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 3 ]
	[[ ${lines[0]} == "ok keystone-token: "* ]]
	[[ ${lines[1]} == "ok keystone-catalog: "* ]]
	[ "${lines[2]}" = "verify: 2 of 2 checks passed" ]
	[[ $output != *gAAAAABsandboxtoken* ]]
	[ "$(<"$BATS_TEST_TMPDIR/openstack.log")" = "token issue -f value -c id
catalog list -f json" ]
	run ! grep -q -e --insecure "$BATS_TEST_TMPDIR/openstack.log"
}

@test "verify.sh runs openstack with the variables of env.sh and no other OS_ variable" {
	access_host
	catalog_with "$AUTH_URL"
	openstack() {
		env | grep '^OS_' | LC_ALL=C sort >"$BATS_TEST_TMPDIR/openstack.env"
		case $* in
		"token issue -f value -c id") echo gAAAAABsandboxtoken ;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		esac
	}
	export -f openstack
	export OS_CLOUD=elsewhere OS_TOKEN=foreign OS_PASSWORD=foreign
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(<"$BATS_TEST_TMPDIR/openstack.env")" = "OS_AUTH_URL=$AUTH_URL
OS_CACERT=$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem
OS_PASSWORD=$PASSWORD
OS_PROJECT_DOMAIN_NAME=Default
OS_PROJECT_NAME=admin
OS_USERNAME=admin
OS_USER_DOMAIN_NAME=Default" ]
}

@test "verify.sh fails the catalog check without a public identity endpoint at OS_AUTH_URL, and exits 1 when one check of two failed" {
	local case
	access_host
	openstack_logs
	for case in other-url internal-only other-type; do
		case $case in
		other-url) catalog_with http://keystone.172-30-255-10.nip.io/v3 ;;
		internal-only)
			jq -n --arg url "$AUTH_URL" '[{Name: "keystone", Type: "identity", Endpoints: [
				{id: "a1", interface: "internal", region_id: "RegionOne", url: $url, region: "RegionOne"}]}]' >"$BATS_TEST_TMPDIR/catalog.json"
			;;
		other-type)
			catalog_with "$AUTH_URL"
			jq '.[0].Type = "compute"' "$BATS_TEST_TMPDIR/catalog.json" >"$BATS_TEST_TMPDIR/c.json"
			mv -- "$BATS_TEST_TMPDIR/c.json" "$BATS_TEST_TMPDIR/catalog.json"
			;;
		esac
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 1 ]
		[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
FAIL keystone-catalog: no public identity endpoint $AUTH_URL in the catalog
verify: 1 of 2 checks passed" ]
	done
}

@test "verify.sh fails the token check when openstack prints no token id, and names the first line of a longer error" {
	access_host
	catalog_with "$AUTH_URL"
	openstack() {
		case $* in
		"token issue -f value -c id") : ;;
		"catalog list -f json") cat -- "$BATS_TEST_TMPDIR/catalog.json" ;;
		esac
	}
	export -f openstack
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "FAIL keystone-token: openstack token issue printed no token id" ]
	[ "${lines[-1]}" = "verify: 1 of 2 checks passed" ]

	openstack_logs
	export TOKEN_ERROR="Failed to discover available identity versions when contacting $AUTH_URL.
SSL exception connecting to $AUTH_URL/auth/tokens"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "FAIL keystone-token: Failed to discover available identity versions when contacting $AUTH_URL." ]
	[ "${lines[-1]}" = "verify: 1 of 2 checks passed" ]
}

@test "verify.sh fails each keystone check with the first line of its error" {
	access_host
	openstack_logs
	export TOKEN_ERROR="SSL exception connecting to $AUTH_URL"
	echo '[]' >"$BATS_TEST_TMPDIR/catalog.json"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "FAIL keystone-token: SSL exception connecting to $AUTH_URL
FAIL keystone-catalog: no public identity endpoint $AUTH_URL in the catalog
verify: 0 of 2 checks passed" ]
}

@test "verify.sh passes the 16 checks of the eight services in the fixed order, whatever the order of spec.services" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
ok keystone-catalog: the catalog holds the public identity endpoint $AUTH_URL
ok glance-catalog: the catalog holds a public image endpoint at https://glance.172-30-255-10.nip.io
ok glance-image: a 1 KiB image uploaded as sandbox-verify-image became active
ok placement-catalog: the catalog holds a public placement endpoint at https://placement.172-30-255-10.nip.io
ok placement-classes: resource class list holds VCPU, MEMORY_MB and DISK_GB
ok barbican-catalog: the catalog holds a public key-manager endpoint at https://barbican.172-30-255-10.nip.io
ok barbican-secret: the payload of sandbox-verify-secret came back unchanged
ok neutron-catalog: the catalog holds a public network endpoint at https://neutron.172-30-255-10.nip.io
ok neutron-network: the network sandbox-verify-net with the subnet sandbox-verify-subnet on 192.0.2.0/24 is ACTIVE
ok cinder-catalog: the catalog holds a public block-storage endpoint at https://cinder.172-30-255-10.nip.io
ok cinder-volume: the 1 GiB volume sandbox-verify-volume is available
ok nova-catalog: the catalog holds a public compute endpoint at https://nova.172-30-255-10.nip.io
ok nova-services: a nova-scheduler and a nova-conductor service are up
ok nova-server: the server sandbox-verify-server is ACTIVE on the fake compute of sandbox-management-control-plane
ok horizon-login: admin logged in to https://horizon.172-30-255-10.nip.io and reached /project/
verify: 16 of 16 checks passed" ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,nova-server,horizon-login ]
	# One catalog serves the seven catalog checks, and nothing waits.
	[ "$(grep -cxF 'catalog list -f json' "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/sleep.log" ]
}

@test "verify.sh runs the checks of a service only when the ControlPlane declares it" {
	local case checks
	healthy_cloud
	for case in \
		glance:glance-catalog,glance-image \
		placement:placement-catalog,placement-classes \
		barbican:barbican-catalog,barbican-secret \
		neutron:neutron-catalog,neutron-network \
		cinder:cinder-catalog,cinder-volume \
		nova:nova-catalog,nova-services,nova-server \
		horizon:horizon-login; do
		controlplane_services "${case%%:*}" keystone
		rm -f -- "$BATS_TEST_TMPDIR/curl.log"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 0 ]
		[ "$(check_ids)" = "keystone-token,keystone-catalog,${case#*:}" ]
		checks=$((${#lines[@]} - 1))
		[ "${lines[-1]}" = "verify: $checks of $checks checks passed" ]
		if [ "${case%%:*}" != horizon ]; then
			[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
		fi
	done
}

@test "verify.sh creates the resources of upstream's Step 7 under sandbox-verify names, and maps the fake compute into the cell" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ -n "$(logged 'image create --disk-format raw --container-format bare --file */image.raw -f value -c id sandbox-verify-image')" ]
	[ -n "$(logged 'secret store --name sandbox-verify-secret --payload sandbox-verify-payload -f value -c Secret href')" ]
	[ -n "$(logged 'network create -f value -c id sandbox-verify-net')" ]
	[ -n "$(logged 'subnet create --network id-sandbox-verify-net --subnet-range 192.0.2.0/24 -f value -c id sandbox-verify-subnet')" ]
	[ -n "$(logged 'volume create --size 1 -f value -c id sandbox-verify-volume')" ]
	[ -n "$(logged 'flavor create --vcpus 1 --ram 128 --disk 1 -f value -c id sandbox-verify-flavor')" ]
	[ -n "$(logged 'image create --disk-format raw --container-format bare --file */boot.raw -f value -c id sandbox-verify-boot')" ]
	[ -n "$(logged '--os-compute-api-version 2.37 server create --image id-sandbox-verify-boot --flavor sandbox-verify-flavor --nic none --wait -f value -c id sandbox-verify-server')" ]
	# The server create alone asks for compute API 2.37, which --nic none
	# needs.
	[ "$(grep -c -- --os-compute-api-version "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
	runs_before 'compute service list --service nova-compute --host sandbox-management-control-plane -f value -c State' 'flavor create *'
	[ "$(grep -c ' exec ' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ]
	grep -qx -- "--kubeconfig $BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml -n openstack exec deploy/controlplane-nova-conductor -c conductor -- nova-manage --config-dir /etc/nova/nova.conf.d cell_v2 discover_hosts" \
		"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh uploads a 1 KiB image as sandbox-verify-image and a 1 MiB image as sandbox-verify-boot" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(<"$BATS_TEST_TMPDIR/image-size.sandbox-verify-image")" -eq 1024 ]
	[ "$(<"$BATS_TEST_TMPDIR/image-size.sandbox-verify-boot")" -eq 1048576 ]
}

@test "verify.sh passes no --insecure and no -k to openstack or curl, and curl trusts OS_CACERT" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	run ! grep -E -e '(^| )(--insecure|-[a-zA-Z]*k)( |$)' "$BATS_TEST_TMPDIR/openstack.log"
	run ! grep -E -e '^(--insecure|-[a-zA-Z]*k[a-zA-Z]*)$' "$BATS_TEST_TMPDIR/curl.log"
	[ "$(grep -cx -- -- "$BATS_TEST_TMPDIR/curl.log")" -eq 2 ]
	[ "$(curl_call 1 | grep -A 1 -x -- --cacert | tail -n 1)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
	[ "$(curl_call 2 | grep -A 1 -x -- --cacert | tail -n 1)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
}

@test "verify.sh gives curl the admin password from a file of mode 600 in its temporary directory, never as an argument" {
	local encoded
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	for encoded in "$PASSWORD" 'p%20w%24' 'p+w%24' "$(printf '%s' "$PASSWORD" | base64 -w 0)"; do
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/curl.log"
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/openstack.log"
		run ! grep -qF -- "$encoded" "$BATS_TEST_TMPDIR/kubectl.log"
	done
	# The file holds the password alone, without a newline, and is gone
	# with the temporary directory, which also held the cookie jar.
	[ "$(<"$BATS_TEST_TMPDIR/posted-password")" = "$PASSWORD" ]
	[ "$(wc -c <"$BATS_TEST_TMPDIR/posted-password")" -eq "${#PASSWORD}" ]
	[ "$(<"$BATS_TEST_TMPDIR/posted-password.mode")" = 600 ]
	[ ! -e "$(<"$BATS_TEST_TMPDIR/posted-password.path")" ]
	[ "$(curl_call 2 | grep -A 1 -x -- --cookie | tail -n 1)" = "$(dirname -- "$(<"$BATS_TEST_TMPDIR/posted-password.path")")/cookies" ]
}

@test "verify.sh posts the hidden inputs of the login form back unchanged with the user, the domain and the password, and follows the redirects" {
	healthy_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	# The GET reads the login page into the cookie jar.
	[ "$(curl_call 1 | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	curl_call 1 | grep -qx -- --cookie-jar
	run ! grep -qx -- --data-urlencode <<<"$(curl_call 1)"
	# The POST sends the cookies and names the login page as its referer.
	[ "$(curl_call 2 | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	[ "$(curl_call 2 | grep -A 1 -x -- --referer | tail -n 1)" = https://horizon.172-30-255-10.nip.io/auth/login/ ]
	curl_call 2 | grep -qx -- --location
	run --separate-stderr awk 'prev == "--data-urlencode" { print } { prev = $0 }' <<<"$(curl_call 2)"
	[ "${#lines[@]}" -eq 6 ]
	[ "${lines[0]}" = csrfmiddlewaretoken=Zx9pQcsrfTokenOfTheForm ]
	[ "${lines[1]}" = region=default ]
	[ "${lines[2]}" = next=/project/ ]
	[ "${lines[3]}" = username=admin ]
	[ "${lines[4]}" = domain=Default ]
	[[ ${lines[5]} == password@/*/password ]]
}

@test "verify.sh fails glance-catalog for a glance block without a hostname" {
	healthy_cloud
	hub_edit 'del(.spec.services.glance.gateway)'
	verify_fails "FAIL glance-catalog: the ControlPlane publishes no hostname for glance" 15
	hub_edit '.spec.services.glance.gateway = {parentRef: {name: "openstack-gw"}, hostname: ""}'
	verify_fails "FAIL glance-catalog: the ControlPlane publishes no hostname for glance" 15
}

@test "verify.sh fails glance-catalog without a public image endpoint at the hostname, and for an empty catalog" {
	local case
	healthy_cloud
	for case in no-row internal-only other-host other-port; do
		healthy_catalog
		case $case in
		no-row) catalog_edit 'map(select(.Type != "image"))' ;;
		internal-only) catalog_edit 'map(if .Type == "image" then .Endpoints |= map(select(.interface != "public")) else . end)' ;;
		other-host) catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io.example.org/" else . end)' ;;
		other-port) catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io:8443" else . end)' ;;
		esac
		echo "$case"
		verify_fails "FAIL glance-catalog: no public image endpoint at https://glance.172-30-255-10.nip.io in the catalog" 15
	done

	echo '[]' >"$BATS_TEST_TMPDIR/catalog.json"
	verify_fails "FAIL glance-catalog: no public image endpoint at https://glance.172-30-255-10.nip.io in the catalog" 9
	[ "$(grep -c -- '-catalog: ' <<<"$output")" -eq 7 ]
	[ "$(grep -c '^FAIL ' <<<"$output")" -eq 7 ]
}

@test "verify.sh passes a catalog check for an endpoint under the hostname" {
	healthy_cloud
	catalog_edit 'map(if .Type == "image" then .Endpoints[1].url = "https://glance.172-30-255-10.nip.io/" else . end)'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${lines[2]}" = "ok glance-catalog: the catalog holds a public image endpoint at https://glance.172-30-255-10.nip.io" ]
}

@test "verify.sh fails each catalog check without the hostname of its service or the endpoint of its type" {
	local pair service type
	healthy_cloud
	for pair in glance:image placement:placement barbican:key-manager neutron:network cinder:block-storage nova:compute; do
		service=${pair%:*}
		type=${pair#*:}
		controlplane_services horizon nova cinder neutron barbican placement glance keystone
		hub_edit "del(.spec.services.$service.gateway.hostname)"
		verify_fails "FAIL $service-catalog: the ControlPlane publishes no hostname for $service" 15

		controlplane_services horizon nova cinder neutron barbican placement glance keystone
		healthy_catalog
		catalog_edit "map(select(.Type != \"$type\"))"
		verify_fails "FAIL $service-catalog: no public $type endpoint at https://$service.172-30-255-10.nip.io in the catalog" 15
		healthy_catalog
	done
}

@test "verify.sh fails every catalog check with the first line of the error of the one catalog read" {
	healthy_cloud
	export STUB_FAILS='catalog list -f json' STUB_ERROR="Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)
Max retries exceeded with url: /v3/auth/catalog"
	verify_fails "FAIL nova-catalog: Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)" 9
	[ "$(grep -c "^FAIL [a-z]*-catalog: Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/catalog: " <<<"$output")" -eq 7 ]
	[ "$(grep -cxF 'catalog list -f json' "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
}

@test "verify.sh fails each check with the first line of the error when openstack exits non-zero" {
	local case
	healthy_cloud
	export STUB_ERROR="Unable to establish connection to https://glance.172-30-255-10.nip.io/v2/images: HTTPSConnectionPool(host='glance.172-30-255-10.nip.io', port=443)
Max retries exceeded with url: /v2/images"
	for case in \
		'image create * sandbox-verify-image|glance-image' \
		'image show id-sandbox-verify-image *|glance-image' \
		'resource class list *|placement-classes' \
		'secret store *|barbican-secret' \
		'secret get *|barbican-secret' \
		'network create *|neutron-network' \
		'subnet create *|neutron-network' \
		'network show *|neutron-network' \
		'volume create *|cinder-volume' \
		'volume show *|cinder-volume' \
		'compute service list -f json|nova-services' \
		'compute service list --service *|nova-server' \
		'flavor create *|nova-server' \
		'image create * sandbox-verify-boot|nova-server' \
		'image show id-sandbox-verify-boot *|nova-server' \
		'*server *|nova-server'; do
		export STUB_FAILS=${case%|*}
		echo "$STUB_FAILS"
		verify_fails "FAIL ${case#*|}: Unable to establish connection to https://glance.172-30-255-10.nip.io/v2/images: HTTPSConnectionPool(host='glance.172-30-255-10.nip.io', port=443)" 15
	done
}

@test "verify.sh reports '' as the status when openstack prints nothing" {
	local case
	healthy_cloud
	export FAULT='No valid host was found. There are not enough hosts available.'
	for case in \
		"image show id-sandbox-verify-image *|FAIL glance-image: the image sandbox-verify-image is '' after 60 s, expected active" \
		"network show *|FAIL neutron-network: the network sandbox-verify-net is '', expected ACTIVE" \
		"volume show *|FAIL cinder-volume: the volume sandbox-verify-volume is '' after 120 s, expected available" \
		"compute service list --service *|FAIL nova-server: the compute service of sandbox-management-control-plane is '' after 120 s, expected up" \
		"image show id-sandbox-verify-boot *|FAIL nova-server: the image sandbox-verify-boot is '' after 60 s, expected active" \
		"server show sandbox-verify-server -f value -c status|FAIL nova-server: the server sandbox-verify-server is '', expected ACTIVE: No valid host was found. There are not enough hosts available."; do
		export STUB_SILENT=${case%%|*}
		echo "$STUB_SILENT"
		verify_fails "${case#*|}" 15
	done
}

@test "verify.sh fails glance-image when the image is not active after 60 s, polling every 2 s" {
	healthy_cloud
	export IMAGE_STATUS=saving
	verify_fails "FAIL glance-image: the image sandbox-verify-image is 'saving' after 60 s, expected active" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 30 ]
	[ "$(sort -u "$BATS_TEST_TMPDIR/sleep.log")" = 2 ]
	[ "$(logged 'image show id-sandbox-verify-image *' | grep -c '')" -eq 31 ]
}

@test "verify.sh fails placement-classes for each standard class the list lacks" {
	local class
	healthy_cloud
	for class in VCPU MEMORY_MB DISK_GB; do
		export CLASSES
		CLASSES=$(printf '%s\n' VCPU MEMORY_MB DISK_GB PCI_DEVICE | grep -vx -- "$class")
		verify_fails "FAIL placement-classes: resource class list holds no $class" 15
	done
}

@test "verify.sh fails barbican-secret when the payload comes back changed" {
	healthy_cloud
	export PAYLOAD=sandbox-verify-payload-changed
	verify_fails "FAIL barbican-secret: the payload of sandbox-verify-secret came back changed" 15
}

@test "verify.sh fails neutron-network when the network is not ACTIVE" {
	healthy_cloud
	export NETWORK_STATUS=DOWN
	verify_fails "FAIL neutron-network: the network sandbox-verify-net is 'DOWN', expected ACTIVE" 15
}

@test "verify.sh fails cinder-volume when the volume is not available after 120 s, polling every 2 s" {
	healthy_cloud
	export VOLUME_STATUS=creating
	verify_fails "FAIL cinder-volume: the volume sandbox-verify-volume is 'creating' after 120 s, expected available" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 60 ]
	[ "$(logged 'volume show id-sandbox-verify-volume *' | grep -c '')" -eq 61 ]
}

@test "verify.sh fails nova-services when no nova-scheduler or no nova-conductor is up" {
	healthy_cloud
	compute_services down up
	verify_fails "FAIL nova-services: no nova-scheduler service is up" 15
	compute_services up down
	verify_fails "FAIL nova-services: no nova-conductor service is up" 15
	echo '[]' >"$BATS_TEST_TMPDIR/services.json"
	verify_fails "FAIL nova-services: no nova-scheduler service is up" 15
}

@test "verify.sh reports two checks for nova without the Deployment controlplane-fake-compute" {
	healthy_cloud
	rm -- "$BATS_TEST_TMPDIR/hub/fake-compute.json"
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,horizon-login ]
	[ "${lines[-1]}" = "verify: 15 of 15 checks passed" ]
	[ -z "$(logged '*server *')" ]
	[ -z "$(logged 'flavor *')" ]
	[ -z "$(logged '* sandbox-verify-boot')" ]
	run ! grep -q ' exec ' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh fails nova-server with the last line of kubectl when it cannot read the Deployment" {
	healthy_cloud
	export KUBECTL_FAILS=fake-compute.json
	verify_fails "FAIL nova-server: cannot read the Deployment openstack/controlplane-fake-compute: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
}

@test "verify.sh fails nova-server with the last line of kubectl when it cannot read the pods of the Deployment" {
	healthy_cloud
	export KUBECTL_FAILS=fake-compute-pods.json
	verify_fails "FAIL nova-server: cannot read the pods of the Deployment openstack/controlplane-fake-compute: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
	[ -z "$(logged 'compute service list --service *')" ]
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the Deployment controlplane-fake-compute has no pod" {
	healthy_cloud
	echo '{"apiVersion": "v1", "kind": "List", "items": []}' >"$BATS_TEST_TMPDIR/hub/fake-compute-pods.json"
	verify_fails "FAIL nova-server: the Deployment controlplane-fake-compute has no pod" 15
	[ -z "$(logged 'compute service list --service *')" ]
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the compute service is not up after 120 s, polling every 2 s" {
	healthy_cloud
	export COMPUTE_STATE=down
	verify_fails "FAIL nova-server: the compute service of sandbox-management-control-plane is 'down' after 120 s, expected up" 15
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 60 ]
	[ "$(logged 'compute service list --service *' | grep -c '')" -eq 61 ]
	[ -z "$(logged 'flavor create *')" ]
	run ! grep -q ' exec ' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh fails nova-server with the last line of kubectl when discover_hosts cannot run in the conductor" {
	healthy_cloud
	export KUBECTL_FAILS=discover-hosts
	verify_fails "FAIL nova-server: cannot run nova-manage cell_v2 discover_hosts in deploy/controlplane-nova-conductor: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 15
	[ -z "$(logged 'flavor create *')" ]
}

@test "verify.sh fails nova-server when the boot image is not active after 60 s" {
	healthy_cloud
	export BOOT_STATUS=queued
	verify_fails "FAIL nova-server: the image sandbox-verify-boot is 'queued' after 60 s, expected active" 15
	[ -z "$(logged '* server create *')" ]
}

@test "verify.sh fails nova-server when the server is not ACTIVE, with the first line of its fault" {
	healthy_cloud
	export SERVER_STATUS=ERROR FAULT='No valid host was found. There are not enough hosts available.
Traceback (most recent call last):'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found. There are not enough hosts available." 15

	# server create --wait fails for a server in ERROR; its status and fault
	# are the message.
	export STUB_FAILS='* server create *' STUB_ERROR='Error creating server: sandbox-verify-server'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found. There are not enough hosts available." 15
}

@test "verify.sh fails nova-server with the first line of the error of server create when there is no server to show, else with that of server show" {
	local refused='--os-compute-api-version 2.37 or greater is required to support explicit auto-allocation of a network or to disable network allocation'
	healthy_cloud
	export SERVER_ABSENT=1
	verify_fails "FAIL nova-server: No Server found for sandbox-verify-server" 15

	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export STUB_FAILS='* server create *' STUB_ERROR="$refused
Usage: openstack server create [-h]"
	verify_fails "FAIL nova-server: $refused" 15
	[ -n "$(logged 'server show sandbox-verify-server -f value -c status')" ]
}

@test "verify.sh fails horizon-login for a horizon block without a hostname, and calls no curl" {
	healthy_cloud
	hub_edit 'del(.spec.services.horizon.gateway)'
	verify_fails "FAIL horizon-login: the ControlPlane publishes no hostname for horizon" 15
	[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "verify.sh fails horizon-login without curl in PATH" {
	local tool
	access_host
	controlplane_services keystone horizon
	catalog_with "$AUTH_URL"
	openstack_logs
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	for tool in dirname mktemp rm grep cat jq mkdir mv tail; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "ok keystone-token: admin received a token from $AUTH_URL
ok keystone-catalog: the catalog holds the public identity endpoint $AUTH_URL
FAIL horizon-login: curl not found in PATH
verify: 2 of 3 checks passed" ]
}

@test "verify.sh fails horizon-login when the login ends on the login page or without status 200" {
	healthy_cloud
	export HORIZON_PATH='/auth/login/?next=/project/'
	verify_fails "FAIL horizon-login: the login of admin ended on /auth/login/ with status 200" 15
	export HORIZON_PATH=/auth/login/ HORIZON_STATUS=403
	verify_fails "FAIL horizon-login: the login of admin ended on /auth/login/ with status 403" 15
	export HORIZON_PATH=/project/ HORIZON_STATUS=500
	verify_fails "FAIL horizon-login: the login of admin ended on /project/ with status 500" 15
}

@test "verify.sh fails horizon-login with the first line of the error of curl" {
	healthy_cloud
	export CURL_ERROR='curl: (60) SSL certificate problem: unable to get local issuer certificate
More details here: https://curl.se/docs/sslcerts.html'
	verify_fails "FAIL horizon-login: curl: (60) SSL certificate problem: unable to get local issuer certificate" 15
}

@test "verify.sh deletes what an earlier run left of its sandbox-verify names before it creates" {
	healthy_cloud
	export SECRET_LEFTOVERS='https://barbican.172-30-255-10.nip.io/v1/secrets/0ld1
https://barbican.172-30-255-10.nip.io/v1/secrets/0ld2'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	runs_before 'image delete sandbox-verify-image' 'image create * sandbox-verify-image'
	runs_before 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/0ld1' 'secret store *'
	runs_before 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/0ld2' 'secret store *'
	runs_before 'subnet delete sandbox-verify-subnet' 'network create *'
	runs_before 'network delete sandbox-verify-net' 'network create *'
	runs_before 'volume delete sandbox-verify-volume' 'volume create *'
	runs_before 'server delete --wait sandbox-verify-server' 'flavor create *'
	runs_before 'image delete sandbox-verify-boot' 'flavor create *'
	runs_before 'flavor delete sandbox-verify-flavor' 'flavor create *'
}

@test "verify.sh deletes every sandbox-verify resource a failed check created" {
	healthy_cloud
	export IMAGE_STATUS=saving PAYLOAD=changed NETWORK_STATUS=DOWN VOLUME_STATUS=error SERVER_STATUS=ERROR \
		FAULT='No valid host was found.'
	verify_fails "FAIL nova-server: the server sandbox-verify-server is 'ERROR', expected ACTIVE: No valid host was found." 11
	[ "$(grep -c '^FAIL ' <<<"$output")" -eq 5 ]
	runs_before 'image create * sandbox-verify-image' 'image delete id-sandbox-verify-image'
	runs_before 'secret store *' 'secret delete https://barbican.172-30-255-10.nip.io/v1/secrets/5e1c0ffe'
	runs_before 'subnet create * sandbox-verify-subnet' 'subnet delete id-sandbox-verify-subnet'
	runs_before 'subnet delete id-sandbox-verify-subnet' 'network delete id-sandbox-verify-net'
	runs_before 'volume create * sandbox-verify-volume' 'volume delete id-sandbox-verify-volume'
	runs_before '* server create * sandbox-verify-server' 'server delete --wait sandbox-verify-server'
	runs_before 'server delete --wait sandbox-verify-server' 'image delete id-sandbox-verify-boot'
	runs_before 'image delete id-sandbox-verify-boot' 'flavor delete sandbox-verify-flavor'

	# A boot image that never becomes active leaves no flavor and no image.
	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export BOOT_STATUS=killed SERVER_STATUS=ACTIVE
	verify_fails "FAIL nova-server: the image sandbox-verify-boot is 'killed' after 60 s, expected active" 11
	runs_before 'image create * sandbox-verify-boot' 'image delete id-sandbox-verify-boot'
	runs_before 'flavor create *' 'flavor delete sandbox-verify-flavor'
}

@test "verify.sh exits 1 with 15 of 16 checks passed when one check failed" {
	healthy_cloud
	export PAYLOAD=changed
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 1 ]
	[ "${#lines[@]}" -eq 17 ]
	[ "$(grep -c '^ok ' <<<"$output")" -eq 15 ]
	[ "${lines[7]}" = "FAIL barbican-secret: the payload of sandbox-verify-secret came back changed" ]
	[ "${lines[16]}" = "verify: 15 of 16 checks passed" ]
}

@test "verify.sh does not report a failed delete" {
	healthy_cloud
	export STUB_FAILS='* delete *' STUB_ERROR='No image found for sandbox-verify-image'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 17 ]
	[ "${lines[16]}" = "verify: 16 of 16 checks passed" ]
	[ -n "$(logged '* delete *')" ]
}

@test "verify.sh runs no compute check without the CRD of NovaCompute, without a pool, or for a pool that names no target cluster" {
	local case
	for case in no-crd no-pool no-target other-target; do
		rm -rf -- "$BATS_TEST_TMPDIR/hub" "$BATS_TEST_TMPDIR"/{kubectl,openstack}.log
		compute_cloud
		case $case in
		no-crd) rm -- "$BATS_TEST_TMPDIR/hub/novacompute-crd" ;;
		no-pool) hub_file_edit novacomputes.json '.items = []' ;;
		no-target) hub_file_edit novacomputes.json 'del(.items[0].spec.targetClusterRef)' ;;
		other-target) hub_file_edit novacomputes.json '.items[0].spec.targetClusterRef.name = "elsewhere"' ;;
		esac
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 0 ]
		[ -z "$(compute_lines)" ]
		[ "${lines[-1]}" = "verify: 16 of 16 checks passed" ]
		[ -z "$(logged '*sandbox-verify-compute*')" ]
		[ -z "$(logged 'network agent list *')" ]
	done
}

@test "verify.sh passes the eight compute checks in the order of the table, after the checks of the services and before those of the orders" {
	orders_cloud
	compute_parts
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,nova-server,horizon-login,compute-pool,compute-chassis,compute-metadata-agent,compute-hypervisor,compute-network,compute-server,compute-metadata,compute-console,orders-ready,orders-secrets,orders-converge,orders-rotation,orders-teardown ]
	[ "$(compute_lines)" = "ok compute-pool: the pool lab is Ready, sandbox-compute-worker Active, up and enabled
ok compute-chassis: the OVNChassis lab-chassis is Ready, with an alive ovn-controller agent on sandbox-compute-worker
ok compute-metadata-agent: the NeutronMetadataAgent lab-metadata-agent is Ready, with an alive neutron-ovn-metadata-agent agent on sandbox-compute-worker
ok compute-hypervisor: sandbox-compute-worker in sandbox onboarded, each in the aggregate of its zone
ok compute-network: the network sandbox-verify-compute-net with the subnet sandbox-verify-compute-subnet on 198.51.100.0/24 has the MTU 1442
ok compute-server: the server sandbox-verify-compute-server is ACTIVE on sandbox-compute-worker
ok compute-metadata: cirros on sandbox-verify-compute-server read the instance id i-00000001 from the metadata service
ok compute-console: the console page answers 200 on https://nova-console.172-30-255-10.nip.io, and a WebSocket with the token of the noVNC URL relays the RFB greeting of the server's VNC" ]
	[ "${lines[-1]}" = "verify: 29 of 29 checks passed" ]
	# The Hypervisor is read on sandbox-compute, and the server boots in the
	# zone and on the host of the node.
	grep -qxF -- "--kubeconfig $BATS_TEST_TMPDIR/.sandbox/kubeconfig/compute.yaml get hypervisors.kvm.cloud.sap sandbox-compute-worker --ignore-not-found -o json" \
		"$BATS_TEST_TMPDIR/kubectl.log"
	[ -n "$(logged 'server create --image cirros-kvm --flavor 1 --network id-sandbox-verify-compute-net --availability-zone sandbox:sandbox-compute-worker -f value -c id sandbox-verify-compute-server')" ]
	[ -n "$(logged 'subnet create --network id-sandbox-verify-compute-net --subnet-range 198.51.100.0/24 -f value -c id sandbox-verify-compute-subnet')" ]
	[ "$(grep -cxF 'network agent list -f json' "$BATS_TEST_TMPDIR/openstack.log")" -eq 1 ]
	# curl reads the page with the sandbox CA, openssl dials the proxy and
	# verifies it with the same CA.
	[ "$(curl_call 3 | grep -A1 -xF -- --cacert | tail -n 1)" = "$BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem" ]
	[ "$(curl_call 3 | tail -n 1)" = https://nova-console.172-30-255-10.nip.io/vnc_lite.html ]
	[ "$(<"$BATS_TEST_TMPDIR/openssl.log")" = "s_client -quiet -no_ign_eof -verify_return_error -CAfile $BATS_TEST_TMPDIR/.sandbox/sandbox-ca.pem -connect nova-console.172-30-255-10.nip.io:443 -servername nova-console.172-30-255-10.nip.io" ]
	[ "$(head -n 1 "$BATS_TEST_TMPDIR/openssl.stdin")" = "GET /?token=$CONSOLE_TOKEN HTTP/1.1"$'\r' ]
	[ "$(tr -d '\r' <"$BATS_TEST_TMPDIR/openssl.stdin" | sed 1d)" = "Host: nova-console.172-30-255-10.nip.io
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: c2FuZGJveC12ZXJpZnkxMg==
Sec-WebSocket-Protocol: binary" ]
}

@test "verify.sh fails compute-pool with the message of Ready for a pool that is not Ready, and with the node and its state for a node whose service is down" {
	compute_cloud
	hub_file_edit novacomputes.json '.items[0].status.conditions[0] = {type: "Ready", status: "False", reason: "NotAllReady", message: "AggregatesReady=False (NodesWithoutZone)"}'
	verify_fails "FAIL compute-pool: the pool lab is not Ready: AggregatesReady=False (NodesWithoutZone)" 23 24
	[ "$(compute_lines | wc -l)" -eq 8 ]

	compute_cloud
	hub_file_edit novacomputes.json '.items[0].status.nodes[0].serviceState = "down"'
	verify_fails "FAIL compute-pool: the node sandbox-compute-worker of the pool lab is Active, its service down and enabled" 23 24
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh fails compute-chassis and compute-metadata-agent with the node that has no alive agent of their binary, and for an object that is not Ready" {
	compute_cloud
	jq '(.[] | select(.Binary == "ovn-controller") | .Alive) = false' "$BATS_TEST_TMPDIR/agents.json" >"$BATS_TEST_TMPDIR/a.json"
	mv -- "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/agents.json"
	verify_fails "FAIL compute-chassis: no alive ovn-controller agent on sandbox-compute-worker" 23 24

	compute_cloud
	jq 'map(select(.Binary != "neutron-ovn-metadata-agent"))' "$BATS_TEST_TMPDIR/agents.json" >"$BATS_TEST_TMPDIR/a.json"
	mv -- "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/agents.json"
	verify_fails "FAIL compute-metadata-agent: no alive neutron-ovn-metadata-agent agent on sandbox-compute-worker" 23 24

	# An alive agent on another node is no agent of the node.
	compute_cloud
	jq '(.[] | .Host) = "sandbox-compute-control-plane"' "$BATS_TEST_TMPDIR/agents.json" >"$BATS_TEST_TMPDIR/a.json"
	mv -- "$BATS_TEST_TMPDIR/a.json" "$BATS_TEST_TMPDIR/agents.json"
	verify_fails "FAIL compute-chassis: no alive ovn-controller agent on sandbox-compute-worker" 22 24
	grep -qxF "FAIL compute-metadata-agent: no alive neutron-ovn-metadata-agent agent on sandbox-compute-worker" <<<"$output"

	compute_cloud
	hub_file_edit ovnchassis.json '.items[0].status.conditions[0] = {type: "Ready", status: "False", reason: "CentralNotReady", message: "CentralReady=False (CentralNotExternallyReachable)"}'
	verify_fails "FAIL compute-chassis: the OVNChassis lab-chassis is not Ready: CentralReady=False (CentralNotExternallyReachable)" 23 24

	compute_cloud
	hub_file_edit metadataagents.json '.items = []'
	verify_fails "FAIL compute-metadata-agent: no NeutronMetadataAgent in openstack names sandbox-compute" 23 24
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh skips the checks of the nodes and the server, naming compute-pool, for a pool without a node" {
	compute_cloud
	hub_file_edit novacomputes.json '.items[0].status.nodes = []'
	verify_fails "FAIL compute-pool: the pool lab has no node" 17 24
	[ "$(compute_lines)" = "FAIL compute-pool: the pool lab has no node
FAIL compute-chassis: skipped, compute-pool failed
FAIL compute-metadata-agent: skipped, compute-pool failed
FAIL compute-hypervisor: skipped, compute-pool failed
ok compute-network: the network sandbox-verify-compute-net with the subnet sandbox-verify-compute-subnet on 198.51.100.0/24 has the MTU 1442
FAIL compute-server: skipped, compute-pool failed
FAIL compute-metadata: skipped, compute-pool failed
FAIL compute-console: skipped, compute-pool failed" ]
	[ -z "$(logged 'network agent list *')" ]
}

@test "verify.sh fails compute-hypervisor for a Hypervisor that stays in another reason for 600 s, without sandbox-compute, and for an aggregate without the node" {
	compute_cloud
	hypervisor_reason Handover
	verify_fails "FAIL compute-hypervisor: the Hypervisor sandbox-compute-worker reports Onboarding Handover after 600 s, expected Succeeded" 23 24
	[ "$(grep -cxF 2 "$BATS_TEST_TMPDIR/sleep.log")" -eq 300 ]

	compute_cloud
	rm -- "$BATS_TEST_TMPDIR/hub/hypervisor.sandbox-compute-worker"
	verify_fails "FAIL compute-hypervisor: the Hypervisor sandbox-compute-worker reports Onboarding none after 600 s, expected Succeeded" 23 24

	compute_cloud
	export COMPUTE_CLUSTER_KIND=
	verify_fails "FAIL compute-hypervisor: sandbox-compute does not exist" 23 24
	unset COMPUTE_CLUSTER_KIND

	compute_cloud
	echo '{"hosts": []}' >"$BATS_TEST_TMPDIR/aggregate.json"
	verify_fails "FAIL compute-hypervisor: the aggregate sandbox does not list sandbox-compute-worker as a host" 23 24
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh fails compute-network for another MTU, and skips the three checks after it, naming compute-network" {
	compute_cloud
	export COMPUTE_MTU=1500
	verify_fails "FAIL compute-network: the network sandbox-verify-compute-net has the MTU 1500, expected 1442" 20 24
	[ "$(compute_lines | tail -n 3)" = "FAIL compute-server: skipped, compute-network failed
FAIL compute-metadata: skipped, compute-network failed
FAIL compute-console: skipped, compute-network failed" ]
	[ -z "$(logged 'server create *')" ]
}

@test "verify.sh fails compute-server with the fault of a server in ERROR, for one still building after 600 s or on another host, and with the module hypervisor-fixtures for a missing image or flavor" {
	compute_cloud
	export COMPUTE_SERVER_STATUS=ERROR FAULT='No valid host was found. There are not enough hosts available.'
	verify_fails "FAIL compute-server: the server sandbox-verify-compute-server is 'ERROR', expected ACTIVE: No valid host was found. There are not enough hosts available." 21 24
	[ "$(compute_lines | tail -n 2)" = "FAIL compute-metadata: skipped, compute-server failed
FAIL compute-console: skipped, compute-server failed" ]
	# The CLI waits for no status; the check reads it.
	[ -z "$(logged 'server create * --wait *')" ]

	compute_cloud
	rm -f -- "$BATS_TEST_TMPDIR/sleep.log"
	export COMPUTE_SERVER_STATUS=BUILD
	verify_fails "FAIL compute-server: the server sandbox-verify-compute-server is 'BUILD' after 600 s, expected ACTIVE" 21 24
	[ "$(grep -cxF 2 "$BATS_TEST_TMPDIR/sleep.log")" -eq 300 ]

	compute_cloud
	export COMPUTE_SERVER_STATUS=ACTIVE COMPUTE_SERVER_HOST=sandbox-compute-worker2
	verify_fails "FAIL compute-server: the server sandbox-verify-compute-server is ACTIVE on 'sandbox-compute-worker2', expected sandbox-compute-worker" 21 24
	unset COMPUTE_SERVER_HOST

	compute_cloud
	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export COMPUTE_SERVER_STATUS=ACTIVE STUB_FAILS='image show cirros-kvm *' STUB_ERROR='No Image found for cirros-kvm'
	verify_fails "FAIL compute-server: the image cirros-kvm, which the module hypervisor-fixtures creates: No Image found for cirros-kvm" 21 24
	[ -z "$(logged 'server create *')" ]

	compute_cloud
	export STUB_FAILS='flavor show 1 *' STUB_ERROR='No Flavor found for 1'
	verify_fails "FAIL compute-server: the flavor 1, which the module hypervisor-fixtures creates: No Flavor found for 1" 21 24
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh fails compute-metadata at once when cirros failed to read its instance id, and after 300 s without either line" {
	compute_cloud
	printf '%s\r\n' 'checking http://169.254.169.254/2009-04-04/instance-id' \
		'failed 20/20: up 182.10. request failed' 'failed to read iid from metadata. tried 20' >"$BATS_TEST_TMPDIR/console.log"
	verify_fails "FAIL compute-metadata: cirros on sandbox-verify-compute-server failed to read iid from metadata" 23 24
	[ ! -e "$BATS_TEST_TMPDIR/sleep.log" ] || [ "$(grep -cxF 2 "$BATS_TEST_TMPDIR/sleep.log")" -eq 0 ]

	compute_cloud
	echo 'Booting from ROM...' >"$BATS_TEST_TMPDIR/console.log"
	verify_fails "FAIL compute-metadata: the console log of sandbox-verify-compute-server shows no instance id after 300 s" 23 24
	[ "$(grep -cxF 2 "$BATS_TEST_TMPDIR/sleep.log")" -eq 150 ]
}

@test "verify.sh fails compute-console without openssl in PATH" {
	local tool
	compute_cloud
	controlplane_services nova keystone
	hub_edit '.spec.services.nova.consoleProxy = {gateway: {hostname: "nova-console.172-30-255-10.nip.io"}}'
	unset -f openssl
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	for tool in dirname mktemp rm grep cat jq mkdir mv tail head tr stat truncate; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 1 ]
	[ "$(compute_lines | tail -n 1)" = "FAIL compute-console: openssl not found in PATH" ]
	[ "${lines[-1]}" = "verify: 12 of 13 checks passed" ]
}

@test "verify.sh fails compute-console for an answer without 101 and for one without the RFB greeting" {
	compute_cloud
	export WS_STATUS='HTTP/1.1 400 Bad Request'
	verify_fails "FAIL compute-console: the console proxy answered the WebSocket upgrade without 101: HTTP/1.1 400 Bad Request" 23 24

	compute_cloud
	export WS_STATUS='HTTP/1.1 101 Switching Protocols' RFB_GREETING=
	verify_fails "FAIL compute-console: the WebSocket to the console proxy relayed no RFB 003. greeting of the server's VNC" 23 24

	compute_cloud
	export CONSOLE_STATUS=404
	verify_fails "FAIL compute-console: the console page https://nova-console.172-30-255-10.nip.io/vnc_lite.html answered 404, expected 200" 23 24
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh fails compute-pool with the last line of kubectl and skips the other seven when it cannot read the pools, and names the first line of openstack's error" {
	compute_cloud
	export KUBECTL_FAILS=novacomputes.json
	verify_fails "FAIL compute-pool: cannot read the NovaComputes of openstack: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 16 24
	[ "$(compute_lines | sed 1d)" = "FAIL compute-chassis: skipped, compute-pool failed
FAIL compute-metadata-agent: skipped, compute-pool failed
FAIL compute-hypervisor: skipped, compute-pool failed
FAIL compute-network: skipped, compute-pool failed
FAIL compute-server: skipped, compute-pool failed
FAIL compute-metadata: skipped, compute-pool failed
FAIL compute-console: skipped, compute-pool failed" ]
	[ -z "$(logged '*sandbox-verify-compute*')" ]
	unset KUBECTL_FAILS

	compute_cloud
	export KUBECTL_FAILS=novacompute-crd
	verify_fails "FAIL compute-pool: cannot read the NovaComputes of openstack: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 16 24
	unset KUBECTL_FAILS

	compute_cloud
	export STUB_FAILS='network agent list *' STUB_ERROR='Unable to establish connection to https://neutron.172-30-255-10.nip.io/v2.0/agents
Connection refused'
	verify_fails "FAIL compute-chassis: Unable to establish connection to https://neutron.172-30-255-10.nip.io/v2.0/agents" 22 24
	grep -qxF "FAIL compute-metadata-agent: Unable to establish connection to https://neutron.172-30-255-10.nip.io/v2.0/agents" <<<"$output"
	[ "$(compute_lines | wc -l)" -eq 8 ]
}

@test "verify.sh deletes the server, the subnet and the network of an earlier run before it creates, and what it created after a failed check" {
	compute_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	# No check polls on a healthy cloud; the one pause of 5 s holds the
	# WebSocket open.
	[ "$(<"$BATS_TEST_TMPDIR/sleep.log")" = 5 ]
	runs_before 'server delete --wait sandbox-verify-compute-server' 'network create * sandbox-verify-compute-net'
	runs_before 'subnet delete sandbox-verify-compute-subnet' 'network create * sandbox-verify-compute-net'
	runs_before 'network delete sandbox-verify-compute-net' 'network create * sandbox-verify-compute-net'
	runs_before 'console url show *' 'server delete --wait sandbox-verify-compute-server'

	compute_cloud
	rm -- "$BATS_TEST_TMPDIR/openstack.log"
	export COMPUTE_SERVER_STATUS=ERROR
	verify_fails "FAIL compute-server: the server sandbox-verify-compute-server is 'ERROR', expected ACTIVE: " 21 24
	runs_before 'server create * sandbox-verify-compute-server' 'server delete --wait sandbox-verify-compute-server'
	# The last delete of the server comes before the first delete of the
	# subnet by its id, which only the cleanup after the checks runs.
	[ "$(logged 'server delete --wait sandbox-verify-compute-server' | tail -n 1)" -lt "$(logged 'subnet delete id-sandbox-verify-compute-subnet' | head -n 1)" ]
	runs_before 'subnet delete id-sandbox-verify-compute-subnet' 'network delete id-sandbox-verify-compute-net'
}

@test "verify.sh passes the console token to no command as an argument and prints it on no line" {
	compute_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[[ $output != *"$CONSOLE_TOKEN"* ]]
	run ! grep -rlF -- "$CONSOLE_TOKEN" "$BATS_TEST_TMPDIR/openstack.log" "$BATS_TEST_TMPDIR/kubectl.log" \
		"$BATS_TEST_TMPDIR/curl.log" "$BATS_TEST_TMPDIR/openssl.log"
	# It reaches openssl on stdin.
	grep -qF -- "$CONSOLE_TOKEN" "$BATS_TEST_TMPDIR/openssl.stdin"
}

@test "verify.sh runs no order check for a ControlPlane without a namespace assigned on the management cluster" {
	local case
	healthy_cloud
	for case in absent empty target-only; do
		controlplane_services horizon nova cinder neutron barbican placement glance keystone
		case $case in
		empty) hub_edit '.spec.namespaceAssignments = []' ;;
		target-only)
			hub_edit '.spec.namespaceAssignments = [{namespace: "workflow", targetClusterRef: {name: "compute"},
				allowedRoles: ["member"], allowCatalogEntries: true}]'
			;;
		esac
		rm -f -- "$BATS_TEST_TMPDIR/kubectl.log"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 0 ]
		[[ $output != *orders-* ]]
		[ "${lines[-1]}" = "verify: 16 of 16 checks passed" ]
		run ! grep -qE ' (apply|delete|patch) |keystoneusers|secrets,' "$BATS_TEST_TMPDIR/kubectl.log"
	done
}

@test "verify.sh passes the five order checks after those of the services, with seven scratch orders on a managed bus" {
	local ref='{"controlPlaneRef":{"name":"controlplane","namespace":"openstack"}}'
	orders_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$(check_ids)" = keystone-token,keystone-catalog,glance-catalog,glance-image,placement-catalog,placement-classes,barbican-catalog,barbican-secret,neutron-catalog,neutron-network,cinder-catalog,cinder-volume,nova-catalog,nova-services,nova-server,horizon-login,orders-ready,orders-secrets,orders-converge,orders-rotation,orders-teardown ]
	[ "$(printf '%s\n' "${lines[@]:16}")" = "ok orders-ready: 7 orders in workflow are Ready
ok orders-secrets: 4 credentials Secrets sit beside their orders in workflow
ok orders-converge: the 7 scratch orders in workflow are Ready with their Secrets
ok orders-rotation: sandbox-verify-appcred rotated to generation 2 on its schedule, generation 1 authenticated inside the grace period and was refused after it
ok orders-teardown: the 7 scratch orders are gone with their Secrets, their children and their user, project and catalog row
verify: 21 of 21 checks passed" ]

	# One apply of the seven scratch orders, and the schedule turned off
	# once generation 2 is there.
	[ ! -e "$BATS_TEST_TMPDIR/applied.2.yaml" ]
	[ "$(yq ea -o=json -I=0 '[[.kind, .metadata.name, .metadata.namespace, .spec]]' "$BATS_TEST_TMPDIR/applied.1.yaml")" = \
		"$(jq -n -c --argjson ref "$ref" '[
		["KeystoneUser", "sandbox-verify", "workflow", $ref],
		["KeystoneProject", "sandbox-verify-project", "workflow", $ref],
		["KeystoneRoleAssignment", "sandbox-verify-member", "workflow",
			$ref + {userRef: {name: "sandbox-verify"}, projectRef: {name: "sandbox-verify-project"}, role: "member"}],
		["KeystoneCatalogEntry", "sandbox-verify-catalog", "workflow", $ref + {serviceType: "sandbox-verify", serviceName: "sandbox-verify",
			endpoints: [{interface: "public", url: "https://sandbox-verify.example.test/v1"}]}],
		["KeystoneApplicationCredential", "sandbox-verify-appcred", "workflow",
			$ref + {userRef: {name: "sandbox-verify"}, projectRef: {name: "sandbox-verify-project"}, rotation: {interval: "3m", gracePeriod: "2m"}}],
		["MariaDBDatabase", "sandbox-verify-db", "workflow", $ref + {deletionPolicy: "Delete"}],
		["RabbitMQVhost", "sandbox-verify-bus", "workflow", $ref + {deletionPolicy: "Delete"}]]')" ]
	[ "$(<"$BATS_TEST_TMPDIR/patch.log")" = '{"spec":{"rotation":{"interval":"0s"}}}' ]
	# The scratch orders are gone with their Secrets and children; the
	# example orders stay.
	[ "$(jq -c '[.[].metadata.name]' "$BATS_TEST_TMPDIR/hub/orders/orders.json")" = \
		'["workflow","workflow-project","workflow-member","workflow-dns","workflow-appcred","workflow-db","workflow-bus"]' ]
	[ "$(jq '[.[] | select(.metadata.name | startswith("sandbox-verify"))] | length' \
		"$BATS_TEST_TMPDIR/hub/orders/secrets.json" "$BATS_TEST_TMPDIR/hub/orders/children.json" | paste -sd ' ')" = "0 0" ]
	# One pause for generation 2, one for the end of the grace period.
	[ "$(<"$BATS_TEST_TMPDIR/sleep.log")" = $'2\n2' ]
}

@test "verify.sh passes orders-ready for a RabbitMQVhost that reports MessagingNotManaged on a brownfield bus and MessagingNotDeclared without a bus, and orders no scratch vhost there" {
	local case reason
	for case in brownfield none; do
		rm -rf -- "$BATS_TEST_TMPDIR/hub" "$BATS_TEST_TMPDIR/scripts" "$BATS_TEST_TMPDIR"/applied.*.yaml "$BATS_TEST_TMPDIR/kubectl.log"
		healthy_cloud
		if [ "$case" = brownfield ]; then
			reason=MessagingNotManaged
			hub_edit '.spec.infrastructure.messaging = {secretRef: {name: "rabbitmq-transport-url"}, tls: {caBundleSecretRef: {name: "shared-rabbitmq-tls"}}}'
		else
			reason=MessagingNotDeclared
			controlplane_services keystone
		fi
		hub_edit '.spec.namespaceAssignments = [{namespace: "workflow", allowedRoles: ["member"], allowCatalogEntries: true}]'
		fake_apply <"$SANDBOX_ROOT/orders/workflow/orders.yaml"
		run "$BATS_TEST_TMPDIR/scripts/verify.sh"
		echo "$case: $output"
		[ "$status" -eq 0 ]
		[ "$(printf '%s\n' "${lines[@]: -6:5}")" = "ok orders-ready: 6 orders in workflow are Ready, RabbitMQVhost workflow/workflow-bus reports $reason on a bus that serves no vhost orders
ok orders-secrets: 3 credentials Secrets sit beside their orders in workflow
ok orders-converge: the 6 scratch orders in workflow are Ready with their Secrets
ok orders-rotation: sandbox-verify-appcred rotated to generation 2 on its schedule, generation 1 authenticated inside the grace period and was refused after it
ok orders-teardown: the 6 scratch orders are gone with their Secrets, their children and their user, project and catalog row" ]
		[[ ${lines[-1]} =~ ^verify:\ ([0-9]+)\ of\ ([0-9]+)\ checks\ passed$ ]]
		[ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
		[ "$(yq ea '[.kind] | join(" ")' "$BATS_TEST_TMPDIR/applied.1.yaml")" = \
			"KeystoneUser KeystoneProject KeystoneRoleAssignment KeystoneCatalogEntry KeystoneApplicationCredential MariaDBDatabase" ]
		run ! grep -q ' delete rabbitmqvhosts' "$BATS_TEST_TMPDIR/kubectl.log"
	done
}

@test "verify.sh fails orders-ready with the first sub-condition that is not True, for an order without conditions, and for a refused RabbitMQVhost on a managed bus" {
	orders_cloud
	orders_edit orders 'map(if .metadata.name == "workflow-db" then .status.conditions = [
		{type: "DeliveryReady", status: "True", reason: "Delivered"},
		{type: "DatabaseReady", status: "False", reason: "DynamicCredentialsUnavailable"},
		{type: "Ready", status: "False", reason: "NotAllReady"}] else . end)
		| map(if .metadata.name == "workflow-bus" then .status.conditions |= map(.status = "False") else . end)'
	# The first failing order of the list decides the line.
	verify_fails "FAIL orders-ready: MariaDBDatabase workflow/workflow-db is not Ready: DatabaseReady=False (DynamicCredentialsUnavailable)" 20 21
	[ "$(grep -c '^FAIL ' <<<"$output")" -eq 1 ]

	orders_edit orders 'map(if .metadata.name == "workflow-member" then del(.status) else . end)'
	verify_fails "FAIL orders-ready: KeystoneRoleAssignment workflow/workflow-member is not Ready: has no condition" 20 21

	orders_cloud
	orders_edit orders 'map(if .metadata.name == "workflow-bus" then .status.conditions = [
		{type: "VhostReady", status: "False", reason: "MessagingNotManaged"},
		{type: "DeliveryReady", status: "False", reason: "MessagingNotManaged"},
		{type: "Ready", status: "False", reason: "NotAllReady"}] else . end)'
	verify_fails "FAIL orders-ready: RabbitMQVhost workflow/workflow-bus is not Ready: VhostReady=False (MessagingNotManaged)" 20 21
}

@test "verify.sh passes orders-ready and orders-secrets for assigned namespaces without an order" {
	healthy_cloud
	hub_edit '.spec.infrastructure.messaging = {clusterRef: {name: "openstack-rabbitmq"}}
		| .spec.namespaceAssignments = [{namespace: "workflow", allowedRoles: ["member"], allowCatalogEntries: true},
			{namespace: "team-b", allowedRoles: ["reader"]}, {namespace: "absent"},
			{namespace: "remote", targetClusterRef: {name: "compute"}}]'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 0 ]
	# absent is assigned and does not exist; remote lives on another cluster.
	[ "${lines[16]}" = "ok orders-ready: no order in workflow, team-b, absent" ]
	[ "${lines[17]}" = "ok orders-secrets: 0 credentials Secrets sit beside their orders in workflow, team-b, absent" ]
	[ "${lines[-1]}" = "verify: 21 of 21 checks passed" ]
	[ "$(kubectl_calls | grep -c '^-n absent get keystoneusers.c5c3.io,')" -eq 1 ]
	run ! grep -q -- '-n remote ' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "verify.sh fails orders-secrets for a missing Secret, a Secret another object controls, a missing key and an empty value" {
	local case
	for case in \
		'map(select(.metadata.name != "workflow-db-credentials"))|the Secret workflow/workflow-db-credentials is missing' \
		'map(if .metadata.name == "workflow-db-credentials" then .metadata.ownerReferences[0].uid = "uid-elsewhere" else . end)|the Secret workflow/workflow-db-credentials is not controlled by MariaDBDatabase workflow-db' \
		'map(if .metadata.name == "workflow-credentials" then .metadata.ownerReferences[0].controller = false else . end)|the Secret workflow/workflow-credentials is not controlled by KeystoneUser workflow' \
		'map(if .metadata.name == "workflow-bus-credentials" then del(.data.vhost) else . end)|the Secret workflow/workflow-bus-credentials holds no vhost' \
		'map(if .metadata.name == "workflow-appcred-credentials" then .data.application_credential_secret = "" else . end)|the Secret workflow/workflow-appcred-credentials holds no application_credential_secret'; do
		orders_cloud
		orders_edit secrets "${case%%|*}"
		verify_fails "FAIL orders-secrets: ${case#*|}" 20 21
		[ "${lines[17]}" = "FAIL orders-secrets: ${case#*|}" ]
		[[ $output != *-of-workflow* ]]
		[[ $output != *S3cr3t* ]]
	done
}

@test "verify.sh fails the three scratch checks and creates nothing when no assigned namespace allows the role member and catalog entries" {
	local id
	healthy_cloud
	hub_edit '.spec.infrastructure.messaging = {clusterRef: {name: "openstack-rabbitmq"}}
		| .spec.namespaceAssignments = [{namespace: "workflow", allowedRoles: ["reader"], allowCatalogEntries: true},
			{namespace: "team-b", allowedRoles: ["member"]},
			{namespace: "remote", targetClusterRef: {name: "compute"}, allowedRoles: ["member"], allowCatalogEntries: true}]'
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	echo "$output"
	[ "$status" -eq 1 ]
	for id in orders-converge orders-rotation orders-teardown; do
		grep -qxF "FAIL $id: no namespace assigned on the management cluster allows the role member and catalog entries" <<<"$output"
	done
	[ "${lines[-1]}" = "verify: 18 of 21 checks passed" ]
	run ! grep -qE ' (apply|delete|patch) ' "$BATS_TEST_TMPDIR/kubectl.log"
	[ ! -e "$BATS_TEST_TMPDIR/appcred.log" ]
}

@test "verify.sh fails orders-converge with the last line of kubectl when the apply fails, and with the order that is not Ready after 300 s" {
	orders_cloud
	export KUBECTL_FAILS=apply
	verify_fails "FAIL orders-converge: cannot order in workflow: The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?" 19 21
	[ "${lines[19]}" = "FAIL orders-rotation: the scratch orders did not converge" ]
	[ "${lines[20]}" = "ok orders-teardown: the 7 scratch orders are gone with their Secrets, their children and their user, project and catalog row" ]
	# The deletes of the teardown still run after the failed apply.
	[ "$(kubectl_calls | sed -n '/^apply -f -$/,$p' | sed -n 's/^-n workflow delete \([^ ]*\) \([^ ]*\) --ignore-not-found --timeout=180s$/\1 \2/p')" = "$HOLDS" ]

	unset KUBECTL_FAILS
	orders_cloud
	export NOT_READY=sandbox-verify-db
	verify_fails "FAIL orders-converge: MariaDBDatabase sandbox-verify-db is not Ready after 300 s: DatabaseReady=False (Provisioning)" 19 21
	[ "${lines[19]}" = "FAIL orders-rotation: the scratch orders did not converge" ]
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/sleep.log")" -eq 150 ]
	[ "$(sort -u "$BATS_TEST_TMPDIR/sleep.log")" = 2 ]
	[[ ${lines[20]} == "ok orders-teardown: "* ]]
}

@test "verify.sh fails orders-rotation at each of its seven steps with the line of that step" {
	local case line refused="The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?"
	local unreachable="Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens"
	while IFS='|' read -r case line; do
		orders_cloud
		unset ROTATION APPCRED_FAILS KUBECTL_FAILS GEN1_ALIVE
		export "${case?}"
		echo "$case"
		verify_fails "FAIL orders-rotation: $line" 20 21
		[ "${lines[19]}" = "FAIL orders-rotation: $line" ]
		[[ ${lines[20]} == "ok orders-teardown: "* ]]
	done <<CASES
APPCRED_FAILS=1|generation 1 does not authenticate: $unreachable
ROTATION=stuck|sandbox-verify-appcred is at generation 1 after 300 s, expected 2
ROTATION=skipped|generation 1 was superseded before verify read generation 2
ROTATION=foreign|generation 1 was superseded before verify read generation 2
APPCRED_FAILS=2|generation 1 is refused inside its grace period: $unreachable
KUBECTL_FAILS=patch|cannot turn the schedule off: $refused
ROTATION=secret-lag|the Secret did not take generation 2 within 180 s
APPCRED_FAILS=3|generation 2 does not authenticate: $unreachable
ROTATION=kept|generation 1 is not deleted 300 s after the switch
GEN1_ALIVE=1|generation 1 still authenticates after its grace period
CASES
}

@test "verify.sh fails orders-rotation with the first line of the error when the refusal after the grace period is neither HTTP 401 nor HTTP 404" {
	orders_cloud
	export APPCRED_FAILS=4 APPCRED_ERROR="Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)
Max retries exceeded with url: /v3/auth/tokens"
	verify_fails "FAIL orders-rotation: Unable to establish connection to https://keystone.172-30-255-10.nip.io/v3/auth/tokens: HTTPSConnectionPool(host='keystone.172-30-255-10.nip.io', port=443)" 20 21
	[ "$(grep -c '' "$BATS_TEST_TMPDIR/appcred.log")" -eq 4 ]

	# Keystone refuses an expired credential with HTTP 401, a deleted one with
	# HTTP 404.
	unset APPCRED_FAILS APPCRED_ERROR
	orders_cloud
	export GEN1_REFUSAL=401
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	[[ ${lines[19]} == "ok orders-rotation: "* ]]
}

@test "verify.sh gives openstack the application credential through the environment, without the user and the password of the admin, and prints no value of a Secret" {
	local value out names="OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET OS_AUTH_TYPE OS_AUTH_URL OS_CACERT"
	orders_cloud
	run "$BATS_TEST_TMPDIR/scripts/verify.sh"
	[ "$status" -eq 0 ]
	out=$output
	# Generation 1, inside its grace period, generation 2, generation 1
	# after it.
	[ "$(<"$BATS_TEST_TMPDIR/appcred.log")" = "$names id-sandbox-verify-appcred-1
$names id-sandbox-verify-appcred-1
$names id-sandbox-verify-appcred-2
$names id-sandbox-verify-appcred-1" ]
	[ "$(grep -cxF 'token issue -f value -c id' "$BATS_TEST_TMPDIR/openstack.log")" -eq 5 ]
	run ! grep -E -e '(^| )(--insecure|-[a-zA-Z]*k)( |$)' "$BATS_TEST_TMPDIR/openstack.log"
	for value in id-sandbox-verify-appcred S3cr3t- -of-workflow -of-sandbox-verify \
		"$(printf S3cr3t-sandbox-verify-appcred-1 | base64 -w 0)" "$(printf id-sandbox-verify-appcred-1 | base64 -w 0)"; do
		[[ $out != *"$value"* ]]
		run ! grep -qF -- "$value" "$BATS_TEST_TMPDIR/openstack.log"
		run ! grep -qF -- "$value" "$BATS_TEST_TMPDIR/kubectl.log"
	done

	# Keystone names the id of a credential it cannot find; the line hides it.
	orders_cloud
	export APPCRED_FAILS=1 APPCRED_ERROR='Could not find Application Credential: id-sandbox-verify-appcred-1. (HTTP 404) (Request-ID: req-1)'
	verify_fails "FAIL orders-rotation: generation 1 does not authenticate: Could not find Application Credential: <redacted>. (HTTP 404) (Request-ID: req-1)" 20 21
	for value in id-sandbox-verify-appcred S3cr3t- -of-; do
		[[ $output != *"$value"* ]]
	done
}

@test "verify.sh deletes the scratch orders an earlier run left before it orders, and tears them down in the order of the holds after a failed check" {
	local calls
	orders_cloud
	# An interrupted run left its scratch orders.
	(
		. "$SANDBOX_ROOT/scripts/lib/orders.sh"
		orders_scratch_ns=workflow orders_refusal=
		orders_manifest
	) | fake_apply
	[ "$(jq '[.[] | select(.metadata.name | startswith("sandbox-verify"))] | length' "$BATS_TEST_TMPDIR/hub/orders/orders.json")" -eq 7 ]

	export ROTATION=stuck
	verify_fails "FAIL orders-rotation: sandbox-verify-appcred is at generation 1 after 300 s, expected 2" 20 21
	calls=$(kubectl_calls)
	# The deletes in the order of the holds come before the apply and after
	# it, and orders-ready reads the example orders alone.
	[ "$(sed -n '1,/^apply -f -$/p' <<<"$calls" | sed -n 's/^-n workflow delete \([^ ]*\) \([^ ]*\) --ignore-not-found --timeout=180s$/\1 \2/p')" = "$HOLDS" ]
	[ "$(sed -n '/^apply -f -$/,$p' <<<"$calls" | sed -n 's/^-n workflow delete \([^ ]*\) \([^ ]*\) --ignore-not-found --timeout=180s$/\1 \2/p')" = "$HOLDS" ]
	[ "$(grep -c '^-n workflow delete ' <<<"$calls")" -eq 14 ]
	[ "${lines[16]}" = "ok orders-ready: 7 orders in workflow are Ready" ]
	[[ ${lines[20]} == "ok orders-teardown: "* ]]
}

@test "verify.sh fails orders-teardown for a delete that times out, for a labelled child that is left and for a user, a project and a service left in Keystone" {
	local case
	orders_cloud
	export DELETE_TIMES_OUT=sandbox-verify-project
	verify_fails "FAIL orders-teardown: KeystoneProject sandbox-verify-project is not deleted after 180 s: error: timed out waiting for the condition on keystoneprojects.c5c3.io/sandbox-verify-project" 20 21
	# The deletes after the one that failed still run.
	[ "$(kubectl_calls | sed -n '/^apply -f -$/,$p' | sed -n 's/^-n workflow delete \([^ ]*\) \([^ ]*\) --ignore-not-found --timeout=180s$/\1 \2/p')" = "$HOLDS" ]
	unset DELETE_TIMES_OUT

	orders_cloud
	export LEFT_CHILD=sandbox-verify-db
	verify_fails "FAIL orders-teardown: Database openstack/sandbox-verify-db is left after the teardown" 20 21
	unset LEFT_CHILD

	for case in \
		'KEYSTONE_USERS=admin workflow sandbox-verify|the user sandbox-verify is left in Keystone' \
		'KEYSTONE_PROJECTS=admin sandbox-verify-project|the project sandbox-verify-project is left in Keystone' \
		'KEYSTONE_SERVICES=identity sandbox-verify dns|the service sandbox-verify is left in Keystone'; do
		orders_cloud
		export "${case%%|*}"
		verify_fails "FAIL orders-teardown: ${case#*|}" 20 21
		unset KEYSTONE_USERS KEYSTONE_PROJECTS KEYSTONE_SERVICES
	done
}

@test "verify.sh fails each order check with the last line of kubectl when a read fails" {
	local refused="The connection to the server 127.0.0.1:40001 was refused - did you specify the right host or port?"
	orders_cloud
	export KUBECTL_FAILS=orders.workflow
	verify_fails "FAIL orders-ready: cannot read the orders of workflow: $refused" 17 21
	[ "${lines[17]}" = "FAIL orders-secrets: cannot read the orders of workflow: $refused" ]
	[ "${lines[18]}" = "FAIL orders-converge: cannot read the orders of workflow: $refused" ]

	orders_cloud
	export KUBECTL_FAILS=secret.workflow.workflow-credentials
	verify_fails "FAIL orders-secrets: cannot read the Secret workflow/workflow-credentials: $refused" 20 21

	orders_cloud
	export KUBECTL_FAILS=secret.workflow.sandbox-verify-appcred-credentials
	verify_fails "FAIL orders-converge: cannot read the Secret workflow/sandbox-verify-appcred-credentials: $refused" 19 21

	orders_cloud
	export KUBECTL_FAILS=appcred
	verify_fails "FAIL orders-rotation: cannot read the KeystoneApplicationCredential workflow/sandbox-verify-appcred: $refused" 20 21

	orders_cloud
	export KUBECTL_FAILS=children.sandbox-verify-appcred
	verify_fails "FAIL orders-teardown: $refused" 20 21

	unset KUBECTL_FAILS
	orders_cloud
	export STUB_FAILS='service list *' STUB_ERROR='Failed to discover available identity versions when contacting https://keystone.172-30-255-10.nip.io/v3.
SSL exception'
	verify_fails "FAIL orders-teardown: Failed to discover available identity versions when contacting https://keystone.172-30-255-10.nip.io/v3." 20 21
}
