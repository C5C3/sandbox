#!/usr/bin/env bats
# The tree Flux reads: the stage contract of every module of a cluster, the
# kustomization of each cluster, and no literal address in a manifest. The
# modules of compute/ copy objects of upstream under names of their own, and
# the tests compare each copy with upstream's file, so this file needs the
# checkout of make vendor.

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

# tree_copy: copies clusters/, infrastructure/ and compute/ into
# $BATS_TEST_TMPDIR/tree.
tree_copy() {
	rm -rf -- "$BATS_TEST_TMPDIR/tree"
	mkdir -- "$BATS_TEST_TMPDIR/tree"
	cp -R -- "$SANDBOX_ROOT/clusters" "$SANDBOX_ROOT/infrastructure" "$SANDBOX_ROOT/compute" "$BATS_TEST_TMPDIR/tree/"
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

@test "every rule of the two tenant Roles and of the Role rabbitmq-transport names its objects" {
	local file count roles='select(.kind == "Role")'
	while read -r file count; do
		[ "$(yq ea "[$roles] | length" "$SANDBOX_ROOT/$file")" = "$count" ]
		[ "$(yq ea -o=json -I=0 "[$roles | .rules[] | select((.resourceNames // []) | length == 0)]" "$SANDBOX_ROOT/$file")" = '[]' ]
	done <<'EOF'
controlplane/tenant.yaml 2
infrastructure/messaging-tls/transport.yaml 1
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

@test "the stages of messaging-tls and controlplane substitute from cluster-vars" {
	local module
	for module in messaging-tls controlplane; do
		[ "$(yq -o=json -I=0 '.spec.postBuild' "$SANDBOX_ROOT/clusters/management/$module/stage.yaml")" = \
			'{"substituteFrom":[{"kind":"ConfigMap","name":"cluster-vars"}]}' ]
	done
}

@test "the stages of openbao, objectstore, platform, sizing, cinder-nfs, fake-compute, hypervisor-fixtures and of access, controllers, node-prep, libvirt and kvm-node-agent on compute substitute no variables" {
	local stage
	for stage in management/{openbao,objectstore,platform,sizing,cinder-nfs,fake-compute,hypervisor-fixtures} \
		compute/{access,controllers,node-prep,libvirt,kvm-node-agent}; do
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

@test "the module trust puts the sandbox CA into the Secrets nova-metadata-ca and sandbox-ca in openstack" {
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/compute/trust/kustomization.yaml")" = '["secrets.yaml"]' ]
	[ "$(yq ea -o=json -I=0 '[[.apiVersion, .kind, .metadata.namespace, .metadata.name, .data]]' "$SANDBOX_ROOT/compute/trust/secrets.yaml")" = \
		'[["v1","Secret","openstack","nova-metadata-ca",{"ca.crt":"${SANDBOX_CA_B64}"}],["v1","Secret","openstack","sandbox-ca",{"ca.crt":"${SANDBOX_CA_B64}"}]]' ]
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
