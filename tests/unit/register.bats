#!/usr/bin/env bats
# scripts/lib/register.sh and scripts/register.sh: the registration of a
# cluster with the CobaltCore operators, with kubectl and kind replaced by
# functions.

setup() {
	load helpers
	export CALLS=$BATS_TEST_TMPDIR/calls TOKEN=sandbox-unit-token-0123456789
	KUBECONFIG_OK='apiVersion: v1
kind: Config
clusters:
- name: target
  cluster:
    server: https://target.example.test:6443
users:
- name: target-cluster-access
  user:
    token: abc
contexts:
- name: target
  context:
    cluster: target
    user: target-cluster-access
current-context: target'
}

# hub_answers: replaces hub_kubectl with a function that records each call in
# calls, answers the dry-run create of a registration Secret as kubectl does
# and writes each applied manifest to applied.json.
hub_answers() {
	hub_kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		case $* in
		"-n c5c3-clusters create secret generic "*" --from-file=kubeconfig=/dev/stdin --dry-run=client -o json")
			base64 -w0 | jq -R --arg name "$6" \
				'{apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: "c5c3-clusters", creationTimestamp: null}, data: {kubeconfig: .}}' ;;
		"apply --server-side --force-conflicts --field-manager=sandbox -f -") cat >"$BATS_TEST_TMPDIR/applied.json" ;;
		*) return 1 ;;
		esac
	}
}

# refuses <message> <name> <namespaces> <kubeconfig>: runs register_cluster
# with the kubeconfig on stdin and expects it to fail with the message,
# without a call of kubectl.
refuses() {
	run register_cluster "$2" "$3" <<<"$4"
	echo "$2 '$3': $output"
	[ "$status" -eq 1 ]
	[ "$output" = "error: $1" ]
	[ ! -e "$CALLS" ]
}

# token_secret <token> <ca.crt>: prints the token Secret of the access chart
# with both values base64-encoded, as kubectl -o json prints it.
token_secret() {
	jq -n --arg token "$1" --arg ca "$2" '{apiVersion: "v1", kind: "Secret",
		metadata: {name: "target-cluster-access-token", namespace: "c5c3-access"},
		type: "kubernetes.io/service-account-token",
		data: {token: ($token | @base64), "ca.crt": ($ca | @base64), namespace: ("c5c3-access" | @base64)}}'
}

# compute_answers <secret>: replaces kubectl with a function that prints the
# secret, which may be empty, for the read of the token Secret on
# sandbox-compute, and kind with one that prints the internal kubeconfig of
# sandbox-compute. Both, and jq and yq, record their arguments in calls.
compute_answers() {
	export SECRET=$1
	kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		[ "$*" = "--kubeconfig $SANDBOX_ROOT/.sandbox/kubeconfig/compute.yaml -n c5c3-access get secret target-cluster-access-token --ignore-not-found -o json" ] ||
			return 1
		printf '%s' "$SECRET"
	}
	kind() {
		printf 'kind %s\n' "$*" >>"$CALLS"
		[ "$*" = "get kubeconfig --internal --name sandbox-compute" ] || return 1
		printf 'apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: Y2E=\n    server: https://sandbox-compute-control-plane:6443\n  name: kind-sandbox-compute\n'
	}
	jq() {
		printf 'jq %s\n' "$*" >>"$CALLS"
		command jq "$@"
	}
	yq() {
		printf 'yq %s\n' "$*" >>"$CALLS"
		command yq "$@"
	}
}

# attached <profile modules of compute>: loads a profile with the management
# and the compute cluster and the modules given for compute, both attached,
# and records each restore of a kubeconfig file in restored.
attached() {
	profile_with "clusters: [management, compute]
modules:
  management: [test]
  compute: [$1]"
	profile_load
	attached_roles() { echo "management compute"; }
	restore_kubeconfig() { echo "$1" >>"$BATS_TEST_TMPDIR/restored"; }
}

@test "register_cluster refuses an empty kubeconfig and calls no kubectl" {
	hub_answers
	run register_cluster sandbox-compute openstack </dev/null
	[ "$status" -eq 1 ]
	[ "$output" = "error: register: the kubeconfig of sandbox-compute is empty" ]
	[ ! -e "$CALLS" ]
}

