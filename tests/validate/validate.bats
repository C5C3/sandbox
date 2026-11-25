#!/usr/bin/env bats
# scripts/validate.sh on a copy of the fixture tree, with the real flux and
# kubeconform of scripts/install-validate-tools.sh. It needs the network for
# the schemas of Kubernetes and Flux, which the validation cache keeps.
#
# Each test commits the vendor/cobaltcore of its copy as a git repository,
# pins that commit in the copy's config.yaml and changes the copy.

setup() {
	# make exports the configuration and the profile of the repository.
	unset SANDBOX_CONFIG SANDBOX_PROFILE SANDBOX_PROFILE_DIR SANDBOX_PROFILE_FILE SANDBOX_UPSTREAM_URL
	export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
	export SANDBOX_CRD_SOURCES=$BATS_TEST_DIRNAME/fixtures/crd-sources.yaml
	ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	TREE=$BATS_TEST_TMPDIR/tree
	STAGE=$TREE/clusters/management/base/stage.yaml
	BASE=$TREE/vendor/cobaltcore/deploy/bases/demo
	cp -R -- "$BATS_TEST_DIRNAME/fixtures/tree" "$TREE"
	git -c init.defaultBranch=main init --quiet -- "$TREE/vendor/cobaltcore"
	git -C "$TREE/vendor/cobaltcore" add -A
	git -C "$TREE/vendor/cobaltcore" -c user.name=test -c user.email=test@example.org commit --quiet -m fixture
	PIN=$(git -C "$TREE/vendor/cobaltcore" rev-parse HEAD)
	PIN=$PIN yq -i '.upstream.cobaltcore = strenv(PIN)' "$TREE/config.yaml"
}

validate() {
	run "$ROOT/scripts/validate.sh" "$TREE"
}

# sources_with <yaml>: points SANDBOX_CRD_SOURCES at a file with the text.
sources_with() {
	export SANDBOX_CRD_SOURCES=$BATS_TEST_TMPDIR/sources.yaml
	printf '%s\n' "$1" >"$SANDBOX_CRD_SOURCES"
}

# failed <checks>: the run exited 1 and named the checks in its last line.
failed() {
	[ "$status" -eq 1 ] && [ "${lines[-1]}" = "validate: failed: $1" ]
}

@test "the unchanged fixture passes with the vendored base, cluster-vars and the fields of the Widget" {
	validate
	[ "$status" -eq 0 ]
	[[ $'\n'$output == *$'\n'"validate: render: 3 roots and 1 stages rendered"$'\n'* ]]
	[[ $output == *$'\n'"validate: schemas: "*" schemas from 2 sources"$'\n'* ]]
	[[ $output == *$'\n'"validate: patches: 1 patches checked"$'\n'* ]]
	[ "${lines[-1]}" = "validate: all checks passed" ]
	[[ $output != *"local changes"* ]]
}

@test "a checkout with local changes passes and is reported" {
	touch "$BASE/notes.txt"
	validate
	[ "$status" -eq 0 ]
	[[ $output == *"validate: vendor: vendor/cobaltcore has local changes"* ]]
}

@test "a missing checkout, another pin and an incomplete configuration fail the vendor check alone" {
	yq -i '.upstream.cobaltcore = "0123456789abcdef0123456789abcdef01234567"' "$TREE/config.yaml"
	validate
	failed vendor
	[ "${lines[-2]}" = "validate: error: vendor: vendor/cobaltcore is at $PIN, the configuration pins 0123456789abcdef0123456789abcdef01234567; run make vendor" ]

	yq -i 'del(.flux.operator)' "$TREE/config.yaml"
	validate
	failed vendor
	[ "${lines[-2]}" = "validate: error: vendor: config: flux.operator is not set" ]

	PIN=$PIN yq -i '.flux.operator = "0.63.1" | .upstream.cobaltcore = strenv(PIN)' "$TREE/config.yaml"
	rm -rf -- "$TREE/vendor/cobaltcore/.git"
	validate
	failed vendor
	[ "${lines[-2]}" = "validate: error: vendor: vendor/cobaltcore not found; run make vendor" ]
}

@test "an undefined variable fails the render of the stage" {
	sed -i 's/NETWORK_SUBNET/NOT_SET/' "$TREE/infrastructure/base/settings.yaml"
	validate
	failed render
	[[ $'\n'$output == *$'\n''validate: error: render: stage management-base: '*'variable not set (strict mode): "NOT_SET"'$'\n'* ]]
}

