#!/usr/bin/env bats
# The tree Flux reads: the stage contract of every module of a cluster, the
# kustomization of each cluster, and no literal address in a manifest.

setup() {
	load helpers
}

# stage_contract <root> <role>/<module>: checks the directory
# <root>/clusters/<role>/<module>/ against the stage contract and prints the
# number of the first point it breaks.
stage_contract() {
	local root=$1 role=${2%/*} module=${2#*/} dir path dep
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

	# 4. The kubeconfig Secret of the role, and none for management.
	if [ "$role" = management ]; then
		[ "$(yq '.spec | has("kubeConfig")' "$dir/stage.yaml")" = false ] || { echo 4; return 1; }
	else
		[ "$(yq '.spec.kubeConfig.secretRef.name' "$dir/stage.yaml")" = "kubeconfig-$role" ] || { echo 4; return 1; }
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

# tree_copy: copies clusters/ and infrastructure/ into $BATS_TEST_TMPDIR/tree.
tree_copy() {
	rm -rf -- "$BATS_TEST_TMPDIR/tree"
	mkdir -- "$BATS_TEST_TMPDIR/tree"
	cp -R -- "$SANDBOX_ROOT/clusters" "$SANDBOX_ROOT/infrastructure" "$BATS_TEST_TMPDIR/tree/"
}

@test "every module of a cluster meets the stage contract" {
	local dir count=0
	for dir in "$SANDBOX_ROOT"/clusters/*/*/; do
		dir=${dir%/}
		run stage_contract "$SANDBOX_ROOT" "${dir#"$SANDBOX_ROOT"/clusters/}"
		echo "${dir#"$SANDBOX_ROOT"/}: point $output"
		[ "$status" -eq 0 ]
		count=$((count + 1))
	done
	[ "$count" -ge 3 ]
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
5 storage/test stage.yaml .spec.dependsOn[0].name = "management-nothere"
5 compute/test stage.yaml .spec.dependsOn += [{"name": "network-test"}]
EOF
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