@test "register_cluster names what is wrong with the name, the namespaces or the kubeconfig and calls no kubectl" {
	local no_server exec provider long
	hub_answers
	no_server=$(yq '.clusters[0].cluster |= del(.server)' - <<<"$KUBECONFIG_OK")
	exec=$(yq '.users[0].user = {"exec": {"apiVersion": "client.authentication.k8s.io/v1", "command": "aws"}}' - <<<"$KUBECONFIG_OK")
	provider=$(yq '.users += [{"name": "other", "user": {"auth-provider": {"name": "oidc"}}}]' - <<<"$KUBECONFIG_OK")
	long=$(printf 'a%.0s' {1..254})
	refuses "register: the kubeconfig of sandbox-x names no server" sandbox-x openstack "$no_server"
	refuses "register: the kubeconfig of sandbox-x names no server" sandbox-x openstack "just text"
	refuses "register: the kubeconfig of sandbox-x uses a credential plugin, which the operators refuse; use a token or a client certificate" \
		sandbox-x openstack "$exec"
	refuses "register: the kubeconfig of sandbox-x uses a credential plugin, which the operators refuse; use a token or a client certificate" \
		sandbox-x openstack "$provider"
	refuses "register: 'Bad_Name' is not a cluster name, expected a DNS-1123 subdomain" Bad_Name openstack "$KUBECONFIG_OK"
	refuses "register: '$long' is not a cluster name, expected a DNS-1123 subdomain" "$long" openstack "$KUBECONFIG_OK"
	refuses "register: '-x' is not a cluster name, expected a DNS-1123 subdomain" -x openstack "$KUBECONFIG_OK"
	refuses "register: no namespace given" sandbox-x "" "$KUBECONFIG_OK"
	refuses "register: 'Bad' is not a namespace name" sandbox-x Bad "$KUBECONFIG_OK"
	refuses "register: '' is not a namespace name" sandbox-x openstack, "$KUBECONFIG_OK"
	refuses "register: '' is not a namespace name" sandbox-x openstack,,other "$KUBECONFIG_OK"
	refuses "register: '$(printf 'openstack\ntenant')' is not a namespace name" sandbox-x "$(printf 'openstack\ntenant')" "$KUBECONFIG_OK"
}

@test "register_cluster names the error of yq for a kubeconfig that does not parse" {
	hub_answers
	run register_cluster sandbox-x openstack <<<'clusters: [unclosed'
	[ "$status" -eq 1 ]
	[[ $output == "error: register: the kubeconfig of sandbox-x: "?* ]]
	[[ $output != *"Error: "* ]]
	[ ! -e "$CALLS" ]
}

@test "register_cluster applies the Namespace c5c3-clusters and the Secret with the kubeconfig, the namespaces and the labels" {
	hub_answers
	run register_cluster sandbox-compute openstack,other compute <<<"$KUBECONFIG_OK"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(jq -c '[.apiVersion, .kind, (.items | map(.kind)), .items[0].metadata.name]' "$BATS_TEST_TMPDIR/applied.json")" = \
		'["v1","List",["Namespace","Secret"],"c5c3-clusters"]' ]
	[ "$(jq -c '.items[1] | [.metadata.name, .metadata.namespace, .metadata.labels, (.data | keys)]' "$BATS_TEST_TMPDIR/applied.json")" = \
		'["sandbox-compute","c5c3-clusters",{"sigs.k8s.io/multicluster-runtime-kubeconfig":"true","sandbox.c5c3.io/cluster":"compute"},["kubeconfig","namespaces"]]' ]
	[ "$(jq -r '.items[1].data.namespaces | @base64d' "$BATS_TEST_TMPDIR/applied.json")" = openstack,other ]
	[ "$(jq -r '.items[1].data.kubeconfig | @base64d' "$BATS_TEST_TMPDIR/applied.json")" = "$KUBECONFIG_OK" ]

	run register_cluster sandbox-verify-external openstack <<<"$KUBECONFIG_OK"
	[ "$status" -eq 0 ]
	[ "$(jq -c '.items[1] | [.metadata.name, .metadata.labels]' "$BATS_TEST_TMPDIR/applied.json")" = \
		'["sandbox-verify-external",{"sigs.k8s.io/multicluster-runtime-kubeconfig":"true"}]' ]
}

