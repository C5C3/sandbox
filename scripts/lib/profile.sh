# shellcheck shell=bash
# The profiles of the sandbox. Source scripts/lib/common.sh first.
#
# A profile is the file profiles/<name>.yaml with three keys. clusters lists
# roles. modules maps a role to the list of its modules, in any order, because
# the dependsOn of their stages orders them. The optional switches maps a key
# of switches in the configuration to a value, which config_merged applies.

# profile_load: reads the profile that SANDBOX_PROFILE names, scaffold when it
# is unset or empty, from SANDBOX_PROFILE_DIR, by default profiles/ in the
# repository root, and checks the whole file. It exports SANDBOX_PROFILE,
# SANDBOX_PROFILE_FILE and SANDBOX_PROFILE_CLUSTERS, the listed roles in the
# order of SANDBOX_ROLES, each once, separated by spaces.
profile_load() {
	local name=${SANDBOX_PROFILE:-scaffold} path out word role module dep listed=' ' stages=' '
	local -a words=() pairs=()

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
			[[ $stages != *" $role-$module "* ]] ||
				die "profile $name: modules.$role lists '$module' twice"
			pairs+=("$role/$module")
			stages+="$role-$module "
		done < <(ROLE=$role yq '(.modules[strenv(ROLE)] // []) | .[]' "$path")
	done

	# Each check runs over every module before the next one, so the message
	# is the first that applies to the file.
	for word in "${pairs[@]}"; do
		[[ ${word#*/} =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "profile $name: '${word#*/}' is not a module name"
	done
	for word in "${pairs[@]}"; do
		[ -f "$SANDBOX_ROOT/clusters/$word/stage.yaml" ] ||
			die "profile $name: module $word does not exist, expected clusters/$word/stage.yaml"
	done
	for word in "${pairs[@]}"; do
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

# cluster_modules <role>: prints the modules whose stages the role's cluster
# runs: those of profile_modules and then resolver, when
# SANDBOX_RESOLVER_FALLBACK is true and the profile does not list it. When
# profile_modules fails, it prints nothing and returns its status.
cluster_modules() {
	local modules
	modules=$(profile_modules "$1") || return
	if [ -n "$modules" ]; then
		printf '%s\n' "$modules"
	fi
	if [ "${SANDBOX_RESOLVER_FALLBACK:-false}" = true ] && ! grep -qxF resolver <<<"$modules"; then
		echo resolver
	fi
}