@test "a variable of the stage wins over the one of cluster-vars" {
	# cluster-vars holds ADDRESSES_GATEWAY=172.30.255.10, and the Widget's
	# level is an integer.
	yq -i '.spec.postBuild.substitute.ADDRESSES_GATEWAY = "2"' "$STAGE"
	sed -i 's/level: 2/level: ${ADDRESSES_GATEWAY}/' "$BASE/widget.yaml"
	validate
	[ "$status" -eq 0 ]
}

@test "a stage without postBuild leaves \${...} as it is" {
	yq -i 'del(.spec.postBuild)' "$STAGE"
	validate
	[ "$status" -eq 0 ]
}

@test "a stage path that does not exist or leaves the tree fails" {
	local path
	for path in ./infrastructure/gone ../..; do
		P=$path yq -i '.spec.path = strenv(P)' "$STAGE"
		validate
		failed render
		[[ $output == *"validate: error: render: stage management-base: path $path does not exist in the tree"* ]]
	done
}

@test "a dependency on a stage the tree does not have fails the profile" {
	yq -i '.spec.dependsOn = [{"name": "management-gone"}]' "$STAGE"
	validate
	failed render
	[[ $output == *"validate: error: render: profile all: management/base depends on the stage management-gone, which the profile does not list"* ]]
}

@test "a Secret in substituteFrom fails unless it is optional" {
	yq -i '.spec.postBuild.substituteFrom += [{"kind": "Secret", "name": "extra"}]' "$STAGE"
	validate
	failed render
	[[ $output == *"validate: error: render: stage management-base: substituteFrom Secret extra cannot be resolved offline"* ]]

	yq -i '.spec.postBuild.substituteFrom[1].optional = true' "$STAGE"
	validate
	[ "$status" -eq 0 ]
}

@test "an unknown field of a Kubernetes kind and of a CRD fails kubeconform" {
	yq -i '.dta = {"mode": "x"}' "$BASE/configmap.yaml"
	validate
	failed kubeconform
	[[ $output == *"ConfigMap demo is invalid"*"additional properties 'dta' not allowed"* ]]

	git -C "$TREE/vendor/cobaltcore" checkout --quiet -- .
	yq -i '.spec.colour = "red"' "$BASE/widget.yaml"
	validate
	failed kubeconform
	[[ $output == *"Widget demo is invalid"*"additional properties 'colour' not allowed"* ]]
}

@test "a kind without a schema fails kubeconform" {
	printf 'apiVersion: demo.c5c3.io/v1\nkind: Gadget\nmetadata:\n  name: demo\n' >"$BASE/gadget.yaml"
	yq -i '.resources += ["gadget.yaml"]' "$BASE/kustomization.yaml"
	validate
	failed kubeconform
	[[ $output == *"could not find schema for Gadget"* ]]
}

@test "a patch of a kustomization fails when its target is gone or already has the value" {
	local expected='validate: error: patches: infrastructure/base/kustomization.yaml: patches[0] changes nothing in any stage: its target matches no resource, or the resource already has what the patch sets'
	yq -i '.metadata.name = "renamed"' "$BASE/configmap.yaml"
	validate
	failed patches
	[[ $output == *"$expected"* ]]

	git -C "$TREE/vendor/cobaltcore" checkout --quiet -- .
	yq -i '.data.mode = "sandbox"' "$BASE/configmap.yaml"
	validate
	failed patches
	[[ $output == *"$expected"* ]]
}

@test "a patch without which the stage does not render passes" {
	yq -i '.data.mode = "${UPSTREAM_ONLY}"' "$BASE/configmap.yaml"
	validate
	[ "$status" -eq 0 ]
	[[ $output == *"validate: patches: 1 patches checked"* ]]
}

@test "a patch of a stage fails when its target is gone" {
	yq -i '.spec.patches = [{"target": {"kind": "ConfigMap", "name": "gone"}, "patch": "- op: replace\n  path: /data/mode\n  value: x\n"}]' "$STAGE"
	validate
	failed patches
	[[ $output == *"validate: error: patches: stage management-base: spec.patches[0] changes nothing: its target matches no resource, or the resource already has what the patch sets"* ]]
	[[ $output == *"validate: patches: 2 patches checked"* ]]
}

# patches_component <stage>: writes the patches Component of the module base,
# whose one patch gives the stage the variable PATCHED that settings.yaml
# reads.
patches_component() {
	mkdir -p -- "$TREE/clusters/management/base/patches"
	cat >"$TREE/clusters/management/base/patches/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - target:
      group: kustomize.toolkit.fluxcd.io
      kind: Kustomization
      name: $1
    patch: |
      - op: add
        path: /spec/postBuild/substitute/PATCHED
        value: component
EOF
}