@test "register_cluster hands a kubeconfig larger than a pipe buffer to no file" {
	hub_answers
	# A command whose stdin is a regular file notes its name in files.
	jq() {
		[ ! -f /dev/stdin ] || echo jq >>"$BATS_TEST_TMPDIR/files"
		command jq "$@"
	}
	yq() {
		[ ! -f /dev/stdin ] || echo yq >>"$BATS_TEST_TMPDIR/files"
		command yq "$@"
	}
	eval "$(declare -f hub_kubectl | sed '1s/hub_kubectl/_answer/')"
	hub_kubectl() {
		[ ! -f /dev/stdin ] || echo "kubectl $1" >>"$BATS_TEST_TMPDIR/files"
		_answer "$@"
	}
	run register_cluster sandbox-compute openstack < <(printf '%s\n# ' "$KUBECONFIG_OK"; head -c 200000 /dev/zero | tr '\0' a; echo)
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/files" ]
	[ "$(jq -r '.items[1].data.kubeconfig | @base64d | length' "$BATS_TEST_TMPDIR/applied.json")" -gt 200000 ]
}

@test "register_cluster fails with the last line of kubectl when it cannot write the Secret" {
	hub_answers
	eval "$(declare -f hub_kubectl | sed '1s/hub_kubectl/_answer/')"
	hub_kubectl() {
		case $1 in
		apply) printf 'Warning: x\nError from server (Forbidden): secrets is forbidden\n' >&2; return 1 ;;
		*) _answer "$@" ;;
		esac
	}
	run register_cluster sandbox-compute openstack compute <<<"$KUBECONFIG_OK"
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot write the Secret c5c3-clusters/sandbox-compute on sandbox-management: Error from server (Forbidden): secrets is forbidden" ]
}

@test "registration_kubeconfig returns 1 without output while the token Secret is absent or not filled in" {
	local secret
	for secret in "" "$(token_secret "" ca)" "$(token_secret "$TOKEN" "")" '{"kind": "Secret"}'; do
		compute_answers "$secret"
		run registration_kubeconfig compute
		echo "$secret"
		[ "$status" -eq 1 ]
		[ "$output" = "" ]
	done
	# kind is asked only once the token is there.
	! grep -q '^kind ' "$CALLS"
}

@test "registration_kubeconfig prints the kubeconfig of the ServiceAccount with the token in no argument" {
	compute_answers "$(token_secret "$TOKEN" "-----BEGIN CERTIFICATE-----")"
	run registration_kubeconfig compute
	[ "$status" -eq 0 ]
	[ "$(jq -c '[.clusters, .contexts, .["current-context"]]' <<<"$output")" = \
		"[[{\"name\":\"sandbox-compute\",\"cluster\":{\"server\":\"https://sandbox-compute-control-plane:6443\",\"certificate-authority-data\":\"$(printf '%s' -----BEGIN\ CERTIFICATE----- | base64 -w0)\"}}],[{\"name\":\"sandbox-compute\",\"context\":{\"cluster\":\"sandbox-compute\",\"user\":\"target-cluster-access\"}}],\"sandbox-compute\"]" ]
	[ "$(jq -c '.users' <<<"$output")" = "[{\"name\":\"target-cluster-access\",\"user\":{\"token\":\"$TOKEN\"}}]" ]
	[ "$(jq -r '.clusters[0].cluster["certificate-authority-data"]' <<<"$output")" = "$(jq -r '.data["ca.crt"]' <<<"$SECRET")" ]
	grep -q '^kind get kubeconfig --internal --name sandbox-compute$' "$CALLS"
	! grep -qF -e "$TOKEN" -e "$(printf '%s' "$TOKEN" | base64 -w0)" "$CALLS"
}

@test "registration_kubeconfig returns 2 with the last line of kubectl when it cannot read the token Secret" {
	kubectl() {
		printf 'E1125 memcache.go\nconnection refused\n' >&2
		return 1
	}
	run registration_kubeconfig compute
	[ "$status" -eq 2 ]
	[ "$output" = "connection refused" ]
}

