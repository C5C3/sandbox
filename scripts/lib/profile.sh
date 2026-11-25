# shellcheck shell=bash
# The profiles of the sandbox. Source scripts/lib/common.sh first.
#
# A profile is the file profiles/<name>.yaml with three keys. clusters lists
# roles. modules maps a role to the list of its modules, in any order, because
# the dependsOn of their stages orders them. The optional switches maps a key
# of switches in the configuration to a value, which config_merged applies.
#
# A module is the directory clusters/<role>/<module>/ in one of two shapes. A
# module with a stage holds stage.yaml and kustomization.yaml, and may hold
# patches/kustomization.yaml. A module without a stage holds
# patches/kustomization.yaml alone, a Component whose patches change the
# stages of other modules; it has no dependsOn.

# profile_load: reads the profile that SANDBOX_PROFILE names, scaffold when it
# is unset or empty, from SANDBOX_PROFILE_DIR, by default profiles/ in the
# repository root, and checks the whole file: every listed module exists in
# either shape, and the dependsOn of every stage names a stage of a listed
# module. It exports SANDBOX_PROFILE, SANDBOX_PROFILE_FILE and
# SANDBOX_PROFILE_CLUSTERS, the listed roles in the order of SANDBOX_ROLES,
# each once, separated by spaces.
profile_load() {
	local name=${SANDBOX_PROFILE:-scaffold} path out word role module dep listed=' ' seen=' ' stages=' '
	local -a words=() pairs=() staged=()

	# The name becomes part of a path, so it is checked before any file is read.
	[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "profile: '$name' is not a profile name"
	path=${SANDBOX_PROFILE_DIR:-$SANDBOX_ROOT/profiles}/$name.yaml
	[ -f "$path" ] || die "profile: $path not found"
	if ! out=$(yq '.' "$path" 2>&1); then
		out=${out%%$'\n'*}
		die "profile: $path: ${out#Error: }"
	fi

	mapfile -t words < <(yq '.clusters | select(tag == "!!seq") | .[]' "$path")
	[ "${#words[@]}" -gt 0 ] || die "profile $name: clusters is not set"
	for word in "${words[@]}"; do
		case $word in
		management | storage | compute) listed+="$word " ;;
		*) die "profile $name: unknown cluster '$word', expected management, storage or compute" ;;
		esac
	done
	[[ $listed == *" management "* ]] || die "profile $name: clusters must list management, Flux runs there"

	case $(yq '.modules | tag' "$path") in
	'!!map' | '!!null') ;;
	*) die "profile $name: modules must be a map" ;;
	esac
	case $(yq '.switches | tag' "$path") in
	'!!map' | '!!null') ;;
	*) die "profile $name: switches must be a map" ;;
	esac

	mapfile -t words < <(yq '.modules // {} | keys | .[]' "$path")
	for word in "${words[@]}"; do
		[[ $listed == *" $word "* ]] ||
			die "profile $name: modules names the cluster '$word', which clusters does not list"
	done
	for role in "${words[@]}"; do
		case $(ROLE=$role yq '.modules[strenv(ROLE)] | tag' "$path") in
		'!!seq' | '!!null') ;;
		*) die "profile $name: modules.$role must be a list" ;;
		esac
		while IFS= read -r module; do
			[[ $seen != *" $role-$module "* ]] ||
				die "profile $name: modules.$role lists '$module' twice"
			pairs+=("$role/$module")
			seen+="$role-$module "
		done < <(ROLE=$role yq '(.modules[strenv(ROLE)] // []) | .[]' "$path")
	done

	# Each check runs over every module before the next one, so the message
	# is the first that applies to the file.
	for word in "${pairs[@]}"; do
		[[ ${word#*/} =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "profile $name: '${word#*/}' is not a module name"
	done
	for word in "${pairs[@]}"; do
		if module_has_stage "${word%%/*}" "${word#*/}"; then
			staged+=("$word")
			stages+="${word%%/*}-${word#*/} "
		elif [ ! -f "$SANDBOX_ROOT/clusters/$word/patches/kustomization.yaml" ]; then
			die "profile $name: module $word does not exist, expected clusters/$word/stage.yaml or clusters/$word/patches/kustomization.yaml"
		fi
	done
	# Only a module with a stage has a dependsOn, and only its stage can be
	# named in one.
	for word in "${staged[@]}"; do
		if ! out=$(yq '.spec.dependsOn // [] | .[].name' "$SANDBOX_ROOT/clusters/$word/stage.yaml" 2>&1); then
			out=${out%%$'\n'*}
			die "profile $name: clusters/$word/stage.yaml: ${out#Error: }"
		fi
		for dep in $out; do
			[[ $stages == *" $dep "* ]] ||
				die "profile $name: $word depends on the stage $dep, which the profile does not list"
		done
	done

	SANDBOX_PROFILE_CLUSTERS=''
	for role in "${SANDBOX_ROLES[@]}"; do
		if [[ $listed == *" $role "* ]]; then
			SANDBOX_PROFILE_CLUSTERS+=${SANDBOX_PROFILE_CLUSTERS:+ }$role
		fi
	done
	export SANDBOX_PROFILE=$name SANDBOX_PROFILE_FILE=$path SANDBOX_PROFILE_CLUSTERS
}

# profile_modules <role>: prints the modules the loaded profile lists for the
# role, one per line, in the order of the file. It prints nothing for a role
# without an entry under modules or with an empty list.
profile_modules() {
	ROLE=$1 yq '(.modules[strenv(ROLE)] // []) | .[]' "$SANDBOX_PROFILE_FILE"
}

# cluster_modules <role>: prints the modules the role's cluster runs, one per
# line: those of profile_modules; for management then glance, barbican,
# horizon and fake-compute, in this order, each when its variable
# SANDBOX_SWITCH_GLANCE, SANDBOX_SWITCH_BARBICAN, SANDBOX_SWITCH_HORIZON or
# SANDBOX_SWITCH_FAKE_COMPUTE is true and the profile does not list it; and
# last resolver, when SANDBOX_RESOLVER_FALLBACK is true and the profile does
# not list it. An unset variable counts as false. When profile_modules fails,
# it prints nothing and returns its status.
cluster_modules() {
	local modules switch variable
	modules=$(profile_modules "$1") || return
	if [ -n "$modules" ]; then
		printf '%s\n' "$modules"
	fi
	if [ "$1" = management ]; then
		for switch in glance barbican horizon fake-compute; do
			variable=SANDBOX_SWITCH_${switch^^}
			variable=${variable//-/_}
			if [ "${!variable:-false}" = true ] && ! grep -qxF "$switch" <<<"$modules"; then
				printf '%s\n' "$switch"
			fi
		done
	fi
	if [ "${SANDBOX_RESOLVER_FALLBACK:-false}" = true ] && ! grep -qxF resolver <<<"$modules"; then
		echo resolver
	fi
}

# module_has_stage <role> <module>: succeeds when the module has a stage,
# that is when clusters/<role>/<module>/stage.yaml exists.
module_has_stage() {
	[ -f "$SANDBOX_ROOT/clusters/$1/$2/stage.yaml" ]
}

# cluster_stages <role>: prints the modules of cluster_modules that have a
# stage, one per line, in the same order. It prints nothing for a role
# without modules. When cluster_modules fails, it prints nothing and returns
# its status.
cluster_stages() {
	local modules module
	modules=$(cluster_modules "$1") || return
	for module in $modules; do
		if module_has_stage "$1" "$module"; then
			printf '%s\n' "$module"
		fi
	done
}
