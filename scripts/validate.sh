#!/usr/bin/env bash
# Usage: validate.sh [<directory>]
#
# Validates the tree in the directory, by default the repository, against
# the checkout of upstream it holds. It reads the tree as flux build artifact
# packs it for make push, with vendor/cobaltcore and without .git/ and
# .sandbox/. The checks, in order:
#
#   tools        flux kubeconform yq jq git curl tar are in PATH, with
#                $SANDBOX_VALIDATE_CACHE/bin first
#   vendor       the configuration loads, and vendor/cobaltcore is a
#                checkout at its pin; local changes are reported, not failed
#   render       the root of each cluster with every module that has a
#                stage.yaml, and every stage of those roots, render with
#                flux build kustomization --dry-run --strict-substitute; a
#                stage reads the variables of cluster-vars
#   schemas      the JSON schemas of the sources in scripts/crd-sources.yaml
#                are downloaded, or converted from CRDs of the tree or of a
#                downloaded YAML stream
#   kubeconform  the renders, the roots and flux/ are valid for Kubernetes
#                $KUBERNETES_VERSION and those schemas, with no unknown field
#                and no unknown kind. A CustomResourceDefinition is skipped:
#                the schemas of Kubernetes hold none for its kind
#   patches      each patch of a stage, and of a kustomization of the tree
#                outside vendor/ that a stage reaches, changes the render of
#                at least one stage
#
# Every check runs even after an earlier one failed, except that a failed
# tools or vendor check ends the run. Each failure prints
# "validate: error: <check>: <message>" on stderr. The last line says that
# all checks passed (exit 0) or which failed (exit 1); a usage error exits 2.
# Helm charts are not templated: a HelmRelease is checked as an object. The
# render reads the https:// resources of a kustomization, so it needs the
# network as Flux does.
#
# Environment:
#   SANDBOX_VALIDATE_CACHE  the tools of scripts/install-validate-tools.sh
#                           and the downloaded schemas, by default
#                           ${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-validate
#   SANDBOX_CRD_SOURCES     another file of schema sources
#   SANDBOX_CONFIG          the configuration, by default config.yaml of the
#                           directory
#
# scripts/crd-sources.yaml and scripts/lib/crd-schema.jq are read from the
# repository that holds this script, never from the directory. The model is
# scripts/validate.sh of C5C3/playground.
set -euo pipefail
shopt -s nullglob

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SANDBOX_ROOT/scripts/lib/profile.sh"
# shellcheck source=lib/hub.sh
. "$SANDBOX_ROOT/scripts/lib/hub.sh"
# shellcheck source=lib/vendor.sh
. "$SANDBOX_ROOT/scripts/lib/vendor.sh"

# The files under kind/ pin no node image, so the clusters run the default of
# kind, kindest/node:v1.37.0 for kind v0.33.0.
readonly KUBERNETES_VERSION=1.37.0
readonly CHECKS=(tools vendor render schemas kubeconform patches)
readonly DEAD_PATCH="its target matches no resource, or the resource already has what the patch sets"
# A stage's name becomes part of a file name.
readonly NAME_RE='^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$'

usage() {
	echo "usage: scripts/validate.sh [<directory>]" >&2
	exit 2
}

[ "$#" -le 1 ] || usage
dir=${1:-$SANDBOX_ROOT}
[ -d "$dir" ] || usage
dir=$(cd -- "$dir" && pwd -P)
script_root=$SANDBOX_ROOT
cache=${SANDBOX_VALIDATE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-validate}
SANDBOX_VENDOR_DIR=$dir/vendor/cobaltcore
export SANDBOX_CONFIG=${SANDBOX_CONFIG:-$dir/config.yaml}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
tree=$tmp/tree

# fail <message>: reports a failure of the running check.
fail() {
	printf 'validate: error: %s: %s\n' "$check" "$*" >&2
	check_failed=1
}