@test "registration_kubeconfig dies when kind cannot read the internal kubeconfig" {
	compute_answers "$(token_secret "$TOKEN" ca)"
	kind() { return 1; }
	run registration_kubeconfig compute
	[ "$status" -eq 1 ]
	[ "$output" = "error: register: cannot read the internal kubeconfig of sandbox-compute" ]
}

@test "ensure_registrations registers the compute cluster under its kind name with the kubeconfig of the access chart" {
	attached access
	compute_answers "$(token_secret "$TOKEN" ca)"
	register_cluster() {
		printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/register.args"
		cat >"$BATS_TEST_TMPDIR/register.in"
	}
	run ensure_registrations
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": registering sandbox-compute in c5c3-clusters for the namespaces openstack" ]]
	[ "$(<"$BATS_TEST_TMPDIR/register.args")" = "sandbox-compute openstack compute" ]
	# The token is read with the kubeconfig file of the role.
	[ "$(<"$BATS_TEST_TMPDIR/restored")" = compute ]
	[ "$(jq -r '[.clusters[0].cluster.server, .users[0].user.token] | join(" ")' "$BATS_TEST_TMPDIR/register.in")" = \
		"https://sandbox-compute-control-plane:6443 $TOKEN" ]
}

@test "ensure_registrations fails after SANDBOX_STAGE_TIMEOUT when the token Secret holds no token" {
	attached access
	compute_answers ""
	export SANDBOX_STAGE_TIMEOUT=1
	run ensure_registrations
	[ "$status" -eq 1 ]
	[[ ${lines[0]} == *": registering sandbox-compute in c5c3-clusters for the namespaces openstack" ]]
	[ "${lines[-1]}" = "error: register: the Secret c5c3-access/target-cluster-access-token on sandbox-compute holds no token after 1 s; make status shows the stage compute-access" ]
}

@test "ensure_registrations names the error of kubectl when the last read of the token Secret failed" {
	attached access
	export SANDBOX_STAGE_TIMEOUT=1
	kubectl() {
		printf 'E1125 memcache.go\nconnection refused\n' >&2
		return 1
	}
	run ensure_registrations
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: register: the Secret c5c3-access/target-cluster-access-token on sandbox-compute holds no token after 1 s; make status shows the stage compute-access; kubectl: connection refused" ]
}

@test "ensure_registrations stops at once when kind cannot read the internal kubeconfig" {
	attached access
	compute_answers "$(token_secret "$TOKEN" ca)"
	kind() { return 1; }
	run ensure_registrations
	[ "$status" -eq 1 ]
	[ "${#lines[@]}" -eq 2 ]
	[ "${lines[1]}" = "error: register: cannot read the internal kubeconfig of sandbox-compute" ]
}

@test "ensure_registrations removes the registration of a compute cluster without access and applies nothing" {
	attached test
	hub_kubectl() {
		printf 'kubectl %s\n' "$*" >>"$CALLS"
		[ "$*" = "-n c5c3-clusters delete secret -l sandbox.c5c3.io/cluster=compute --ignore-not-found -o name" ] || return 1
		echo secret/sandbox-compute
	}
	run ensure_registrations
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[[ ${lines[0]} == *": removed the registration of sandbox-compute" ]]
	[ "$(<"$CALLS")" = "kubectl -n c5c3-clusters delete secret -l sandbox.c5c3.io/cluster=compute --ignore-not-found -o name" ]

	# Nothing deleted, nothing logged; kubectl says so on stdout.
	hub_kubectl() { echo "No resources found"; }
	run ensure_registrations
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ ! -e "$BATS_TEST_TMPDIR/restored" ]
}

@test "ensure_registrations fails with the last line of kubectl when it cannot remove a registration" {
	attached test
	hub_kubectl() {
		printf 'Warning: x\nError from server (Forbidden): secrets is forbidden\n' >&2
		return 1
	}
	run ensure_registrations
	[ "$status" -eq 1 ]
	[ "$output" = "error: cannot remove the registration of sandbox-compute: Error from server (Forbidden): secrets is forbidden" ]
}

