#!/usr/bin/env bats
# The tree Flux reads: the stage contract of every module of a cluster, the
# kustomization of each cluster, and no literal address in a manifest. The
# modules of compute/ and storage/ copy objects of upstream under names of
# their own, and the tests compare each copy with upstream's file, so this
# file needs the checkout of make vendor.

setup() {
	load helpers
}

# stage_contract <root> <role>/<module>: checks the directory
# <root>/clusters/<role>/<module>/ against the stage contract and prints the
# number of the first point it breaks.
stage_contract() {
	local root=$1 role=${2%/*} module=${2#*/} dir path dep names
	dir=$root/clusters/$2

	# 1. A Component whose resources are exactly stage.yaml.
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind, .resources]' "$dir/kustomization.yaml")" = \
		'["kustomize.config.k8s.io/v1alpha1","Component",["stage.yaml"]]' ] || { echo 1; return 1; }

	# 2. One Kustomization <role>-<module> in flux-system that prunes, waits
	# and reads the OCIRepository sandbox.
	[ "$(yq ea '[.] | length' "$dir/stage.yaml")" = 1 ] &&
		[ "$(yq -o=json -I=0 '[.apiVersion, .kind, .metadata.name, .metadata.namespace, .spec.prune, .spec.wait, .spec.sourceRef.kind, .spec.sourceRef.name]' "$dir/stage.yaml")" = \
			"[\"kustomize.toolkit.fluxcd.io/v1\",\"Kustomization\",\"$role-$module\",\"flux-system\",true,true,\"OCIRepository\",\"sandbox\"]" ] ||
		{ echo 2; return 1; }

	# 3. spec.path names a directory of the tree with a kustomization.yaml.
	path=$(yq '.spec.path' "$dir/stage.yaml")
	[[ $path == ./* && $path != *..* ]] && [ -f "$root/${path#./}/kustomization.yaml" ] || { echo 3; return 1; }

	# 4. The kubeconfig Secret of the role, and none for management. A stage
	# of storage or compute without one applies its objects to the management
	# cluster: the directory of its spec.path holds at least one HelmRelease,
	# and each names the Secret of the role.
	if [ "$role" = management ]; then
		[ "$(yq '.spec | has("kubeConfig")' "$dir/stage.yaml")" = false ] || { echo 4; return 1; }
	elif [ "$(yq '.spec | has("kubeConfig")' "$dir/stage.yaml")" = true ]; then
		[ "$(yq '.spec.kubeConfig.secretRef.name' "$dir/stage.yaml")" = "kubeconfig-$role" ] || { echo 4; return 1; }
	else
		# One list over all files: yq separates the results of several
		# documents with ---. The list stays JSON, because the empty name of
		# a last release without kubeConfig would end the text as an empty
		# line, which $(...) removes.
		names=$(yq ea -o=json -I=0 '[select(.kind == "HelmRelease") | .spec.kubeConfig.secretRef.name // ""]' "$root/${path#./}"/*.yaml)
		jq -e --arg secret "kubeconfig-$role" 'length > 0 and all(. == $secret)' <<<"$names" >/dev/null || { echo 4; return 1; }
	fi

	# 5. Every dependency is the stage of an existing module.
	for dep in $(yq '.spec.dependsOn // [] | .[].name' "$dir/stage.yaml"); do
		[[ $dep =~ ^(management|storage|compute)-([a-z0-9][a-z0-9-]*)$ ]] &&
			[ -f "$root/clusters/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/stage.yaml" ] || { echo 5; return 1; }
	done
}

# find_addresses <root>: prints each *.yaml file under the root, outside
# config.yaml, kind/, tests/, docs/, vendor/, .sandbox/ and .git/, that
# contains an IPv4 address.
find_addresses() {
	local file
	while IFS= read -r -d '' file; do
		if grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$file"; then
			printf '%s\n' "${file#"$1"/}"
		fi
	done < <(find "$1" \( -path "$1/.git" -o -path "$1/.sandbox" -o -path "$1/vendor" -o -path "$1/kind" \
		-o -path "$1/tests" -o -path "$1/docs" \) -prune -o -type f -name '*.yaml' ! -path "$1/config.yaml" -print0)
}

# component_patch <component> <index>: prints the patch with the index of the
# Component controlplane/components/<component> as JSON on one line.
component_patch() {
	I=$2 yq '.patches[env(I)].patch' "$SANDBOX_ROOT/controlplane/components/$1/kustomization.yaml" | yq -o=json -I=0 '.'
}

# tree_copy: copies clusters/, infrastructure/, compute/ and storage/ into
# $BATS_TEST_TMPDIR/tree.
tree_copy() {
	rm -rf -- "$BATS_TEST_TMPDIR/tree"
	mkdir -- "$BATS_TEST_TMPDIR/tree"
	cp -R -- "$SANDBOX_ROOT/clusters" "$SANDBOX_ROOT/infrastructure" "$SANDBOX_ROOT/compute" "$SANDBOX_ROOT/storage" \
		"$BATS_TEST_TMPDIR/tree/"
}

@test "every module of a cluster with a stage meets the stage contract" {
	local dir count=0
	for dir in "$SANDBOX_ROOT"/clusters/*/*/; do
		dir=${dir%/}
		[ -f "$dir/stage.yaml" ] || continue
		run stage_contract "$SANDBOX_ROOT" "${dir#"$SANDBOX_ROOT"/clusters/}"
		echo "${dir#"$SANDBOX_ROOT"/}: point $output"
		[ "$status" -eq 0 ]
		count=$((count + 1))
	done
	[ "$count" -ge 3 ]
}

@test "every module of a cluster without a stage holds exactly patches/kustomization.yaml" {
	local dir count=0
	for dir in "$SANDBOX_ROOT"/clusters/*/*/; do
		dir=${dir%/}
		[ ! -f "$dir/stage.yaml" ] || continue
		echo "${dir#"$SANDBOX_ROOT"/}"
		[ "$(cd -- "$dir" && find . -mindepth 1 | LC_ALL=C sort | paste -sd ' ')" = "./patches ./patches/kustomization.yaml" ]
		count=$((count + 1))
	done
	[ "$count" -ge 7 ]
}

@test "the stage contract names the first point a broken module breaks" {
	local point module file expression
	while read -r point module file expression; do
		tree_copy
		yq -i "$expression" "$BATS_TEST_TMPDIR/tree/clusters/$module/$file"
		run stage_contract "$BATS_TEST_TMPDIR/tree" "$module"
		echo "$module/$file $expression: point $output"
		[ "$status" -eq 1 ]
		[ "$output" = "$point" ]
	done <<'EOF'
1 storage/test kustomization.yaml .kind = "Kustomization"
1 storage/test kustomization.yaml .resources += ["extra.yaml"]
2 storage/test stage.yaml .metadata.name = "test"
2 storage/test stage.yaml .metadata.namespace = "default"
2 storage/test stage.yaml .spec.wait = "true"
2 storage/test stage.yaml del(.spec.prune)
2 storage/test stage.yaml .spec.sourceRef.kind = "GitRepository"
3 storage/test stage.yaml .spec.path = "./infrastructure/nothere"
3 storage/test stage.yaml .spec.path = "./infrastructure/../infrastructure/test"
4 storage/test stage.yaml del(.spec.kubeConfig)
4 compute/test stage.yaml .spec.kubeConfig.secretRef.name = "kubeconfig-storage"
4 management/test stage.yaml .spec.kubeConfig.secretRef.name = "kubeconfig-management"
4 compute/access stage.yaml .spec.path = "./infrastructure/test"
5 storage/test stage.yaml .spec.dependsOn[0].name = "management-nothere"
5 compute/test stage.yaml .spec.dependsOn += [{"name": "network-test"}]
EOF
}

@test "a second HelmRelease that names the Secret of its role keeps point 4" {
	tree_copy
	printf -- '---\n' >>"$BATS_TEST_TMPDIR/tree/compute/access/release.yaml"
	yq '.metadata.name = "compute-access-2"' "$SANDBOX_ROOT/compute/access/release.yaml" >>"$BATS_TEST_TMPDIR/tree/compute/access/release.yaml"
	[ "$(yq ea '[select(.kind == "HelmRelease")] | length' "$BATS_TEST_TMPDIR/tree/compute/access/release.yaml")" = 2 ]
	run stage_contract "$BATS_TEST_TMPDIR/tree" compute/access
	echo "point $output"
	[ "$status" -eq 0 ]
}

@test "a HelmRelease of a stage without kubeConfig that names no Secret of its role breaks point 4" {
	local expression
	for expression in '.spec.kubeConfig.secretRef.name = "kubeconfig-storage"' 'del(.spec.kubeConfig)'; do
		tree_copy
		yq -i "$expression" "$BATS_TEST_TMPDIR/tree/compute/access/release.yaml"
		run stage_contract "$BATS_TEST_TMPDIR/tree" compute/access
		echo "$expression: point $output"
		[ "$status" -eq 1 ]
		[ "$output" = 4 ]
	done
}

@test "a release of compute/controllers without kubeConfig breaks point 4" {
	local file=$BATS_TEST_TMPDIR/tree/compute/controllers/releases.yaml
	tree_copy
	yq -i '(select(.metadata.name == "compute-external-secrets") | .spec) |= del(.kubeConfig)' "$file"
	[ "$(yq ea -o=json -I=0 '[select(.kind == "HelmRelease") | .spec | has("kubeConfig")]' "$file")" = '[true,false]' ]
	run stage_contract "$BATS_TEST_TMPDIR/tree" compute/controllers
	echo "point $output"
	[ "$status" -eq 1 ]
	[ "$output" = 4 ]
}

@test "a stage.yaml with a second document breaks point 2" {
	tree_copy
	printf -- '---\n' >>"$BATS_TEST_TMPDIR/tree/clusters/storage/test/stage.yaml"
	cat -- "$SANDBOX_ROOT/clusters/storage/test/stage.yaml" >>"$BATS_TEST_TMPDIR/tree/clusters/storage/test/stage.yaml"
	run stage_contract "$BATS_TEST_TMPDIR/tree" storage/test
	[ "$status" -eq 1 ]
	[ "$output" = 2 ]
}

@test "the kustomization of each cluster lists no resource of its own" {
	local role
	for role in "${SANDBOX_ROLES[@]}"; do
		[ "$(yq -o=json -I=0 '[.kind, .resources]' "$SANDBOX_ROOT/clusters/$role/kustomization.yaml")" = '["Kustomization",[]]' ]
	done
}

@test "no manifest of the tree carries a literal IPv4 address" {
	run find_addresses "$SANDBOX_ROOT"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "the address check finds an address in a manifest and skips the excluded paths" {
	local root=$BATS_TEST_TMPDIR/root dir
	for dir in clusters/storage kind tests docs vendor .sandbox; do
		mkdir -p -- "$root/$dir"
		echo 'address: 172.30.255.10' >"$root/$dir/a.yaml"
	done
	echo 'subnet: 172.30.0.0/16' >"$root/config.yaml"
	echo 'address: ${ADDRESSES_GATEWAY}' >"$root/clusters/b.yaml"
	run find_addresses "$root"
	[ "$status" -eq 0 ]
	[ "$output" = clusters/storage/a.yaml ]
}

@test "the address pool hands out no address unasked" {
	[ "$(yq 'select(.kind == "IPAddressPool") | .spec.autoAssign' "$SANDBOX_ROOT/infrastructure/loadbalancer/pool.yaml")" = false ]
}

@test "the Corefile of the module resolver holds the sandbox block once and is never pruned" {
	local file=$SANDBOX_ROOT/infrastructure/resolver/coredns/configmap.yaml corefile
	corefile=$(yq '.data.Corefile' "$file")
	[ "$(grep -cxF '    # sandbox: begin' <<<"$corefile")" = 1 ]
	[ "$(grep -cxF '    # sandbox: end' <<<"$corefile")" = 1 ]
	[ "$(yq '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' "$file")" = disabled ]
}

@test "the Job openbao-bootstrap is forced, pins its image by digest and mounts the runner, the scripts and the policies" {
	local file=$SANDBOX_ROOT/infrastructure/openbao/bootstrap.yaml job='select(.kind == "Job")'
	[ "$(yq "$job | .metadata.name + \" \" + .metadata.annotations[\"kustomize.toolkit.fluxcd.io/force\"]" "$file")" = \
		"openbao-bootstrap enabled" ]
	[[ $(yq "$job | .spec.template.spec.containers[0].image" "$file") =~ @sha256:[0-9a-f]{64}$ ]]
	[ "$(yq ea -o=json -I=0 "[$job | .spec.template.spec.volumes[] | select(has(\"configMap\")) | .configMap.name]" "$file")" = \
		'["openbao-bootstrap-runner","cobaltcore-openbao-scripts","cobaltcore-openbao-policies"]' ]
}

@test "every rule of the bootstrap Role and ClusterRole names its objects, but the one that creates Secrets" {
	local file=$SANDBOX_ROOT/infrastructure/openbao/bootstrap.yaml roles='select(.kind == "Role" or .kind == "ClusterRole")'
	[ "$(yq ea "[$roles] | length" "$file")" = 2 ]
	[ "$(yq ea -o=json -I=0 "[$roles | .rules[] | select((.resourceNames // []) | length == 0)]" "$file")" = \
		'[{"apiGroups":[""],"resources":["secrets"],"verbs":["create"]}]' ]
}

@test "the stage management-openbao-remote-auth applies the module after openbao and loadbalancer, substitutes cluster-vars and the optional ConfigMap openbao-remote-auth, and waits for the Certificates" {
	local stage=$SANDBOX_ROOT/clusters/management/openbao-remote-auth/stage.yaml
	run stage_contract "$SANDBOX_ROOT" management/openbao-remote-auth
	echo "point $output"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.postBuild]' "$stage")" = \
		'[[{"name":"management-openbao"},{"name":"management-loadbalancer"}],"./infrastructure/openbao-remote-auth","10m","1m","15m",{"substituteFrom":[{"kind":"ConfigMap","name":"cluster-vars"},{"kind":"ConfigMap","name":"openbao-remote-auth","optional":true}]}]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '[.spec.healthCheckExprs[] | select(.kind == "Certificate")]' "$SANDBOX_ROOT/clusters/management/pki/stage.yaml")" ]
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/infrastructure/openbao-remote-auth/kustomization.yaml")" = \
		'["service.yaml","certificates.yaml","job.yaml"]' ]
}

@test "the Job openbao-remote-auth is forced, pins the image of openbao-bootstrap, mounts only its runner and an emptyDir, and takes the four API variables as := defaults" {
	local dir=$SANDBOX_ROOT/infrastructure/openbao-remote-auth job='select(.kind == "Job")' spec
	spec=$(yq -o=json -I=0 "$job | .spec" "$dir/job.yaml")
	[ "$(yq "$job | .metadata.name + \" \" + .metadata.annotations[\"kustomize.toolkit.fluxcd.io/force\"]" "$dir/job.yaml")" = \
		"openbao-remote-auth enabled" ]
	[ "$(jq -c '[.backoffLimit, .activeDeadlineSeconds, .template.spec.serviceAccountName, .template.spec.containers[0].command]' <<<"$spec")" = \
		'[4,900,"openbao-remote-auth",["bash","/runner/remote-auth.sh"]]' ]
	[ "$(jq -r '.template.spec.containers[0].image' <<<"$spec")" = \
		"$(yq "$job | .spec.template.spec.containers[0].image" "$SANDBOX_ROOT/infrastructure/openbao/bootstrap.yaml")" ]
	[ "$(jq -c '.template.spec.containers[0] | [.securityContext, .resources]' <<<"$spec")" = \
		"$(yq ea -o=json -I=0 "[$job | .spec.template.spec.containers[0]] | map([.securityContext, .resources]) | .[0]" "$SANDBOX_ROOT/infrastructure/openbao/bootstrap.yaml")" ]
	[ "$(jq -c '.template.spec.volumes' <<<"$spec")" = \
		'[{"name":"tmp","emptyDir":{}},{"name":"runner","configMap":{"name":"openbao-remote-auth-runner"}}]' ]
	[ "$(jq -c '.template.spec.containers[0].env' <<<"$spec")" = \
		'[{"name":"HOME","value":"/tmp"},{"name":"STORAGE_API_SERVER","value":"${STORAGE_API_SERVER:=}"},{"name":"STORAGE_API_CA_B64","value":"${STORAGE_API_CA_B64:=}"},{"name":"COMPUTE_API_SERVER","value":"${COMPUTE_API_SERVER:=}"},{"name":"COMPUTE_API_CA_B64","value":"${COMPUTE_API_CA_B64:=}"}]' ]
	# Each default is quoted in the file.
	[ "$(grep -cE '^ +value: "\$\{(STORAGE|COMPUTE)_API_(SERVER|CA_B64):=\}"$' "$dir/job.yaml")" = 4 ]
}

@test "the generator openbao-remote-auth-runner holds the runner, the policy and upstream's common.sh, which Flux does not substitute" {
	local generator
	generator=$(yq -o=json -I=0 '.configMapGenerator[] | select(.name == "openbao-remote-auth-runner")' \
		"$SANDBOX_ROOT/infrastructure/openbao-remote-auth/kustomization.yaml")
	[ "$(jq -c '[.namespace, .options.annotations["kustomize.toolkit.fluxcd.io/substitute"]]' <<<"$generator")" = \
		'["shared-services","disabled"]' ]
	[ "$(jq -r '.files | map(split("/")[-1]) | join(" ")' <<<"$generator")" = "remote-auth.sh read-ceph-client-cinder.hcl common.sh" ]
	[ -f "$SANDBOX_ROOT/infrastructure/openbao-remote-auth/$(jq -r '.files[2]' <<<"$generator")" ]
}

@test "every rule of the Role openbao-remote-auth names its objects, and the module has no ClusterRole" {
	local dir=$SANDBOX_ROOT/infrastructure/openbao-remote-auth
	[ "$(yq ea -o=json -I=0 '[select(.kind == "Role") | .rules[]] | map([.resources, .resourceNames, .verbs])' "$dir/job.yaml")" = \
		'[[["pods"],["openbao-0"],["get"]],[["pods/exec"],["openbao-0"],["create"]],[["secrets"],["openbao-init-keys"],["get"]]]' ]
	[ "$(yq ea '[select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding")] | length' "$dir"/*.yaml)" = 0 ]
}

@test "the Service openbao-published puts port 8200 of the OpenBao server on addresses.openbao" {
	[ "$(yq -o=json -I=0 '[.kind, .metadata.namespace, .metadata.name, .metadata.annotations, .spec]' "$SANDBOX_ROOT/infrastructure/openbao-remote-auth/service.yaml")" = \
		'["Service","shared-services","openbao-published",{"metallb.io/loadBalancerIPs":"${ADDRESSES_OPENBAO}"},{"type":"LoadBalancer","ports":[{"name":"https","port":8200,"targetPort":8200}],"selector":{"app.kubernetes.io/name":"openbao","app.kubernetes.io/instance":"openbao","component":"server"}}]' ]
}

@test "the client Certificates of storage and compute come from the ClusterIssuer openbao-ca-issuer for client auth alone" {
	[ "$(yq ea -o=json -I=0 '[[.metadata.namespace, .metadata.name, .spec.secretName, .spec.issuerRef, .spec.usages, .spec.commonName, .spec.duration, .spec.renewBefore]]' \
		"$SANDBOX_ROOT/infrastructure/openbao-remote-auth/certificates.yaml")" = \
		'[["shared-services","openbao-client-storage","openbao-client-storage",{"name":"openbao-ca-issuer","kind":"ClusterIssuer"},["client auth"],"openbao-client.sandbox-storage","8760h","720h"],["shared-services","openbao-client-compute","openbao-client-compute",{"name":"openbao-ca-issuer","kind":"ClusterIssuer"},["client auth"],"openbao-client.sandbox-compute","8760h","720h"]]' ]
}

@test "the policy read-ceph-client-cinder grants read on kv-v2/data/ceph/client-cinder alone" {
	[ "$(grep -vE '^[[:space:]]*(#|$)' "$SANDBOX_ROOT/infrastructure/openbao-remote-auth/read-ceph-client-cinder.hcl")" = 'path "kv-v2/data/ceph/client-cinder" {
  capabilities = ["read"]
}' ]
}

@test "every rule of the two tenant Roles and of the Roles rabbitmq-transport and hypervisor-operator-auth names its objects" {
	local file count roles='select(.kind == "Role")'
	while read -r file count; do
		[ "$(yq ea "[$roles] | length" "$SANDBOX_ROOT/$file")" = "$count" ]
		[ "$(yq ea -o=json -I=0 "[$roles | .rules[] | select((.resourceNames // []) | length == 0)]" "$SANDBOX_ROOT/$file")" = '[]' ]
	done <<'EOF'
controlplane/tenant.yaml 2
infrastructure/messaging-tls/transport.yaml 1
compute/hypervisor-operator/auth.yaml 1
EOF
}

@test "every patches Component targets only the stages of other modules of its cluster" {
	local file module role name count=0
	for file in "$SANDBOX_ROOT"/clusters/*/*/patches/kustomization.yaml; do
		module=${file%/patches/kustomization.yaml}
		module=${module##*/}
		role=${file#"$SANDBOX_ROOT"/clusters/}
		role=${role%%/*}
		echo "$file"
		[ "$(yq -o=json -I=0 '[.apiVersion, .kind, has("resources")]' "$file")" = \
			'["kustomize.config.k8s.io/v1alpha1","Component",false]' ]
		[ "$(yq '.patches | length' "$file")" -gt 0 ]
		[ "$(yq '[.patches[].target | select(.group != "kustomize.toolkit.fluxcd.io" or .kind != "Kustomization")] | length' "$file")" = 0 ]
		for name in $(yq '.patches[].target.name' "$file"); do
			[[ $name == "$role-"* ]]
			[ "${name#"$role"-}" != "$module" ]
			[ -f "$SANDBOX_ROOT/clusters/$role/${name#"$role"-}/stage.yaml" ]
		done
		count=$((count + 1))
	done
	[ "$count" -ge 2 ]
}

@test "the patches Component of controlplane resumes the keystone-operator on one replica in the stage of controllers" {
	local file=$SANDBOX_ROOT/clusters/management/controlplane/patches/kustomization.yaml ops flux
	[ "$(yq -o=json -I=0 '[.patches[].target.name]' "$file")" = '["management-controllers"]' ]
	ops=$(yq '.patches[0].patch' "$file")
	[ "$(yq -o=json -I=0 '[.[] | [.op, .path]]' - <<<"$ops")" = '[["add","/spec/patches/-"]]' ]
	flux=$(yq '.[0].value' - <<<"$ops")
	[ "$(yq -o=json -I=0 '.target' - <<<"$flux")" = \
		'{"group":"helm.toolkit.fluxcd.io","kind":"HelmRelease","name":"keystone-operator","namespace":"keystone-system"}' ]
	[ "$(yq '.patch' - <<<"$flux" | yq -o=json -I=0 '.')" = \
		'[{"op":"replace","path":"/spec/suspend","value":false},{"op":"replace","path":"/spec/values/replicas","value":1}]' ]
	# The stage declares the list the patch appends to.
	[ "$(yq -o=json -I=0 '.spec.patches' "$SANDBOX_ROOT/clusters/management/controllers/stage.yaml")" = '[]' ]
}

@test "the patches Component of messaging-tls puts the ControlPlane on the bus and the stage after it" {
	local file=$SANDBOX_ROOT/clusters/management/messaging-tls/patches/kustomization.yaml
	[ "$(yq -o=json -I=0 '[.patches[].target.name]' "$file")" = '["management-controlplane"]' ]
	[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/components/-","value":"components/messaging-tls"},{"op":"add","path":"/spec/dependsOn/-","value":{"name":"management-messaging-tls"}}]' ]
	[ -f "$SANDBOX_ROOT/controlplane/components/messaging-tls/kustomization.yaml" ]
	[ "$(yq -o=json -I=0 '[.spec.components, (.spec.dependsOn | length)]' "$SANDBOX_ROOT/clusters/management/controlplane/stage.yaml")" = \
		'[["components/keystone"],3]' ]
}

@test "each service module appends its component to the stage of controlplane and resumes its releases on one replica in the stage of controllers" {
	local module releases release file ops expected count i
	while read -r module releases; do
		file=$SANDBOX_ROOT/clusters/management/$module/patches/kustomization.yaml
		echo "$module"
		[ ! -e "$SANDBOX_ROOT/clusters/management/$module/stage.yaml" ]
		[ "$(yq -o=json -I=0 '[.patches[].target.name]' "$file")" = '["management-controlplane","management-controllers"]' ]
		[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '[.[] | select(.path == "/spec/components/-")]')" = \
			"[{\"op\":\"add\",\"path\":\"/spec/components/-\",\"value\":\"components/$module\"}]" ]
		[ -f "$SANDBOX_ROOT/controlplane/components/$module/kustomization.yaml" ]
		ops=$(yq '.patches[1].patch' "$file")
		[ "$(yq -o=json -I=0 '[.[] | [.op, .path]] | unique' - <<<"$ops")" = '[["add","/spec/patches/-"]]' ]
		expected=
		for release in $releases; do
			expected+="${expected:+,}{\"group\":\"helm.toolkit.fluxcd.io\",\"kind\":\"HelmRelease\",\"name\":\"$release-operator\",\"namespace\":\"$release-system\"}"
		done
		[ "$(yq -o=json -I=0 '[.[].value.target]' - <<<"$ops")" = "[$expected]" ]
		# Each resume first tests the suspension of controllers.
		count=$(yq 'length' - <<<"$ops")
		for ((i = 0; i < count; i++)); do
			[ "$(I=$i yq '.[env(I)].value.patch' - <<<"$ops" | yq -o=json -I=0 '.')" = \
				'[{"op":"test","path":"/spec/suspend","value":true},{"op":"replace","path":"/spec/suspend","value":false},{"op":"replace","path":"/spec/values/replicas","value":1}]' ]
		done
	done <<'EOF'
glance glance
placement placement
barbican barbican
neutron ovn neutron
cinder cinder
nova nova
horizon horizon
EOF
}

@test "glance and cinder-nfs append the dependency on the stage they need, and the other service modules none" {
	local module dir=$SANDBOX_ROOT/clusters/management
	[ "$(yq '.patches[0].patch' "$dir/glance/patches/kustomization.yaml" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/components/-","value":"components/glance"},{"op":"add","path":"/spec/dependsOn/-","value":{"name":"management-objectstore"}}]' ]
	[ "$(yq -o=json -I=0 '[.patches[].target.name]' "$dir/cinder-nfs/patches/kustomization.yaml")" = '["management-controlplane"]' ]
	[ "$(yq '.patches[0].patch' "$dir/cinder-nfs/patches/kustomization.yaml" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/components/-","value":"components/cinder-nfs"},{"op":"add","path":"/spec/dependsOn/-","value":{"name":"management-cinder-nfs"}}]' ]
	[ -f "$SANDBOX_ROOT/controlplane/components/cinder-nfs/kustomization.yaml" ]
	for module in placement barbican neutron cinder nova horizon; do
		echo "$module"
		[ "$(yq '.patches[0].patch' "$dir/$module/patches/kustomization.yaml" | yq '[.[] | select(.path == "/spec/dependsOn/-")] | length')" = 0 ]
	done
}

@test "the stage of cinder-nfs runs the NFS export after controllers, and the stage of fake-compute the fake compute after controlplane" {
	local dir=$SANDBOX_ROOT/clusters/management
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.timeout]' "$dir/cinder-nfs/stage.yaml")" = \
		'[[{"name":"management-controllers"}],"./infrastructure/nfs","10m"]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$dir/cinder-nfs/stage.yaml")" = \
		"$(yq -o=json -I=0 '.spec.healthCheckExprs' "$dir/platform/stage.yaml")" ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.timeout]' "$dir/fake-compute/stage.yaml")" = \
		'[[{"name":"management-controlplane"}],"./controlplane/fake-compute","10m"]' ]
}

@test "each component of a service patches the ControlPlane controlplane with its block behind the Gateway openstack-gw" {
	local component service file patch rest
	for component in glance placement barbican neutron cinder nova horizon cinder-nfs; do
		file=$SANDBOX_ROOT/controlplane/components/$component/kustomization.yaml
		service=${component%-nfs}
		echo "$component"
		[ "$(yq -o=json -I=0 '[.apiVersion, .kind]' "$file")" = '["kustomize.config.k8s.io/v1alpha1","Component"]' ]
		[ "$(yq -o=json -I=0 '.patches[0].target' "$file")" = \
			'{"group":"c5c3.io","version":"v1alpha1","kind":"ControlPlane","name":"controlplane","namespace":"openstack"}' ]
		patch=$(component_patch "$component" 0)
		[ "$(jq -c '[.apiVersion, .kind, .metadata.name, .metadata.namespace, (.spec.services | keys)]' <<<"$patch")" = \
			"[\"c5c3.io/v1alpha1\",\"ControlPlane\",\"controlplane\",\"openstack\",[\"$service\"]]" ]
		if [ "$component" = cinder-nfs ]; then
			[ "$(jq -c '.spec.services.cinder' <<<"$patch")" = \
				'{"backends":[{"name":"nfs1","type":"NFS","nfs":{"server":"nfs-server.openstack.svc.cluster.local","path":"/volumes"}}]}' ]
			continue
		fi
		[ "$(jq -c ".spec.services.$service.gateway" <<<"$patch")" = \
			"{\"parentRef\":{\"name\":\"openstack-gw\"},\"hostname\":\"$service.\${ADDRESSES_GATEWAY//./-}.nip.io\"}" ]
		[ "$(jq ".spec.services.$service | has(\"publicEndpoint\")" <<<"$patch")" = false ]
		# Beside the gateway, the block of Step 4 and nothing else.
		case $component in
		glance) rest='{"backends":[{"name":"default","type":"S3","isDefault":true,"s3":{"endpoint":"http://garage.shared-services.svc.cluster.local:3900","bucket":"glance-images","region":"garage","credentialsSecretRef":{"name":"garage-s3-credentials"}}}]}' ;;
		barbican) rest='{"secretStore":{"dedicated":{}}}' ;;
		neutron) rest='{"ovn":{"centralRef":{"name":"controlplane-ovn"}}}' ;;
		*) rest='{}' ;;
		esac
		[ "$(jq -c ".spec.services.$service | del(.gateway)" <<<"$patch")" = "$rest" ]
	done
	# A merge patch replaces a list, so cinder-nfs alone sets backends.
	[ "$(component_patch cinder 0 | jq '.spec.services.cinder | has("backends")')" = false ]
}

@test "the three bus consumers declare messaging: {} in the patch of their block, and the other components no messaging" {
	local component expected
	for component in glance placement barbican neutron cinder nova horizon cinder-nfs; do
		case $component in
		neutron | cinder | nova) expected="[{\"messaging\":{}},[\"$component\"]]" ;;
		*) expected="[null,[\"${component%-nfs}\"]]" ;;
		esac
		echo "$component"
		[ "$(component_patch "$component" 0 | jq -c '[.spec.infrastructure, (.spec.services | keys)]')" = "$expected" ]
	done
}

@test "the six database services add their TENANT_SERVICE_ variable to the container tenant of the Job, and horizon and cinder-nfs none" {
	local component file
	[ "$(yq 'select(.kind == "Job") | .spec.template.spec.containers[0].name' "$SANDBOX_ROOT/controlplane/tenant.yaml")" = tenant ]
	for component in glance placement barbican neutron cinder nova; do
		file=$SANDBOX_ROOT/controlplane/components/$component/kustomization.yaml
		echo "$component"
		[ "$(yq '.patches | length' "$file")" = 2 ]
		[ "$(yq -o=json -I=0 '.patches[1].target' "$file")" = \
			'{"group":"batch","version":"v1","kind":"Job","name":"controlplane-database-tenant","namespace":"openstack"}' ]
		[ "$(component_patch "$component" 1 | jq -c '[.apiVersion, .kind, .metadata.name, .metadata.namespace, .spec.template.spec.containers]')" = \
			"[\"batch/v1\",\"Job\",\"controlplane-database-tenant\",\"openstack\",[{\"name\":\"tenant\",\"env\":[{\"name\":\"TENANT_SERVICE_${component^^}\",\"value\":\"$component\"}]}]]" ]
	done
	for component in horizon cinder-nfs; do
		echo "$component"
		[ "$(yq '.patches | length' "$SANDBOX_ROOT/controlplane/components/$component/kustomization.yaml")" = 1 ]
	done
}

@test "the component neutron holds the OVNCentral controlplane-ovn, horizon the ExternalSecret of its secret key, and no other component a resource" {
	local dir=$SANDBOX_ROOT/controlplane/components component
	[ "$(yq -o=json -I=0 '.resources' "$dir/neutron/kustomization.yaml")" = '["ovncentral.yaml"]' ]
	[ "$(yq -o=json -I=0 '.' "$dir/neutron/ovncentral.yaml")" = \
		'{"apiVersion":"ovn.openstack.c5c3.io/v1alpha1","kind":"OVNCentral","metadata":{"name":"controlplane-ovn","namespace":"openstack"},"spec":{"tls":{"issuerRef":{"name":"openstack-ovn-ca-issuer"}},"northbound":{"replicas":1},"southbound":{"replicas":1},"northd":{"deployment":{"replicas":1}}}}' ]
	[ "$(yq -o=json -I=0 '.resources' "$dir/horizon/kustomization.yaml")" = \
		'["../../../vendor/cobaltcore/deploy/bases/devstack/infrastructure/horizon-secret-key-externalsecret.yaml"]' ]
	for component in glance placement barbican cinder nova cinder-nfs; do
		[ "$(yq 'has("resources")' "$dir/$component/kustomization.yaml")" = false ]
	done
}

@test "the Job controlplane-database-tenant is forced, pins its image by digest and mounts the generated scripts, which Flux does not substitute" {
	local file=$SANDBOX_ROOT/controlplane/tenant.yaml job='select(.kind == "Job")' generator
	[ "$(yq "$job | .metadata.name + \" \" + .metadata.annotations[\"kustomize.toolkit.fluxcd.io/force\"]" "$file")" = \
		"controlplane-database-tenant enabled" ]
	[[ $(yq "$job | .spec.template.spec.containers[0].image" "$file") =~ @sha256:[0-9a-f]{64}$ ]]
	[ "$(yq -o=json -I=0 "$job | .spec.template.spec.containers[0].command" "$file")" = '["bash","/scripts/tenant.sh"]' ]
	[ "$(yq ea -o=json -I=0 "[$job | .spec.template.spec.volumes[] | select(has(\"configMap\")) | .configMap.name]" "$file")" = \
		'["controlplane-database-tenant"]' ]
	generator=$(yq -o=json -I=0 '.configMapGenerator[] | select(.name == "controlplane-database-tenant")' \
		"$SANDBOX_ROOT/controlplane/kustomization.yaml")
	[ "$(jq -c '[.namespace, .options.annotations["kustomize.toolkit.fluxcd.io/substitute"]]' <<<"$generator")" = \
		'["openstack","disabled"]' ]
	[ "$(jq -r '.files | map(split("/")[-1]) | join(" ")' <<<"$generator")" = "tenant.sh common.sh setup-database-tenant.sh" ]
}

@test "the stages of pki, messaging-tls, controlplane and ceph-cluster on storage substitute from cluster-vars" {
	local stage
	for stage in management/pki management/messaging-tls management/controlplane storage/ceph-cluster; do
		echo "$stage"
		[ "$(yq -o=json -I=0 '.spec.postBuild' "$SANDBOX_ROOT/clusters/$stage/stage.yaml")" = \
			'{"substituteFrom":[{"kind":"ConfigMap","name":"cluster-vars"}]}' ]
	done
}

@test "the patch of infrastructure/pki adds the published name of OpenBao to the dnsNames of openbao-tls and changes nothing else" {
	local file=$SANDBOX_ROOT/infrastructure/pki/kustomization.yaml
	[ "$(yq -o=json -I=0 '[.patches[].target]' "$file")" = \
		'[{"group":"cert-manager.io","version":"v1","kind":"Certificate","name":"openbao-tls","namespace":"shared-services"}]' ]
	[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/dnsNames/-","value":"openbao.${ADDRESSES_OPENBAO//./-}.nip.io"}]' ]
	# Upstream's certificate holds the names the patch appends to.
	[ "$(yq -o=json -I=0 '[.metadata.namespace, (.spec.dnsNames | length > 0)]' \
		"$SANDBOX_ROOT/vendor/cobaltcore/deploy/bases/tls/openbao-tls-cert.yaml")" = '["shared-services",true]' ]
}

@test "the stages of openbao, objectstore, platform, sizing, cinder-nfs, fake-compute, hypervisor-fixtures, of access, controllers, node-prep, libvirt, kvm-node-agent and hypervisor-operator on compute and of block-devices, rook-crds, rook-operator and controllers on storage substitute no variables" {
	local stage
	for stage in management/{openbao,objectstore,platform,sizing,cinder-nfs,fake-compute,hypervisor-fixtures} \
		compute/{access,controllers,node-prep,libvirt,kvm-node-agent,hypervisor-operator} \
		storage/{block-devices,rook-crds,rook-operator,controllers}; do
		echo "$stage"
		[ "$(yq '.spec | has("postBuild")' "$SANDBOX_ROOT/clusters/$stage/stage.yaml")" = false ]
	done
}

@test "the stage compute-access applies the ArtifactGenerator and the HelmRelease of the access chart on sandbox-management and waits for both" {
	local dir=$SANDBOX_ROOT/compute/access ready expected
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig")), (.spec | has("dependsOn"))]' \
		"$SANDBOX_ROOT/clusters/compute/access/stage.yaml")" = '["./compute/access","10m","1m","5m",false,false]' ]
	ready="status.conditions.exists(c, c.type == 'Ready' && c.status == 'True' && c.observedGeneration == metadata.generation)"
	expected=$(jq -n -c --arg ready "$ready" '[{apiVersion: "helm.toolkit.fluxcd.io/v2", kind: "HelmRelease", current: $ready},
		{apiVersion: "source.extensions.fluxcd.io/v1beta1", kind: "ArtifactGenerator", current: $ready}]')
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$SANDBOX_ROOT/clusters/compute/access/stage.yaml")" = "$expected" ]
	[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = '["chart.yaml","release.yaml"]' ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name, .metadata.namespace, .spec.sources, .spec.artifacts]' "$dir/chart.yaml")" = \
		'["ArtifactGenerator","target-cluster-access","flux-system",[{"alias":"sandbox","kind":"OCIRepository","name":"sandbox"}],[{"name":"target-cluster-access","copy":[{"from":"@sandbox/vendor/cobaltcore/deploy/bases/target-cluster-access/","to":"@artifact/"}]}]]' ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name, .metadata.namespace, .spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.install, .spec.chartRef, .spec.kubeConfig, .spec.values]' "$dir/release.yaml")" = \
		'["HelmRelease","compute-access","flux-system","target-cluster-access","c5c3-access","c5c3-access",{"createNamespace":true},{"kind":"ExternalArtifact","name":"target-cluster-access"},{"secretRef":{"name":"kubeconfig-compute"}},{"namespaces":["openstack"],"privilegedNamespaces":["openstack"],"createNamespaces":true}]' ]
}

@test "the stage compute-controllers applies the sources and releases of cert-manager and External Secrets on sandbox-management and waits for the releases" {
	local stage=$SANDBOX_ROOT/clusters/compute/controllers/stage.yaml
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig")), (.spec | has("dependsOn"))]' "$stage")" = \
		'["./compute/controllers","10m","1m","10m",false,false]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '[.spec.healthCheckExprs[] | select(.kind == "HelmRelease")]' "$SANDBOX_ROOT/clusters/compute/access/stage.yaml")" ]
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/compute/controllers/kustomization.yaml")" = '["sources.yaml","releases.yaml"]' ]
}

@test "the sources and releases of compute/controllers are upstream's, under names of their own and with the kubeconfig of compute" {
	local dir=$SANDBOX_ROOT/compute/controllers upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/bases/operators chart release original fields
	[ "$(yq ea -o=json -I=0 '[.kind + "/" + .metadata.namespace + "/" + .metadata.name]' "$dir/sources.yaml" "$dir/releases.yaml")" = \
		'["HelmRepository/flux-system/compute-cert-manager","HelmRepository/flux-system/compute-external-secrets","HelmRelease/flux-system/compute-cert-manager","HelmRelease/flux-system/compute-external-secrets"]' ]
	fields='[.spec.interval, .spec.chart.spec.chart, .spec.chart.spec.version, .spec.values, .spec.install, .spec.upgrade]'
	for chart in cert-manager external-secrets; do
		echo "$chart"
		[ "$(NAME=compute-$chart yq ea -o=json -I=0 'select(.metadata.name == env(NAME)) | [.spec.interval, .spec.url]' "$dir/sources.yaml")" = \
			"$(yq -o=json -I=0 '[.spec.interval, .spec.url]' "$upstream/sources/$chart.yaml")" ]
		release=$(NAME=compute-$chart yq -o=json -I=0 'select(.metadata.name == env(NAME))' "$dir/releases.yaml")
		original=$(yq -o=json -I=0 '.' "$upstream/releases/$chart.yaml")
		[ "$(jq -c "$fields" <<<"$release")" = "$(jq -c "$fields" <<<"$original")" ]
		[ "$(jq -c '[.spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.chart.spec.sourceRef, .spec.kubeConfig]' <<<"$release")" = \
			"[\"$chart\",\"$chart\",\"$chart\",{\"kind\":\"HelmRepository\",\"name\":\"compute-$chart\"},{\"secretRef\":{\"name\":\"kubeconfig-compute\"}}]" ]
	done
	# External Secrets waits for cert-manager, as upstream's release does.
	[ "$(yq ea -o=json -I=0 '[.spec | has("dependsOn")]' "$dir/releases.yaml")" = '[false,true]' ]
	[ "$(yq ea -o=json -I=0 'select(.metadata.name == "compute-external-secrets") | .spec.dependsOn' "$dir/releases.yaml")" = \
		'[{"name":"compute-cert-manager"}]' ]
	[ "$(yq -o=json -I=0 '.spec.dependsOn' "$upstream/releases/external-secrets.yaml")" = '[{"name":"cert-manager","namespace":"cert-manager"}]' ]
}

@test "the stage compute-node-prep applies upstream's migration port reservation on sandbox-compute" {
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.kubeConfig, (.spec | has("dependsOn"))]' \
		"$SANDBOX_ROOT/clusters/compute/node-prep/stage.yaml")" = \
		'["./compute/node-prep","10m","1m","5m",{"secretRef":{"name":"kubeconfig-compute"}},false]' ]
	[ "$(yq -o=json -I=0 '[.resources, has("patches")]' "$SANDBOX_ROOT/compute/node-prep/kustomization.yaml")" = \
		'[["../../vendor/cobaltcore/deploy/overlays/metal-stack/migration-ports"],false]' ]
	[ -f "$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/migration-ports/kustomization.yaml" ]
}

@test "the module libvirt applies the four vendored files, merges host-prepare.sh into libvirt-lab, and its stage waits for access, controllers and node-prep, not for the pods" {
	local dir=$SANDBOX_ROOT/compute/libvirt stage=$SANDBOX_ROOT/clusters/compute/libvirt/stage.yaml file
	[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = \
		'["../../vendor/cobaltcore/deploy/bases/tls/cluster-issuer.yaml","../../vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/libvirt-ca.yaml","../../vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/libvirt-configmap.yaml","../../vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/libvirt-daemonset.yaml"]' ]
	for file in $(yq '.resources[]' "$dir/kustomization.yaml"); do
		[ -f "$dir/$file" ]
	done
	[ "$(yq -o=json -I=0 '[.configMapGenerator, has("patches")]' "$dir/kustomization.yaml")" = \
		'[[{"name":"libvirt-lab","namespace":"openstack","behavior":"merge","files":["host-prepare.sh"]}],false]' ]
	# The ConfigMap the generator merges into, and the key it replaces.
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name, .metadata.namespace, (.data | keys)]' \
		"$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/libvirt-configmap.yaml")" = \
		'["ConfigMap","libvirt-lab","openstack",["host-prepare.sh","libvirtd.sh","ceph-secret.sh","libvirtd.conf","qemu.conf"]]' ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.kubeConfig]' "$stage")" = \
		'[[{"name":"compute-access"},{"name":"compute-controllers"},{"name":"compute-node-prep"}],"./compute/libvirt","10m","1m","5m",{"secretRef":{"name":"kubeconfig-compute"}}]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		'[{"apiVersion":"apps/v1","kind":"DaemonSet","current":"status.observedGeneration == metadata.generation"}]' ]
}

@test "the module kvm-node-agent releases upstream's chart with upstream's values from the hub without waiting for its pods, after the stage of libvirt" {
	local dir=$SANDBOX_ROOT/compute/kvm-node-agent upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor
	local stage=$SANDBOX_ROOT/clusters/compute/kvm-node-agent/stage.yaml
	[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = '["source.yaml","release.yaml"]' ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name, .metadata.namespace, .spec]' "$dir/source.yaml")" = \
		"$(yq ea -o=json -I=0 'select(.metadata.name == "kvm-node-agent") | [.kind, .metadata.name, .metadata.namespace, .spec]' "$upstream/sources.yaml")" ]
	[ "$(yq -o=json -I=0 '[.spec.interval, .spec.values, .spec.postRenderers]' "$dir/release.yaml")" = \
		"$(yq -o=json -I=0 '[.spec.interval, .spec.values, .spec.postRenderers]' "$upstream/kna-release.yaml")" ]
	[ "$(yq -o=json -I=0 '[.metadata.name, .metadata.namespace, .spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.chartRef, .spec.kubeConfig, .spec.install, .spec.upgrade]' "$dir/release.yaml")" = \
		'["compute-kvm-node-agent","flux-system","kvm-node-agent","hypervisor-system","hypervisor-system",{"kind":"OCIRepository","name":"kvm-node-agent"},{"secretRef":{"name":"kubeconfig-compute"}},{"crds":"CreateReplace","disableWait":true},{"crds":"CreateReplace","disableWait":true}]' ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig"))]' "$stage")" = \
		'[[{"name":"compute-libvirt"}],"./compute/kvm-node-agent","10m","1m","5m",false]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '[.spec.healthCheckExprs[] | select(.kind == "HelmRelease")]' "$SANDBOX_ROOT/clusters/compute/access/stage.yaml")" ]
}

@test "the stage of hypervisor-fixtures applies upstream's lab fixtures after controlplane and waits for the seven K-ORC kinds to be Available" {
	local file=$SANDBOX_ROOT/clusters/management/hypervisor-fixtures/stage.yaml expected
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig"))]' "$file")" = \
		'[[{"name":"management-controlplane"}],"./controlplane/hypervisor-fixtures","10m","1m","15m",false]' ]
	expected=$(jq -n -c --arg available "status.conditions.exists(c, c.type == 'Available' && c.status == 'True')" '
		[("Domain", "Project", "User", "Role", "RoleAssignment", "Flavor", "Image")
		 | {apiVersion: "openstack.k-orc.cloud/v1alpha1", kind: ., current: $available}]')
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$file")" = "$expected" ]
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/controlplane/hypervisor-fixtures/kustomization.yaml")" = \
		'["../../vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor-fixtures"]' ]
}

@test "the stage compute-trust applies the module trust on sandbox-compute after access and pki and substitutes from the ConfigMap sandbox-trust alone" {
	local stage=$SANDBOX_ROOT/clusters/compute/trust/stage.yaml
	run stage_contract "$SANDBOX_ROOT" compute/trust
	echo "point $output"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.kubeConfig]' "$stage")" = \
		'[[{"name":"compute-access"},{"name":"management-pki"}],"./compute/trust","10m","1m","2m",{"secretRef":{"name":"kubeconfig-compute"}}]' ]
	[ "$(yq -o=json -I=0 '.spec.postBuild' "$stage")" = '{"substituteFrom":[{"kind":"ConfigMap","name":"sandbox-trust"}]}' ]
}

@test "the stage compute-hypervisor-operator applies the module on sandbox-management after libvirt, trust and hypervisor-fixtures and waits for the release" {
	local stage=$SANDBOX_ROOT/clusters/compute/hypervisor-operator/stage.yaml
	run stage_contract "$SANDBOX_ROOT" compute/hypervisor-operator
	echo "point $output"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig"))]' "$stage")" = \
		'[[{"name":"compute-libvirt"},{"name":"compute-trust"},{"name":"management-hypervisor-fixtures"}],"./compute/hypervisor-operator","10m","1m","10m",false]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '.spec.healthCheckExprs' "$SANDBOX_ROOT/clusters/compute/kvm-node-agent/stage.yaml")" ]
}

@test "a release of compute/hypervisor-operator without kubeConfig breaks point 4" {
	tree_copy
	yq -i 'del(.spec.kubeConfig)' "$BATS_TEST_TMPDIR/tree/compute/hypervisor-operator/release.yaml"
	run stage_contract "$BATS_TEST_TMPDIR/tree" compute/hypervisor-operator
	echo "point $output"
	[ "$status" -eq 1 ]
	[ "$output" = 4 ]
}

@test "the stage management-compute-pool applies the pool after controlplane and trust, substitutes cluster-vars and COMPUTE_CLUSTER, and waits for the three objects; neither it nor the stage of hvo depends on the other" {
	local stage=$SANDBOX_ROOT/clusters/management/compute-pool/stage.yaml
	run stage_contract "$SANDBOX_ROOT" management/compute-pool
	echo "point $output"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout]' "$stage")" = \
		'[[{"name":"management-controlplane"},{"name":"compute-trust"}],"./controlplane/compute-pool","10m","1m","20m"]' ]
	[ "$(yq '[.spec.dependsOn[].name] | contains(["compute-hypervisor-operator"])' "$stage")" = false ]
	[ "$(yq '[.spec.dependsOn[].name] | contains(["management-compute-pool"])' "$SANDBOX_ROOT/clusters/compute/hypervisor-operator/stage.yaml")" = false ]
	[ "$(yq -o=json -I=0 '.spec.postBuild' "$stage")" = \
		'{"substitute":{"COMPUTE_CLUSTER":"sandbox-compute"},"substituteFrom":[{"kind":"ConfigMap","name":"cluster-vars"}]}' ]
	# The three objects are waited for as the ControlPlane is.
	[ "$(yq -o=json -I=0 '[.spec.healthCheckExprs[] | [.apiVersion, .kind]]' "$stage")" = \
		'[["ovn.openstack.c5c3.io/v1alpha1","OVNChassis"],["neutron.openstack.c5c3.io/v1alpha1","NeutronMetadataAgent"],["nova.openstack.c5c3.io/v1alpha1","NovaCompute"]]' ]
	[ "$(yq -o=json -I=0 '[.spec.healthCheckExprs[].current] | unique' "$stage")" = \
		"$(yq -o=json -I=0 '[.spec.healthCheckExprs[].current]' "$SANDBOX_ROOT/clusters/management/controlplane/stage.yaml")" ]
}

@test "the module trust puts the sandbox CA into the Secrets nova-metadata-ca and sandbox-ca in openstack" {
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/compute/trust/kustomization.yaml")" = '["secrets.yaml"]' ]
	[ "$(yq ea -o=json -I=0 '[[.apiVersion, .kind, .metadata.namespace, .metadata.name, .data]]' "$SANDBOX_ROOT/compute/trust/secrets.yaml")" = \
		'[["v1","Secret","openstack","nova-metadata-ca",{"ca.crt":"${SANDBOX_CA_B64}"}],["v1","Secret","openstack","sandbox-ca",{"ca.crt":"${SANDBOX_CA_B64}"}]]' ]
}

@test "the module hypervisor-operator releases upstream's chart from the hub with upstream's six values and auth_url from the copy of the auth Secret" {
	local dir=$SANDBOX_ROOT/compute/hypervisor-operator upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor
	local release=$dir/release.yaml
	[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = '["source.yaml","auth.yaml","release.yaml"]' ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name, .metadata.namespace, .spec]' "$dir/source.yaml")" = \
		"$(yq ea -o=json -I=0 'select(.metadata.name == "openstack-hypervisor-operator") | [.kind, .metadata.name, .metadata.namespace, .spec]' "$upstream/sources.yaml")" ]
	[ "$(yq -o=json -I=0 '[.metadata.name, .metadata.namespace, .spec.interval, .spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.chartRef, .spec.kubeConfig, .spec.install, .spec.upgrade]' "$release")" = \
		'["compute-hypervisor-operator","flux-system","30m","openstack-hypervisor-operator","openstack","openstack",{"kind":"OCIRepository","name":"openstack-hypervisor-operator"},{"secretRef":{"name":"kubeconfig-compute"}},{"crds":"CreateReplace","remediation":{"retries":3}},{"crds":"CreateReplace","remediation":{"retries":3}}]' ]
	[ "$(yq -o=json -I=0 '.spec.valuesFrom[0:6]' "$release")" = "$(yq -o=json -I=0 '.spec.valuesFrom' "$upstream/hvo-release.yaml")" ]
	[ "$(yq -o=json -I=0 '.spec.valuesFrom[6:]' "$release")" = \
		'[{"kind":"Secret","name":"controlplane-nova-hypervisor-operator-auth","valuesKey":"auth_url","targetPath":"controllerManager.manager.env.osAuthUrl"}]' ]
	[ "$(yq -o=json -I=0 '.spec.values' "$release")" = \
		'{"fullnameOverride":"hypervisor-operator","controllerManager":{"manager":{"image":{"repository":"ghcr.io/c5c3/openstack-hypervisor-operator"},"env":{"certificateNamespace":"hypervisor-system","agentNamespaces":"openstack"}}},"serviceMonitor":{"enabled":false},"prometheusRules":{"create":false},"dashboards":{"create":false},"customResourceMetrics":{"create":false}}' ]
	# Beside upstream's values but osAuthUrl, which comes from the copy.
	[ "$(yq -o=json -I=0 '.spec.values.controllerManager.manager | .env |= del(.osAuthUrl)' "$upstream/hvo-release.yaml")" = \
		"$(yq -o=json -I=0 '.spec.values.controllerManager.manager' "$release")" ]
}

@test "the post-renderer of hvo mounts the Secret sandbox-ca, names it in SSL_CERT_FILE, appends upstream's argument and sets neither OS_CACERT nor OS_INTERFACE" {
	local release=$SANDBOX_ROOT/compute/hypervisor-operator/release.yaml upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/hvo-release.yaml
	local patch
	[ "$(yq -o=json -I=0 '[.spec.postRenderers[0].kustomize.patches[].target]' "$release")" = '[{"kind":"Deployment"},{"kind":"Deployment"}]' ]
	patch=$(yq '.spec.postRenderers[0].kustomize.patches[0].patch' "$release" | yq -o=json -I=0 '.')
	[ "$(jq -c '.spec.template.spec.containers' <<<"$patch")" = \
		'[{"name":"manager","imagePullPolicy":"Always","env":[{"name":"SSL_CERT_FILE","value":"/etc/sandbox-ca/ca.crt"}],"volumeMounts":[{"name":"sandbox-ca","mountPath":"/etc/sandbox-ca","readOnly":true}]}]' ]
	[ "$(jq -c '.spec.template.spec.volumes' <<<"$patch")" = '[{"name":"sandbox-ca","secret":{"secretName":"sandbox-ca"}}]' ]
	[ "$(yq '.spec.postRenderers[0].kustomize.patches[1].patch' "$release" | yq -o=json -I=0 '.')" = \
		"$(yq '.spec.postRenderers[0].kustomize.patches[1].patch' "$upstream" | yq -o=json -I=0 '.')" ]
	[ "$(yq '.spec.postRenderers[0].kustomize.patches[1].patch' "$release" | yq '.[0].value')" = --default-high-availability=false ]
	# The comments name both variables, no value does.
	[ "$(yq '[.. | select(tag == "!!str") | select(test("OS_(CACERT|INTERFACE)"))] | length' "$release")" = 0 ]
}

@test "the copy of the auth Secret of hvo is an ExternalSecret in flux-system behind an account that may get that one Secret" {
	local file=$SANDBOX_ROOT/compute/hypervisor-operator/auth.yaml
	[ "$(yq ea -o=json -I=0 '[.kind + "/" + .metadata.namespace + "/" + .metadata.name]' "$file")" = \
		'["ServiceAccount/flux-system/hypervisor-operator-auth","Role/openstack/hypervisor-operator-auth","RoleBinding/openstack/hypervisor-operator-auth","SecretStore/flux-system/hypervisor-operator-auth","ExternalSecret/flux-system/controlplane-nova-hypervisor-operator-auth"]' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "Role") | .rules' "$file")" = \
		'[{"apiGroups":[""],"resources":["secrets"],"resourceNames":["controlplane-nova-hypervisor-operator-auth"],"verbs":["get"]}]' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "RoleBinding") | [.roleRef, .subjects]' "$file")" = \
		'[{"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"hypervisor-operator-auth"},[{"kind":"ServiceAccount","name":"hypervisor-operator-auth","namespace":"flux-system"}]]' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "SecretStore") | .spec' "$file")" = \
		'{"provider":{"kubernetes":{"remoteNamespace":"openstack","server":{"caProvider":{"type":"ConfigMap","name":"kube-root-ca.crt","key":"ca.crt"}},"auth":{"serviceAccount":{"name":"hypervisor-operator-auth"}}}}}' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "ExternalSecret") | .spec' "$file")" = \
		'{"refreshInterval":"5m","secretStoreRef":{"kind":"SecretStore","name":"hypervisor-operator-auth"},"target":{"name":"controlplane-nova-hypervisor-operator-auth","template":{"metadata":{"labels":{"reconcile.fluxcd.io/watch":"Enabled"}}}},"dataFrom":[{"extract":{"key":"controlplane-nova-hypervisor-operator-auth"}}]}' ]
	# Every HelmRelease of the module reads its values from that copy.
	[ "$(yq ea -o=json -I=0 '[select(.kind == "HelmRelease") | .spec.valuesFrom[].name] | unique' "$SANDBOX_ROOT/compute/hypervisor-operator/release.yaml")" = \
		'["controlplane-nova-hypervisor-operator-auth"]' ]
}

@test "the module compute-pool applies upstream's chassis, agent and pool on the cluster COMPUTE_CLUSTER, with the agent at 768Mi over https and the pool on the virt type of the host" {
	local file=$SANDBOX_ROOT/controlplane/compute-pool/pool.yaml upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/hypervisor/compute.yaml
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/controlplane/compute-pool/kustomization.yaml")" = '["pool.yaml"]' ]
	[ "$(yq ea -o=json -I=0 '[[.apiVersion, .kind, .metadata.namespace, .metadata.name, .spec.targetClusterRef]]' "$file")" = \
		'[["ovn.openstack.c5c3.io/v1alpha1","OVNChassis","openstack","lab-chassis",{"name":"${COMPUTE_CLUSTER}"}],["neutron.openstack.c5c3.io/v1alpha1","NeutronMetadataAgent","openstack","lab-metadata-agent",{"name":"${COMPUTE_CLUSTER}"}],["nova.openstack.c5c3.io/v1alpha1","NovaCompute","openstack","lab",{"name":"${COMPUTE_CLUSTER}"}]]' ]
	# The chassis is upstream's; the agent and the pool keep upstream's
	# release, image, chassis, Nova and nodes.
	[ "$(yq ea -o=json -I=0 'select(.kind == "OVNChassis") | .spec | del(.targetClusterRef)' "$file")" = \
		"$(yq ea -o=json -I=0 'select(.kind == "OVNChassis") | .spec' "$upstream")" ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "NeutronMetadataAgent") | .spec | [.openStackRelease, .image, .chassisRef]' "$file")" = \
		"$(yq ea -o=json -I=0 'select(.kind == "NeutronMetadataAgent") | .spec | [.openStackRelease, .image, .chassisRef]' "$upstream")" ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "NeutronMetadataAgent") | .spec | [.novaMetadata, .resources]' "$file")" = \
		'[{"host":"nova-metadata.${ADDRESSES_GATEWAY//./-}.nip.io","port":443,"protocol":"https","caBundleSecretRef":{"name":"nova-metadata-ca"},"sharedSecretRef":{"name":"controlplane-nova-metadata-agent-secret"}},{"requests":{"memory":"768Mi"},"limits":{"memory":"768Mi"}}]' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "NovaCompute") | .spec | [.novaRef, .nodeSelector]' "$file")" = \
		"$(yq ea -o=json -I=0 'select(.kind == "NovaCompute") | .spec | [.novaRef, .nodeSelector]' "$upstream")" ]
	# No cpuMode, so Nova's default for the virt type applies.
	[ "$(yq ea -o=json -I=0 'select(.kind == "NovaCompute") | .spec.libvirt' "$file")" = '{"virtType":"${COMPUTE_VIRT_TYPE}","imagesType":"qcow2"}' ]
	[ "$(yq ea -o=json -I=0 'select(.kind == "NovaCompute") | .spec.extraConfig' "$file")" = \
		"$(jq -n -c '["keystone_authtoken", "service_user", "placement", "neutron", "glance"] | map({key: ., value: {cafile: "/etc/nova/compute-config/ca.crt"}}) | from_entries')" ]
}

@test "the c5c3-operator depends on no release that controllers suspends" {
	local pattern names name
	pattern=$(yq '.patches[] | select(.patch | test("/spec/suspend")) | .target.name' \
		"$SANDBOX_ROOT/infrastructure/controllers/kustomization.yaml")
	names=$(yq '.patches[] | select(.patch | test("/spec/dependsOn")) | .patch' \
		"$SANDBOX_ROOT/platform/operator/kustomization.yaml" | yq '.[0].value[].name')
	[ -n "$pattern" ]
	[ -n "$names" ]
	for name in $names; do
		[[ ! $name =~ ^($pattern)$ ]]
	done
}

@test "the module sizing holds the SizingProfile sandbox on the base Minimal" {
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind, .metadata.name, .spec.base]' "$SANDBOX_ROOT/platform/sizing/sizingprofile.yaml")" = \
		'["c5c3.io/v1alpha1","SizingProfile","sandbox","Minimal"]' ]
}

@test "the stage of orders applies ./orders after controlplane, substitutes nothing and settles a RabbitMQVhost that reports MessagingNotManaged or MessagingNotDeclared" {
	local file=$SANDBOX_ROOT/clusters/management/orders/stage.yaml ready expected
	[ "$(yq -o=json -I=0 '[.spec.dependsOn, .spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("postBuild")), (.spec | has("kubeConfig"))]' "$file")" = \
		'[[{"name":"management-controlplane"}],"./orders","10m","1m","15m",false,false]' ]
	ready="status.conditions.exists(c, c.type == 'Ready' && c.status == 'True')"
	expected=$(jq -n -c --arg ready "$ready" \
		--arg vhost "$ready || status.conditions.exists(c, c.type == 'VhostReady' && (c.reason == 'MessagingNotManaged' || c.reason == 'MessagingNotDeclared'))" '
		[("KeystoneUser", "KeystoneProject", "KeystoneRoleAssignment", "KeystoneCatalogEntry", "KeystoneApplicationCredential", "MariaDBDatabase")
		 | {apiVersion: "c5c3.io/v1alpha1", kind: ., current: $ready}]
		+ [{apiVersion: "c5c3.io/v1alpha1", kind: "RabbitMQVhost", current: $vhost}]')
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$file")" = "$expected" ]
}

@test "the patches Component of orders appends components/orders to the stage of controlplane and nothing else" {
	local file=$SANDBOX_ROOT/clusters/management/orders/patches/kustomization.yaml
	[ "$(yq -o=json -I=0 '[.patches[].target]' "$file")" = \
		'[{"group":"kustomize.toolkit.fluxcd.io","kind":"Kustomization","name":"management-controlplane"}]' ]
	[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/components/-","value":"components/orders"}]' ]
	[ -f "$SANDBOX_ROOT/controlplane/components/orders/kustomization.yaml" ]
}

@test "the patches Component of remote-compute appends its component and the published OVN databases to the stage of controlplane" {
	local file=$SANDBOX_ROOT/clusters/management/remote-compute/patches/kustomization.yaml ops flux
	[ ! -e "$SANDBOX_ROOT/clusters/management/remote-compute/stage.yaml" ]
	[ "$(yq -o=json -I=0 '[.patches[].target]' "$file")" = \
		'[{"group":"kustomize.toolkit.fluxcd.io","kind":"Kustomization","name":"management-controlplane"},{"group":"kustomize.toolkit.fluxcd.io","kind":"Kustomization","name":"management-controlplane"}]' ]
	[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/components/-","value":"components/remote-compute"}]' ]
	ops=$(yq '.patches[1].patch' "$file")
	[ "$(yq -o=json -I=0 '[.[] | [.op, .path]]' - <<<"$ops")" = '[["add","/spec/patches/-"]]' ]
	flux=$(yq '.[0].value' - <<<"$ops")
	[ "$(yq -o=json -I=0 '.target' - <<<"$flux")" = \
		'{"group":"ovn.openstack.c5c3.io","kind":"OVNCentral","name":"controlplane-ovn","namespace":"openstack"}' ]
	[ "$(yq '.patch' - <<<"$flux" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/northbound/externallyReachable","value":true},{"op":"add","path":"/spec/southbound/externallyReachable","value":true}]' ]
	# The stage declares the list the Flux patch appends to.
	[ "$(yq -o=json -I=0 '.spec.patches' "$SANDBOX_ROOT/clusters/management/controlplane/stage.yaml")" = '[]' ]
}

@test "the component remote-compute patches the ControlPlane controlplane alone with the remote compute contract of Nova" {
	local file=$SANDBOX_ROOT/controlplane/components/remote-compute/kustomization.yaml
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind, (.patches | length), has("resources")]' "$file")" = \
		'["kustomize.config.k8s.io/v1alpha1","Component",1,false]' ]
	[ "$(yq -o=json -I=0 '.patches[0].target' "$file")" = \
		'{"group":"c5c3.io","version":"v1alpha1","kind":"ControlPlane","name":"controlplane","namespace":"openstack"}' ]
	[ "$(component_patch remote-compute 0 | jq -c '[.apiVersion, .kind, .metadata.name, .metadata.namespace, (.spec | keys), (.spec.services | keys)]')" = \
		'["c5c3.io/v1alpha1","ControlPlane","controlplane","openstack",["services"],["nova"]]' ]
	[ "$(component_patch remote-compute 0 | jq -c '.spec.services.nova')" = \
		'{"remoteCompute":{"transportURLSecretRef":{"name":"controlplane-nova-remote-transport"}},"hypervisorOperator":{},"metadataGateway":{"parentRef":{"name":"openstack-gw"},"hostname":"nova-metadata.${ADDRESSES_GATEWAY//./-}.nip.io"},"consoleProxy":{"gateway":{"parentRef":{"name":"openstack-gw"},"hostname":"nova-console.${ADDRESSES_GATEWAY//./-}.nip.io"}}}' ]
	# The transport URL Secret is the one the module messaging-tls writes.
	[ "$(yq ea '[select(.kind == "ExternalSecret") | .spec.target.name] | contains(["controlplane-nova-remote-transport"])' \
		"$SANDBOX_ROOT/infrastructure/messaging-tls/transport.yaml")" = true ]
}

@test "the component orders assigns exactly the namespaces of orders/, each with the role member and catalog entries" {
	local file=$SANDBOX_ROOT/controlplane/components/orders/kustomization.yaml ops owners
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind, (.patches | length), has("resources")]' "$file")" = \
		'["kustomize.config.k8s.io/v1alpha1","Component",1,false]' ]
	[ "$(yq -o=json -I=0 '.patches[0].target' "$file")" = \
		'{"group":"c5c3.io","version":"v1alpha1","kind":"ControlPlane","name":"controlplane","namespace":"openstack"}' ]
	ops=$(component_patch orders 0)
	[ "$(jq -c '[.[] | [.op, .path]]' <<<"$ops")" = '[["add","/spec/namespaceAssignments"]]' ]
	owners=$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/orders/kustomization.yaml")
	[ "$owners" != '[]' ]
	[ "$(jq -c '[.[0].value[].namespace]' <<<"$ops")" = "$owners" ]
	# No targetClusterRef: every namespace is on the management cluster.
	[ "$(jq -c '[.[0].value[] | del(.namespace)] | unique' <<<"$ops")" = '[{"allowedRoles":["member"],"allowCatalogEntries":true}]' ]
}

@test "each owner of orders/ holds its Namespace and one order of each of the seven kinds on the ControlPlane controlplane, each order with ssa Merge" {
	local owner dir count=0
	[ "$(yq -o=json -I=0 '[.apiVersion, .kind]' "$SANDBOX_ROOT/orders/kustomization.yaml")" = \
		'["kustomize.config.k8s.io/v1beta1","Kustomization"]' ]
	for owner in $(yq '.resources[]' "$SANDBOX_ROOT/orders/kustomization.yaml"); do
		dir=$SANDBOX_ROOT/orders/$owner
		echo "$owner"
		[ "$(yq -o=json -I=0 '.resources' "$dir/kustomization.yaml")" = '["namespace.yaml","orders.yaml"]' ]
		[ "$(yq -o=json -I=0 '[.apiVersion, .kind, .metadata.name]' "$dir/namespace.yaml")" = "[\"v1\",\"Namespace\",\"$owner\"]" ]
		[ "$(yq ea -o=json -I=0 '[.kind] | sort' "$dir/orders.yaml")" = \
			'["KeystoneApplicationCredential","KeystoneCatalogEntry","KeystoneProject","KeystoneRoleAssignment","KeystoneUser","MariaDBDatabase","RabbitMQVhost"]' ]
		[ "$(yq ea -o=json -I=0 '[[.apiVersion, .metadata.namespace, .metadata.annotations["kustomize.toolkit.fluxcd.io/ssa"], .spec.controlPlaneRef]] | unique' "$dir/orders.yaml")" = \
			"[[\"c5c3.io/v1alpha1\",\"$owner\",\"Merge\",{\"name\":\"controlplane\",\"namespace\":\"openstack\"}]]" ]
		count=$((count + 1))
	done
	[ "$count" -ge 1 ]

	# The orders of workflow are those of Steps 3 to 9 of upstream's Quick
	# Start (Orders).
	[ "$(yq ea -o=json -I=0 '[[.kind, .metadata.name, (.spec | del(.controlPlaneRef))]]' "$SANDBOX_ROOT/orders/workflow/orders.yaml")" = \
		'[["KeystoneUser","workflow",{}],["KeystoneProject","workflow-project",{}],["KeystoneRoleAssignment","workflow-member",{"userRef":{"name":"workflow"},"projectRef":{"name":"workflow-project"},"role":"member"}],["KeystoneCatalogEntry","workflow-dns",{"serviceType":"dns","serviceName":"designate","endpoints":[{"interface":"public","url":"https://dns.example.test/v2"}]}],["KeystoneApplicationCredential","workflow-appcred",{"userRef":{"name":"workflow"},"projectRef":{"name":"workflow-project"}}],["MariaDBDatabase","workflow-db",{}],["RabbitMQVhost","workflow-bus",{}]]' ]
}

@test "the example application credential carries no rotation, and the database and the vhost no deletionPolicy" {
	local file=$SANDBOX_ROOT/orders/workflow/orders.yaml
	[ "$(yq ea -o=json -I=0 '[select(.kind == "KeystoneApplicationCredential") | .spec | has("rotation")]' "$file")" = '[false]' ]
	[ "$(yq ea -o=json -I=0 '[select(.kind == "MariaDBDatabase" or .kind == "RabbitMQVhost") | .spec | has("deletionPolicy")]' "$file")" = '[false,false]' ]
}

@test "the four stages of sandbox-storage meet the stage contract, rook-operator after rook-crds and ceph-cluster after rook-operator and block-devices" {
	local module
	for module in block-devices rook-crds rook-operator ceph-cluster; do
		run stage_contract "$SANDBOX_ROOT" "storage/$module"
		echo "storage/$module: point $output"
		[ "$status" -eq 0 ]
	done
	[ "$(yq -o=json -I=0 '.spec.dependsOn' "$SANDBOX_ROOT/clusters/storage/rook-operator/stage.yaml")" = '[{"name":"storage-rook-crds"}]' ]
	[ "$(yq -o=json -I=0 '.spec.dependsOn' "$SANDBOX_ROOT/clusters/storage/ceph-cluster/stage.yaml")" = \
		'[{"name":"storage-rook-operator"},{"name":"storage-block-devices"}]' ]
}

@test "the stages storage-block-devices and storage-rook-crds apply their modules on sandbox-storage without a dependency" {
	local module
	for module in block-devices rook-crds; do
		echo "$module"
		[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.kubeConfig, (.spec | has("dependsOn"))]' \
			"$SANDBOX_ROOT/clusters/storage/$module/stage.yaml")" = \
			"[\"./storage/$module\",\"10m\",\"1m\",\"2m\",{\"secretRef\":{\"name\":\"kubeconfig-storage\"}},false]" ]
	done
}

@test "the module block-devices holds the StorageClass sandbox-block alone, without a provisioner" {
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/storage/block-devices/kustomization.yaml")" = '["storageclass.yaml"]' ]
	[ "$(yq ea -o=json -I=0 '[[.apiVersion, .kind, .metadata.name, .provisioner, .volumeBindingMode, .reclaimPolicy]]' "$SANDBOX_ROOT/storage/block-devices/storageclass.yaml")" = \
		'[["storage.k8s.io/v1","StorageClass","sandbox-block","kubernetes.io/no-provisioner","WaitForFirstConsumer","Retain"]]' ]
}

@test "the module rook-crds applies upstream's Namespace and ClientProfile CRD, unchanged, and nothing else" {
	local file
	[ "$(yq -o=json -I=0 '[.resources, has("patches"), has("components")]' "$SANDBOX_ROOT/storage/rook-crds/kustomization.yaml")" = \
		'[["../../vendor/cobaltcore/deploy/overlays/metal-stack/ceph/namespace.yaml","../../vendor/cobaltcore/deploy/overlays/metal-stack/ceph/csi-clientprofile-crd.yaml"],false,false]' ]
	for file in $(yq '.resources[]' "$SANDBOX_ROOT/storage/rook-crds/kustomization.yaml"); do
		[ -f "$SANDBOX_ROOT/storage/rook-crds/$file" ]
	done
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name]' "$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/ceph/namespace.yaml")" = '["Namespace","rook-ceph"]' ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.name]' "$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/ceph/csi-clientprofile-crd.yaml")" = \
		'["CustomResourceDefinition","clientprofiles.csi.ceph.io"]' ]
}

@test "the stage storage-rook-operator applies the source and the release on sandbox-management after rook-crds and waits for the release" {
	local stage=$SANDBOX_ROOT/clusters/storage/rook-operator/stage.yaml
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig")), (.spec | has("postBuild"))]' "$stage")" = \
		'["./storage/rook-operator","10m","1m","10m",false,false]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '.spec.healthCheckExprs' "$SANDBOX_ROOT/clusters/compute/controllers/stage.yaml")" ]
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/storage/rook-operator/kustomization.yaml")" = '["source.yaml","release.yaml"]' ]
}

@test "the source and the release of rook-operator are upstream's, under names of their own, with allowLoopDevices and the kubeconfig of storage" {
	local dir=$SANDBOX_ROOT/storage/rook-operator upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/overlays/metal-stack/ceph
	local fields='[.spec.chart.spec.chart, .spec.chart.spec.version, .spec.install, .spec.upgrade]'
	[ "$(yq -o=json -I=0 '[.kind, .metadata.namespace, .metadata.name, .spec]' "$dir/source.yaml")" = \
		"$(yq -o=json -I=0 '[.kind, .metadata.namespace, "storage-" + .metadata.name, .spec]' "$upstream/source.yaml")" ]
	[ "$(yq -o=json -I=0 "$fields" "$dir/release.yaml")" = "$(yq -o=json -I=0 "$fields" "$upstream/release.yaml")" ]
	[ "$(yq -o=json -I=0 '.spec.values' "$dir/release.yaml")" = "$(yq -o=json -I=0 '.spec.values + {"allowLoopDevices": true}' "$upstream/release.yaml")" ]
	[ "$(yq -o=json -I=0 '[.kind, .metadata.namespace, .metadata.name, .spec.interval, .spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.chart.spec.sourceRef, .spec.kubeConfig]' "$dir/release.yaml")" = \
		'["HelmRelease","flux-system","storage-rook-ceph","30m","rook-ceph","rook-ceph","rook-ceph",{"kind":"HelmRepository","name":"storage-rook-release"},{"secretRef":{"name":"kubeconfig-storage"}}]' ]
	# Upstream's release lives in rook-ceph and names its source in flux-system.
	[ "$(yq -o=json -I=0 '[.metadata.namespace, .spec.chart.spec.sourceRef]' "$upstream/release.yaml")" = \
		'["rook-ceph",{"kind":"HelmRepository","name":"rook-release","namespace":"flux-system"}]' ]
}

@test "a release of storage/rook-operator without kubeConfig breaks point 4" {
	tree_copy
	yq -i 'del(.spec.kubeConfig)' "$BATS_TEST_TMPDIR/tree/storage/rook-operator/release.yaml"
	run stage_contract "$BATS_TEST_TMPDIR/tree" storage/rook-operator
	echo "point $output"
	[ "$status" -eq 1 ]
	[ "$output" = 4 ]
}

@test "the stage storage-controllers applies the source and the release of External Secrets on sandbox-management without a dependency and waits for the release" {
	local stage=$SANDBOX_ROOT/clusters/storage/controllers/stage.yaml
	run stage_contract "$SANDBOX_ROOT" storage/controllers
	echo "point $output"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, (.spec | has("kubeConfig")), (.spec | has("dependsOn")), (.spec | has("postBuild"))]' "$stage")" = \
		'["./storage/controllers","10m","1m","10m",false,false,false]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		"$(yq -o=json -I=0 '.spec.healthCheckExprs' "$SANDBOX_ROOT/clusters/compute/controllers/stage.yaml")" ]
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/storage/controllers/kustomization.yaml")" = '["sources.yaml","releases.yaml"]' ]
}

@test "the source and the release of storage/controllers are upstream's External Secrets, under names of their own, without dependsOn and with the kubeconfig of storage" {
	local dir=$SANDBOX_ROOT/storage/controllers upstream=$SANDBOX_ROOT/vendor/cobaltcore/deploy/bases/operators
	local fields='[.spec.interval, .spec.chart.spec.chart, .spec.chart.spec.version, .spec.values, .spec.install, .spec.upgrade]'
	[ "$(yq ea -o=json -I=0 '[.kind + "/" + .metadata.namespace + "/" + .metadata.name]' "$dir/sources.yaml" "$dir/releases.yaml")" = \
		'["HelmRepository/flux-system/storage-external-secrets","HelmRelease/flux-system/storage-external-secrets"]' ]
	[ "$(yq -o=json -I=0 '[.spec.interval, .spec.url]' "$dir/sources.yaml")" = \
		"$(yq -o=json -I=0 '[.spec.interval, .spec.url]' "$upstream/sources/external-secrets.yaml")" ]
	[ "$(yq -o=json -I=0 "$fields" "$dir/releases.yaml")" = "$(yq -o=json -I=0 "$fields" "$upstream/releases/external-secrets.yaml")" ]
	[ "$(yq -o=json -I=0 '[.spec.releaseName, .spec.targetNamespace, .spec.storageNamespace, .spec.chart.spec.sourceRef, .spec.kubeConfig, (.spec | has("dependsOn"))]' "$dir/releases.yaml")" = \
		'["external-secrets","external-secrets","external-secrets",{"kind":"HelmRepository","name":"storage-external-secrets"},{"secretRef":{"name":"kubeconfig-storage"}},false]' ]
	# Upstream's release waits for cert-manager, which the storage cluster
	# does not run.
	[ "$(yq -o=json -I=0 '.spec.dependsOn' "$upstream/releases/external-secrets.yaml")" = '[{"name":"cert-manager","namespace":"cert-manager"}]' ]
}

@test "a release of storage/controllers without kubeConfig breaks point 4" {
	tree_copy
	yq -i 'del(.spec.kubeConfig)' "$BATS_TEST_TMPDIR/tree/storage/controllers/releases.yaml"
	run stage_contract "$BATS_TEST_TMPDIR/tree" storage/controllers
	echo "point $output"
	[ "$status" -eq 1 ]
	[ "$output" = 4 ]
}

@test "the module ceph-cluster applies upstream's cluster, pools, clients and toolbox without the key hand-off, and the pool .mgr" {
	local upstream=../../vendor/cobaltcore/deploy/overlays/metal-stack/ceph/cluster file
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/storage/ceph-cluster/kustomization.yaml")" = \
		"[\"$upstream/cluster.yaml\",\"$upstream/pools.yaml\",\"$upstream/clients.yaml\",\"$upstream/toolbox.yaml\",\"mgr-pool.yaml\"]" ]
	for file in $(yq '.resources[]' "$SANDBOX_ROOT/storage/ceph-cluster/kustomization.yaml"); do
		[ -f "$SANDBOX_ROOT/storage/ceph-cluster/$file" ]
	done
	# Upstream's directory holds the key hand-off, which the module leaves out.
	[ -f "$SANDBOX_ROOT/storage/ceph-cluster/$upstream/keys-push.yaml" ]
	[ -f "$SANDBOX_ROOT/storage/ceph-cluster/$upstream/keys-pull.yaml" ]
	[ "$(yq ea -o=json -I=0 '[[.apiVersion, .kind, .metadata.namespace, .metadata.name, .spec]]' "$SANDBOX_ROOT/storage/ceph-cluster/mgr-pool.yaml")" = \
		'[["ceph.rook.io/v1","CephBlockPool","rook-ceph","builtin-mgr",{"name":".mgr","failureDomain":"osd","enableCrushUpdates":true,"replicated":{"size":"${STORAGE_POOL_SIZE}","requireSafeReplicaSize":false}}]]' ]
}

@test "the patches of ceph-cluster put the CephCluster on host networking and the loop devices, the pools on failure domain osd, and keep the toolbox from the substitution" {
	local file=$SANDBOX_ROOT/storage/ceph-cluster/kustomization.yaml
	[ "$(yq -o=json -I=0 '[.patches[].target]' "$file")" = \
		'[{"kind":"CephCluster","name":"rook-ceph"},{"kind":"CephBlockPool","name":"volumes|backups"},{"kind":"Deployment","name":"rook-ceph-tools"}]' ]
	[ "$(yq '.patches[0].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/spec/network/provider","value":"host"},{"op":"replace","path":"/spec/cephConfig/global/osd_pool_default_size","value":"1"},{"op":"add","path":"/spec/cephConfig/global/mon_warn_on_pool_no_redundancy","value":"false"},{"op":"add","path":"/spec/cephConfig/global/mon_data_avail_warn","value":"10"},{"op":"add","path":"/spec/healthCheck/muteHealthWarning/BLUESTORE_SLOW_OP_ALERT","value":{"policy":"mute"}},{"op":"replace","path":"/spec/resources/mon/requests/memory","value":"512Mi"},{"op":"replace","path":"/spec/resources/mgr/requests/memory","value":"256Mi"},{"op":"replace","path":"/spec/storage/storageClassDeviceSets/0/name","value":"loop"},{"op":"replace","path":"/spec/storage/storageClassDeviceSets/0/count","value":"${SWITCHES_OSD_COUNT}"},{"op":"replace","path":"/spec/storage/storageClassDeviceSets/0/resources/requests/memory","value":"1Gi"},{"op":"add","path":"/spec/storage/storageClassDeviceSets/0/volumeClaimTemplates/0/spec/storageClassName","value":"sandbox-block"},{"op":"replace","path":"/spec/storage/storageClassDeviceSets/0/volumeClaimTemplates/0/spec/resources/requests/storage","value":"${SWITCHES_OSD_SIZE}"}]' ]
	[ "$(yq '.patches[1].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"replace","path":"/spec/failureDomain","value":"osd"},{"op":"replace","path":"/spec/replicated/size","value":"${STORAGE_POOL_SIZE}"},{"op":"replace","path":"/spec/replicated/requireSafeReplicaSize","value":false}]' ]
	[ "$(yq '.patches[2].patch' "$file" | yq -o=json -I=0 '.')" = \
		'[{"op":"add","path":"/metadata/annotations","value":{"kustomize.toolkit.fluxcd.io/substitute":"disabled"}}]' ]
}

@test "the stage storage-ceph-cluster applies the module on sandbox-storage after rook-operator and block-devices and waits for a healthy cluster, its pools and its clients" {
	local stage=$SANDBOX_ROOT/clusters/storage/ceph-cluster/stage.yaml
	[ "$(yq -o=json -I=0 '[.spec.path, .spec.interval, .spec.retryInterval, .spec.timeout, .spec.kubeConfig]' "$stage")" = \
		'["./storage/ceph-cluster","10m","1m","30m",{"secretRef":{"name":"kubeconfig-storage"}}]' ]
	[ "$(yq -o=json -I=0 '.spec.healthCheckExprs' "$stage")" = \
		'[{"apiVersion":"ceph.rook.io/v1","kind":"CephCluster","current":"status.phase == '"'"'Ready'"'"' && status.ceph.health == '"'"'HEALTH_OK'"'"'"},{"apiVersion":"ceph.rook.io/v1","kind":"CephBlockPool","current":"status.phase == '"'"'Ready'"'"'"},{"apiVersion":"ceph.rook.io/v1","kind":"CephClient","current":"status.phase == '"'"'Ready'"'"'"}]' ]
}