@test "the patch of a patches Component reaches the rendered stage, and one whose stage is gone fails" {
	yq -i '.data.patched = "${PATCHED}"' "$TREE/infrastructure/base/settings.yaml"
	validate
	failed render
	[[ $output == *'validate: error: render: stage management-base: '*'variable not set (strict mode): "PATCHED"'* ]]

	patches_component management-base
	validate
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"validate: patches: 2 patches checked"$'\n'* ]]

	patches_component management-nothere
	validate
	failed "render patches"
	[[ $output == *"validate: error: patches: clusters/management/base/patches/kustomization.yaml: patches[0] changes nothing in the root cluster-management: its target matches no resource, or the resource already has what the patch sets"* ]]
}

@test "patchesJson6902 in a kustomization is not checked and fails" {
	yq -i '.patchesJson6902 = [{"target": {"version": "v1", "kind": "ConfigMap", "name": "demo"}, "patch": "- op: add\n  path: /data/extra\n  value: x\n"}]' \
		"$TREE/infrastructure/base/kustomization.yaml"
	validate
	failed patches
	[[ $output == *"validate: error: patches: infrastructure/base/kustomization.yaml: patchesJson6902 is not checked; use patches"* ]]
}

@test "a failed check does not stop the next one" {
	yq -i '.spec.colour = "red"' "$BASE/widget.yaml"
	yq -i '.data.mode = "sandbox"' "$BASE/configmap.yaml"
	validate
	failed "kubeconform patches"
}

@test "a broken source of schemas fails with its name" {
	local file=$BATS_TEST_TMPDIR/sources.yaml glob='vendor/cobaltcore/operators/*/config/crd/none/*.yaml'

	sources_with "sources: [{name: cobaltcore, path: '$glob'}]"
	validate
	[[ ${lines[-1]} == "validate: failed: schemas"* ]]
	[[ $output == *"validate: error: schemas: cobaltcore: $glob matches no file"* ]]

	sources_with 'sources: [{name: flux, schemas: "http://example.org/crd-schemas.tar.gz"}]'
	validate
	[[ $output == *"validate: error: schemas: flux: http://example.org/crd-schemas.tar.gz is not an https:// URL"* ]]

	sources_with 'sources: [{name: flux, schemas: "https://invalid.invalid/crd-schemas.tar.gz"}]'
	validate
	[[ $output == *"validate: error: schemas: flux: cannot download https://invalid.invalid/crd-schemas.tar.gz: "?* ]]

	sources_with 'sources: [{name: both, schemas: "https://example.org/x.tar.gz", path: "x/*.yaml"}]'
	validate
	[[ $output == *"validate: error: schemas: both: needs exactly one of schemas, path and crds"* ]]

	sources_with 'sources: [{name: all, schemas: "https://example.org/x.tar.gz", path: "x/*.yaml", crds: "https://example.org/x.yaml"}, {name: none}]'
	validate
	[[ $output == *"validate: error: schemas: all: needs exactly one of schemas, path and crds"* ]]
	[[ $output == *"validate: error: schemas: none: needs exactly one of schemas, path and crds"* ]]

	sources_with 'sources: []'
	validate
	[[ ${lines[-1]} == "validate: failed: schemas"* ]]
	[[ $output == *"validate: error: schemas: no source in $file"* ]]
}