@test "ensure_registrations leaves the management cluster alone" {
	profile_with 'clusters: [management]'
	profile_load
	attached_roles() { echo management; }
	hub_kubectl() { echo "unit test called hub_kubectl $*" >&2; return 1; }
	run ensure_registrations
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

# register_host <kind clusters>: copies scripts/ into the test's directory
# with a kubeconfig file for management, and exports docker, kind and
# kubectl for the kind clusters given, every node on the sandbox network,
# and a management cluster that answers the registration.
register_host() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	mkdir -p -- "$BATS_TEST_TMPDIR/.sandbox/kubeconfig"
	: >"$BATS_TEST_TMPDIR/.sandbox/kubeconfig/management.yaml"
	export CLUSTERS=$1 APPLIED=$BATS_TEST_TMPDIR/applied.json
	docker() { echo 'cobaltcore-sandbox '; }
	kind() {
		case $* in
		"get clusters") [ -z "$CLUSTERS" ] || echo "$CLUSTERS" ;;
		"get nodes --name "*) echo "$4-control-plane" ;;
		*) return 1 ;;
		esac
	}
	kubectl() {
		case $* in
		*" -n c5c3-clusters create secret generic "*" --from-file=kubeconfig=/dev/stdin --dry-run=client -o json")
			base64 -w0 | command jq -R --arg name "$8" '{apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: "c5c3-clusters"}, data: {kubeconfig: .}}' ;;
		*" apply --server-side --force-conflicts --field-manager=sandbox -f -") cat >"$APPLIED" ;;
		*) return 1 ;;
		esac
	}
	export -f docker kind kubectl
}

@test "register.sh prints its usage and exits 2 for a wrong number of arguments" {
	register_host sandbox-management
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x
	[ "$status" -eq 2 ]
	[ "$output" = "usage: scripts/register.sh <name> <kubeconfig-file> [<namespaces>]" ]
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x - openstack extra
	[ "$status" -eq 2 ]
	[ ! -e "$APPLIED" ]
}

@test "register.sh fails for a missing kubeconfig file and without a management cluster" {
	register_host sandbox-management
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x "$BATS_TEST_TMPDIR/missing.yaml"
	[ "$status" -eq 1 ]
	[ "$output" = "error: register: $BATS_TEST_TMPDIR/missing.yaml not found" ]
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x "$BATS_TEST_TMPDIR"
	[ "$status" -eq 1 ]
	[ "$output" = "error: register: $BATS_TEST_TMPDIR not found" ]

	register_host ""
	printf '%s\n' "$KUBECONFIG_OK" >"$BATS_TEST_TMPDIR/target.yaml"
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x "$BATS_TEST_TMPDIR/target.yaml"
	[ "$status" -eq 1 ]
	[ "$output" = "error: register: sandbox-management does not exist; run make up" ]
	[ ! -e "$APPLIED" ]
}

@test "register.sh registers the kubeconfig on stdin for openstack and without the label of a role" {
	register_host sandbox-management
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-verify-external - <<<"$KUBECONFIG_OK"
	[ "$status" -eq 0 ]
	[ "$output" = "register: registered sandbox-verify-external in c5c3-clusters for the namespaces openstack" ]
	[ "$(jq -c '.items[1] | [.metadata.name, .metadata.labels, (.data.namespaces | @base64d)]' "$APPLIED")" = \
		'["sandbox-verify-external",{"sigs.k8s.io/multicluster-runtime-kubeconfig":"true"},"openstack"]' ]
	[ "$(jq -r '.items[1].data.kubeconfig | @base64d' "$APPLIED")" = "$KUBECONFIG_OK" ]

	printf '%s\n' "$KUBECONFIG_OK" >"$BATS_TEST_TMPDIR/target.yaml"
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-x "$BATS_TEST_TMPDIR/target.yaml" openstack,tenant
	[ "$status" -eq 0 ]
	[ "$(jq -r '.items[1].data.namespaces | @base64d' "$APPLIED")" = openstack,tenant ]

	# A process substitution is a pipe, not a regular file.
	rm -f -- "$APPLIED"
	run "$BATS_TEST_TMPDIR/scripts/register.sh" sandbox-y <(printf '%s\n' "$KUBECONFIG_OK")
	[ "$status" -eq 0 ]
	[ "$(jq -r '.items[1].metadata.name' "$APPLIED")" = sandbox-y ]
}