# flux_build <name> <path> <kustomization file> <output>: renders the Flux
# Kustomization in the file from the path, offline, into the output. On a
# failure it sets build_error to the last line of flux's error output.
flux_build() {
	if KUBECONFIG=/dev/null flux build kustomization "$1" -n flux-system --path "$2" \
		--kustomization-file "$3" --dry-run --strict-substitute </dev/null >"$4" 2>"$tmp/err"; then
		return 0
	fi
	build_error=$(_last_line "$(<"$tmp/err")")
	build_error=${build_error#✗ }
	return 1
}

check_tools() {
	local tool
	PATH=$cache/bin:$PATH
	for tool in flux kubeconform yq jq git curl tar; do
		command -v "$tool" >/dev/null || fail "$tool not found in PATH; run scripts/install-validate-tools.sh"
	done
}

check_vendor() {
	local out commit
	# A failing config_load exits; the subshell keeps its message.
	if ! out=$(config_load 2>&1); then
		fail "${out#error: }"
		return
	fi
	config_load
	if ! commit=$(vendor_commit); then
		fail "vendor/cobaltcore not found; run make vendor"
		return
	fi
	if [ "$commit" != "$SANDBOX_UPSTREAM_COMMIT" ]; then
		fail "vendor/cobaltcore is at $commit, the configuration pins $SANDBOX_UPSTREAM_COMMIT; run make vendor"
		return
	fi
	if vendor_modified; then
		log "vendor: vendor/cobaltcore has local changes"
	fi

	if ! flux build artifact --path "$dir" --ignore-paths "$SANDBOX_ARTIFACT_IGNORE" \
		--output "$tmp/artifact.tgz" >/dev/null 2>"$tmp/err"; then
		out=$(_last_line "$(<"$tmp/err")")
		fail "cannot pack $dir: ${out#✗ }"
		return
	fi
	mkdir -- "$tree"
	if ! tar -xzf "$tmp/artifact.tgz" -C "$tree" 2>"$tmp/err"; then
		fail "cannot unpack the artifact of $dir: $(_last_line "$(<"$tmp/err")")"
		return
	fi
	tree=$(realpath -- "$tree")
	# profile_load, root_manifest and cluster_vars read the snapshot.
	SANDBOX_ROOT=$tree
}

# render_stage <role> <file>: renders the stage in the file, a document of
# the render of the root of the role, into $tmp/render/<role>/<name>.yaml and
# records it in the stage_* arrays for the patch check.
render_stage() {
	local role=$1 doc=$2 name path resolved kind ref optional copy out vars=$tmp/novars.json ok=true
	name=$(yq '.metadata.name' "$doc")
	if [[ ! $name =~ $NAME_RE ]]; then
		fail "stage $name: the name is not a Kubernetes name"
		return
	fi
	path=$(yq '.spec.path // ""' "$doc")
	resolved=$(realpath -m -- "$tree/$path")
	case $resolved in
	"$tree" | "$tree"/*) ;;
	*) resolved='' ;;
	esac
	if [ -z "$resolved" ] || [ ! -d "$resolved" ]; then
		fail "stage $name: path $path does not exist in the tree"
		return
	fi

	copy=$tmp/stages/$name.yaml
	if [ "$(yq '.spec | has("postBuild")' "$doc")" = true ]; then
		while IFS=$'\t' read -r kind ref optional; do
			if [ "$kind" = ConfigMap ] && [ "$ref" = cluster-vars ]; then
				vars=$tmp/vars.json
			elif [ "$optional" != true ]; then
				fail "stage $name: substituteFrom $kind $ref cannot be resolved offline"
				ok=false
			fi
		done < <(yq '.spec.postBuild.substituteFrom // [] | .[] | [.kind // "", .name // "", (.optional // false)] | @tsv' "$doc")
		$ok || return 0
		# The stage's own values win over those of cluster-vars, as in Flux.
		VARS=$vars yq '.spec.postBuild = {"substitute": (load(strenv(VARS)) * (.spec.postBuild.substitute // {}))}' \
			"$doc" >"$copy"
	else
		# Without postBuild, Flux substitutes nothing, and ${...} in vendored
		# text stays as it is.
		cp -- "$doc" "$copy"
	fi

	out=$tmp/render/$role/$name.yaml
	if ! flux_build "$name" "$resolved" "$copy" "$out"; then
		rm -f -- "$out"
		fail "stage $name: $build_error"
		return
	fi
	stage_names+=("$name") stage_copies+=("$copy") stage_paths+=("$resolved") stage_outs+=("$out")
}

check_render() {
	local role module out root names name roots=0
	local -a modules
	mkdir -p -- "$tmp/profiles" "$tmp/roots" "$tmp/stages"
	echo '{}' >"$tmp/novars.json"

	# The profile all lists every module of the tree.
	{
		(IFS=,; echo "clusters: [${SANDBOX_ROLES[*]}]")
		echo 'modules:'
		for role in "${SANDBOX_ROLES[@]}"; do
			modules=()
			for module in "$tree/clusters/$role"/*/stage.yaml; do
				module=${module%/stage.yaml}
				modules+=("${module##*/}")
			done
			names=$(printf '%s\n' "${modules[@]}" | LC_ALL=C sort | paste -sd ',' | sed 's/,/, /g')
			printf '  %s: [%s]\n' "$role" "$names"
		done
	} >"$tmp/profiles/all.yaml"
	export SANDBOX_PROFILE_DIR=$tmp/profiles SANDBOX_PROFILE=all
	unset SANDBOX_PROFILE_FILE
	if ! out=$(profile_load 2>&1); then
		fail "${out#error: }"
		log "render: 0 roots and 0 stages rendered"
		return
	fi
	profile_load

	if ! out=$(cluster_vars 2>"$tmp/err"); then
		out=$(_last_line "$(<"$tmp/err")")
		fail "${out#error: }"
		log "render: 0 roots and 0 stages rendered"
		return
	fi
	jq '.data' <<<"$out" >"$tmp/vars.json"

	for role in "${SANDBOX_ROLES[@]}"; do
		mkdir -p -- "$tmp/render/$role" "$tmp/docs/$role"
		root=$tmp/roots/cluster-$role.yaml
		root_manifest "$role" >"$root"
		out=$tmp/render/$role/cluster-$role.yaml
		if ! flux_build "cluster-$role" "$tree/clusters/$role" "$root" "$out"; then
			rm -f -- "$out"
			fail "root cluster-$role: $build_error"
			continue
		fi
		roots=$((roots + 1))
		# One file per stage of the root, in the order of the render.
		(cd "$tmp/docs/$role" && yq -s '"stage-" + ($index | tostring)' \
			'select((.apiVersion // "" | test("^kustomize\.toolkit\.fluxcd\.io/")) and .kind == "Kustomization")' "$out")
		for name in "$tmp/docs/$role"/stage-*.yml; do
			render_stage "$role" "$name"
		done
	done
	log "render: $roots roots and ${#stage_names[@]} stages rendered"
}