@test "a broken stream of CRDs fails with its name and is not kept" {
	# A cache of its own, with the tools of the one in use.
	local tools=${SANDBOX_VALIDATE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-validate}/bin
	export SANDBOX_VALIDATE_CACHE=$BATS_TEST_TMPDIR/cache
	mkdir -p -- "$SANDBOX_VALIDATE_CACHE/sources"
	ln -s -- "$tools" "$SANDBOX_VALIDATE_CACHE/bin"

	sources_with 'sources: [{name: metallb, crds: "http://example.org/crds.yaml"}]'
	validate
	[[ ${lines[-1]} == "validate: failed: schemas"* ]]
	[[ $output == *"validate: error: schemas: metallb: http://example.org/crds.yaml is not an https:// URL"* ]]

	sources_with 'sources: [{name: metallb, crds: "https://invalid.invalid/crds.yaml"}]'
	validate
	[[ $output == *"validate: error: schemas: metallb: cannot download https://invalid.invalid/crds.yaml: "?* ]]

	# A release asset of Envoy Gateway with a Gateway and no CRD.
	sources_with 'sources: [{name: quickstart, crds: "https://github.com/envoyproxy/gateway/releases/download/v1.9.3/quickstart.yaml"}]'
	validate
	[[ $output == *"validate: error: schemas: quickstart: https://github.com/envoyproxy/gateway/releases/download/v1.9.3/quickstart.yaml holds no CustomResourceDefinition"* ]]
	[ -z "$(find "$SANDBOX_VALIDATE_CACHE/sources" -type f)" ]

	# A cached stream that yq cannot read fails with the message of yq.
	printf 'kind: [\n' >"$SANDBOX_VALIDATE_CACHE/sources/$(printf '%s' https://example.org/broken.yaml | sha256sum | cut -d ' ' -f 1).yaml"
	sources_with 'sources: [{name: broken, crds: "https://example.org/broken.yaml"}]'
	validate
	[[ $output == *"validate: error: schemas: broken: https://example.org/broken.yaml: "?* ]]
	[ -z "$(find "$SANDBOX_VALIDATE_CACHE/sources" -type f)" ]
}

# pool_source: points SANDBOX_CRD_SOURCES at the sources of the fixture and
# the CRD of the MetalLB IPAddressPool as a stream.
pool_source() {
	export SANDBOX_CRD_SOURCES=$BATS_TEST_TMPDIR/sources.yaml
	yq '.sources += [{"name": "metallb", "crds": "https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/crd/bases/metallb.io_ipaddresspools.yaml"}]' \
		"$BATS_TEST_DIRNAME/fixtures/crd-sources.yaml" >"$SANDBOX_CRD_SOURCES"
}

@test "an IPAddressPool needs the stream of its CRD and fails for an unknown field" {
	printf 'apiVersion: metallb.io/v1beta1\nkind: IPAddressPool\nmetadata:\n  name: demo\n  namespace: demo\nspec:\n  addresses: [192.0.2.0/24]\n  autoAssign: false\n' >"$BASE/pool.yaml"
	yq -i '.resources += ["pool.yaml"]' "$BASE/kustomization.yaml"
	validate
	failed kubeconform
	[[ $output == *"could not find schema for IPAddressPool"* ]]

	pool_source
	validate
	[ "$status" -eq 0 ]
	[[ $output == *$'\n'"validate: schemas: "*" schemas from 3 sources"$'\n'* ]]

	yq -i '.spec.colour = "red"' "$BASE/pool.yaml"
	validate
	failed kubeconform
	[[ $output == *"IPAddressPool demo is invalid"*"additional properties 'colour' not allowed"* ]]
}

@test "a CustomResourceDefinition in a stage passes unchecked" {
	cp -- "$TREE/vendor/cobaltcore/operators/demo/config/crd/bases/demo.c5c3.io_widgets.yaml" "$BASE/crd.yaml"
	yq -i '.resources += ["crd.yaml"]' "$BASE/kustomization.yaml"
	validate
	[ "$status" -eq 0 ]
	[[ $output == *"Skipped: 1"* ]]
}

@test "missing tools fail the run before any other check" {
	local tool
	mkdir -- "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/cache"
	for tool in dirname mktemp rm mkdir realpath cp mv cmp find sort wc sha256sum cut paste sed grep tail cat \
		yq jq git curl tar; do
		ln -s -- "$(command -v "$tool")" "$BATS_TEST_TMPDIR/bin/$tool"
	done
	run env -i PATH="$BATS_TEST_TMPDIR/bin" HOME="$HOME" SANDBOX_VALIDATE_CACHE="$BATS_TEST_TMPDIR/cache" \
		"$BASH" "$ROOT/scripts/validate.sh" "$TREE"
	[ "$status" -eq 1 ]
	[ "$output" = "validate: error: tools: flux not found in PATH; run scripts/install-validate-tools.sh
validate: error: tools: kubeconform not found in PATH; run scripts/install-validate-tools.sh
validate: failed: tools" ]
}

@test "a second argument or one that is no directory is a usage error" {
	run "$ROOT/scripts/validate.sh" a b
	[ "$status" -eq 2 ]
	[ "$output" = "usage: scripts/validate.sh [<directory>]" ]
	run "$ROOT/scripts/validate.sh" /nonexistent
	[ "$status" -eq 2 ]
	[ "$output" = "usage: scripts/validate.sh [<directory>]" ]
}