check_schemas() {
	local sources=${SANDBOX_CRD_SOURCES:-$script_root/scripts/crd-sources.yaml} count i name url path crds file
	local archive used=0 n
	local -a files
	mkdir -p -- "$tmp/schemas/archives" "$tmp/schemas/crds" "$cache/sources"
	if ! count=$(yq '.sources // [] | length' "$sources" 2>"$tmp/err"); then
		fail "$sources: $(_first_line "$(<"$tmp/err")")"
		return
	fi
	if [ "$count" -eq 0 ]; then
		fail "no source in $sources"
		return
	fi
	for ((i = 0; i < count; i++)); do
		name=$(I=$i yq '.sources[env(I)].name // ""' "$sources")
		if [ "$(I=$i yq '.sources[env(I)] | [has("schemas"), has("path"), has("crds")] | map(select(.)) | length' "$sources")" != 1 ]; then
			fail "$name: needs exactly one of schemas, path and crds"
			continue
		fi
		url=$(I=$i yq '.sources[env(I)].schemas // ""' "$sources")
		path=$(I=$i yq '.sources[env(I)].path // ""' "$sources")
		crds=$(I=$i yq '.sources[env(I)].crds // ""' "$sources")
		if [ -n "$crds" ]; then
			if [[ $crds != https://* ]]; then
				fail "$name: $crds is not an https:// URL"
				continue
			fi
			file=$cache/sources/$(printf '%s' "$crds" | sha256sum | cut -d ' ' -f 1).yaml
			if [ ! -f "$file" ]; then
				if ! curl -fsSL --retry 3 -o "$tmp/download" "$crds" 2>"$tmp/err"; then
					fail "$name: cannot download $crds: $(_last_line "$(<"$tmp/err")")"
					continue
				fi
				mv -- "$tmp/download" "$file"
			fi
			# A file that converts to nothing is downloaded again next time.
			if ! convert_crds "$name" "$crds" "$file"; then
				rm -f -- "$file"
				continue
			fi
			if [ ! -s "$tmp/crd.out" ]; then
				rm -f -- "$file"
				fail "$name: $crds holds no CustomResourceDefinition"
				continue
			fi
		elif [ -n "$url" ]; then
			if [[ $url != https://* ]]; then
				fail "$name: $url is not an https:// URL"
				continue
			fi
			archive=$cache/sources/$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1).tar.gz
			if [ ! -f "$archive" ]; then
				if ! curl -fsSL --retry 3 -o "$tmp/download" "$url" 2>"$tmp/err"; then
					fail "$name: cannot download $url: $(_last_line "$(<"$tmp/err")")"
					continue
				fi
				mv -- "$tmp/download" "$archive"
			fi
			if ! tar -xzf "$archive" -C "$tmp/schemas/archives" 2>"$tmp/err"; then
				rm -f -- "$archive"
				fail "$name: cannot unpack $url: $(_last_line "$(<"$tmp/err")")"
				continue
			fi
		else
			files=()
			# The glob is not quoted: it expands in the tree.
			for file in "$tree"/$path; do
				if [ -f "$file" ]; then
					files+=("$file")
				fi
			done
			if [ "${#files[@]}" -eq 0 ]; then
				fail "$name: $path matches no file"
				continue
			fi
			for file in "${files[@]}"; do
				convert_crds "$name" "${file#"$tree"/}" "$file" || continue
			done
		fi
		used=$((used + 1))
	done
	n=$(find "$tmp/schemas" -type f -name '*.json' | wc -l)
	log "schemas: $n schemas from $used sources"
}

# convert_crds <name> <label> <file>: converts the CustomResourceDefinitions
# of the YAML file into JSON schemas in $tmp/schemas/crds, and leaves the
# output of scripts/lib/crd-schema.jq, one line per schema, in $tmp/crd.out.
# A failure names the source and the label of the file, and returns 1 when
# the file cannot be read.
convert_crds() {
	local line schema
	if ! yq -o=json -I=0 '.' "$3" >"$tmp/crd.json" 2>"$tmp/err" ||
		! jq -c -f "$script_root/scripts/lib/crd-schema.jq" "$tmp/crd.json" >"$tmp/crd.out" 2>"$tmp/err"; then
		fail "$1: $2: $(_first_line "$(<"$tmp/err")")"
		return 1
	fi
	while IFS= read -r line; do
		schema=$(jq -r '.file' <<<"$line")
		if [[ $schema == */* ]]; then
			fail "$1: $2: $schema is not a file name"
			continue
		fi
		jq '.schema' <<<"$line" >"$tmp/schemas/crds/$schema"
	done <"$tmp/crd.out"
}

check_kubeconform() {
	local status=0 summary
	local -a inputs=("$tmp/render" "$tmp/roots")
	if [ -d "$tree/flux" ]; then
		inputs+=("$tree/flux")
	fi
	mkdir -p -- "$cache/kubeconform" "$tmp/render" "$tmp/roots"
	# kubeconform tries the locations in order. The local ones come first, so
	# the kinds of Flux and of the CRDs cost no request to GitHub.
	kubeconform -strict -summary -skip CustomResourceDefinition -kubernetes-version "$KUBERNETES_VERSION" -cache "$cache/kubeconform" \
		-schema-location "$tmp/schemas/archives/{{.ResourceKind}}{{.KindSuffix}}.json" \
		-schema-location "$tmp/schemas/crds/{{.Group}}_{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
		-schema-location default \
		"${inputs[@]}" >"$tmp/kubeconform.out" 2>&1 || status=$?
	cat -- "$tmp/kubeconform.out"
	if [ "$status" -ne 0 ]; then
		summary=$(grep -m 1 '^Summary:' "$tmp/kubeconform.out") || summary=$(_last_line "$(<"$tmp/kubeconform.out")")
		fail "$summary"
	fi
}

# reach <directory>: records in reached the kustomization.yaml of the
# directory and, recursively, of every local directory its resources and
# components name, inside the tree and outside vendor/.
reach() {
	local file=$1/kustomization.yaml entry target
	[ -f "$file" ] && [ -z "${reached[$file]:-}" ] || return 0
	reached[$file]=1
	while IFS= read -r entry; do
		target=$(realpath -m -- "$1/$entry")
		case $target in
		"$tree/vendor" | "$tree/vendor"/*) ;;
		"$tree"/*) if [ -d "$target" ]; then reach "$target"; fi ;;
		esac
	done < <(yq '(.resources // []) + (.components // []) | .[]' "$file")
}

check_patches() {
	local name copy file rel field count i idx changed checked=0
	local -a files=()
	local -A reached readers=()

	for idx in "${!stage_names[@]}"; do
		name=${stage_names[idx]} copy=${stage_copies[idx]}
		count=$(yq '.spec.patches // [] | length' "$copy")
		for ((i = 0; i < count; i++)); do
			checked=$((checked + 1))
			I=$i yq 'del(.spec.patches[env(I)])' "$copy" >"$tmp/without.yaml"
			if flux_build "$name" "${stage_paths[idx]}" "$tmp/without.yaml" "$tmp/without.out" &&
				cmp -s -- "${stage_outs[idx]}" "$tmp/without.out"; then
				fail "stage $name: spec.patches[$i] changes nothing: $DEAD_PATCH"
			fi
		done

		reached=()
		case ${stage_paths[idx]} in
		"$tree/vendor" | "$tree/vendor"/*) ;;
		*) reach "${stage_paths[idx]}" ;;
		esac
		for file in "${!reached[@]}"; do
			readers[$file]+="$idx "
		done
	done

	mapfile -t files < <(printf '%s\n' "${!readers[@]}" | LC_ALL=C sort)
	for file in "${files[@]}"; do
		[ -n "$file" ] || continue
		rel=${file#"$tree"/}
		for field in patchesStrategicMerge patchesJson6902; do
			if [ "$(F=$field yq 'has(strenv(F))' "$file")" = true ]; then
				fail "$rel: $field is not checked; use patches"
			fi
		done
		count=$(yq '.patches // [] | length' "$file")
		for ((i = 0; i < count; i++)); do
			checked=$((checked + 1))
			cp -- "$file" "$tmp/kustomization.orig"
			I=$i yq -i 'del(.patches[env(I)])' "$file"
			changed=false
			for idx in ${readers[$file]}; do
				# A render that fails without the patch counts as a change.
				if ! flux_build "${stage_names[idx]}" "${stage_paths[idx]}" "${stage_copies[idx]}" "$tmp/without.out" ||
					! cmp -s -- "${stage_outs[idx]}" "$tmp/without.out"; then
					changed=true
					break
				fi
			done
			mv -f -- "$tmp/kustomization.orig" "$file"
			if ! $changed; then
				fail "$rel: patches[$i] changes nothing in any stage: $DEAD_PATCH"
			fi
		done
	done
	log "patches: $checked patches checked"
}

stage_names=() stage_copies=() stage_paths=() stage_outs=()
failed=()
for check in "${CHECKS[@]}"; do
	check_failed=0
	"check_$check"
	if [ "$check_failed" -ne 0 ]; then
		failed+=("$check")
		# Without the tools or the snapshot no other check can run.
		case $check in
		tools | vendor) break ;;
		esac
	fi
done

if [ "${#failed[@]}" -eq 0 ]; then
	log "all checks passed"
	exit 0
fi
log "failed: ${failed[*]}"
exit 1
