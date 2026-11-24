# shellcheck shell=bash
# The host check of the sandbox. Source scripts/lib/common.sh first.
#
# Each probe_* function runs one command and holds no logic. They are the
# seam the unit tests replace to simulate a host.

probe_os() {
	printf '%s %s\n' "$(uname -s)" "$(uname -m)"
}

probe_cgroup_fstype() {
	stat -fc %T /sys/fs/cgroup
}

probe_docker_security() {
	docker info --format '{{json .SecurityOptions}}'
}

probe_inotify_instances() {
	cat /proc/sys/fs/inotify/max_user_instances
}

# probe_tool <name>: fails when the tool is not in PATH, otherwise prints the
# first line of its version output.
probe_tool() {
	local out
	command -v "$1" >/dev/null || return 1
	case $1 in
	kind) out=$(kind version 2>&1) ;;
	kubectl) out=$(kubectl version --client 2>&1) ;;
	helm) out=$(helm version --short 2>&1) ;;
	*) out=$("$1" --version 2>&1) ;;
	esac
	printf '%s\n' "${out%%$'\n'*}"
}

probe_openstack_plugin() {
	case $1 in
	osc-placement) openstack help resource provider list ;;
	python-barbicanclient) openstack help secret list ;;
	*) return 1 ;;
	esac >/dev/null 2>&1
}

probe_module() {
	[ -d "/sys/module/$1" ] || modinfo -n "$1" >/dev/null 2>&1
}

probe_kvm() {
	[ -c /dev/kvm ]
}

# probe_resolve <name>: prints the first IPv4 address of the name, or nothing.
probe_resolve() {
	local out
	# A failed lookup prints nothing; preflight_run reports the empty answer.
	out=$(timeout 5 getent ahostsv4 "$1") || true
	out=${out%%$'\n'*}
	printf '%s\n' "${out%%[[:space:]]*}"
}

# _preflight_report <ok|warn|FAIL> <id> <detail>: prints one line of the host
# check and counts it in the variables failed and warned of preflight_run.
_preflight_report() {
	printf '%s %s: %s\n' "$1" "$2" "$3"
	case $1 in
	FAIL) failed=$((failed + 1)) ;;
	warn) warned=$((warned + 1)) ;;
	esac
}

# preflight_run [<role>...]: runs every check that applies to the roles, or
# only the checks of every role when none is given. It never stops at a
# failure, prints one line per check and a summary, and returns 1 when a
# check failed.
preflight_run() {
	local failed=0 warned=0 storage=false compute=false
	local yq_ok=false openstack_ok=false config_ok=false
	local yq_min=4.40.1 inotify_min=512
	local role out name lowest
	local -a modules=()

	for role in "$@"; do
		case $role in
		storage) storage=true ;;
		compute) compute=true ;;
		esac
	done

	out=$(probe_os) || true
	if [ "$out" = "Linux x86_64" ]; then
		_preflight_report ok os "$out"
	else
		_preflight_report FAIL os "Linux on x86_64 required, found $out"
	fi

	out=$(probe_cgroup_fstype) || true
	if [ "$out" = cgroup2fs ]; then
		_preflight_report ok cgroup "$out"
	else
		_preflight_report FAIL cgroup "cgroup v2 required, /sys/fs/cgroup is $out"
	fi

	if out=$(probe_docker_security 2>/dev/null); then
		if [[ $out == *rootless* ]]; then
			_preflight_report FAIL docker "rootful Docker required, the daemon runs rootless"
		else
			_preflight_report ok docker "$out"
		fi
	else
		# The output of a failed call can hold a placeholder on stdout, so
		# the detail is read from stderr alone.
		out=$(probe_docker_security 2>&1 >/dev/null) || true
		_preflight_report FAIL docker "cannot reach the Docker daemon: ${out%%$'\n'*}"
	fi

	if ! out=$(probe_inotify_instances) || ! [[ $out =~ ^[0-9]+$ ]]; then
		_preflight_report FAIL inotify "cannot read fs.inotify.max_user_instances"
	elif [ "$out" -lt "$inotify_min" ]; then
		_preflight_report FAIL inotify "fs.inotify.max_user_instances is $out, $inotify_min or more required (sudo sysctl fs.inotify.max_user_instances=$inotify_min)"
	else
		_preflight_report ok inotify "$out"
	fi

	for name in docker kind kubectl jq helm flux git; do
		if out=$(probe_tool "$name"); then
			_preflight_report ok "tool $name" "$out"
		else
			_preflight_report FAIL "tool $name" "not found in PATH"
		fi
	done

	if ! out=$(probe_tool yq); then
		_preflight_report FAIL "tool yq" "not found in PATH"
	elif [[ $out == *mikefarah* && $out =~ [0-9]+\.[0-9]+\.[0-9]+ ]] &&
		lowest=$(printf '%s\n' "$yq_min" "${BASH_REMATCH[0]}" | sort -V) &&
		[ "${lowest%%$'\n'*}" = "$yq_min" ]; then
		yq_ok=true
		_preflight_report ok "tool yq" "$out"
	else
		_preflight_report FAIL "tool yq" "mikefarah yq v$yq_min or newer required, found $out"
	fi

	if out=$(probe_tool openstack); then
		openstack_ok=true
		_preflight_report ok "tool openstack" "$out"
	else
		_preflight_report warn "tool openstack" "not found in PATH"
	fi

	if $openstack_ok; then
		for name in osc-placement python-barbicanclient; do
			if probe_openstack_plugin "$name"; then
				_preflight_report ok "plugin $name" installed
			else
				_preflight_report warn "plugin $name" "OpenStack CLI plugin missing"
			fi
		done
	fi

	if ! $yq_ok; then
		_preflight_report FAIL config "not checked, yq is unusable"
	elif out=$(config_load 2>&1); then
		# The subshell above contains the die of a failing config_load; this
		# call sets the Gateway address for the resolver check.
		config_load
		config_ok=true
		_preflight_report ok config "${SANDBOX_CONFIG:-$SANDBOX_ROOT/config.yaml}"
	else
		_preflight_report FAIL config "${out#error: }"
	fi

	if $storage; then
		modules+=(loop)
	fi
	if $compute; then
		modules+=(openvswitch geneve vhost_net)
	fi
	for name in "${modules[@]}"; do
		if probe_module "$name"; then
			_preflight_report ok "module $name" available
		else
			_preflight_report FAIL "module $name" "neither loaded nor in the module tree of this kernel"
		fi
	done

	if $compute; then
		if probe_kvm; then
			_preflight_report ok kvm /dev/kvm
		else
			_preflight_report warn kvm "/dev/kvm is missing, the compute pool falls back to virtType qemu"
		fi
	fi

	if ! $config_ok; then
		_preflight_report warn resolver "not checked, the configuration is unusable"
	else
		name=preflight.${SANDBOX_GATEWAY_ADDRESS//./-}.nip.io
		out=$(probe_resolve "$name") || true
		if [ "$out" = "$SANDBOX_GATEWAY_ADDRESS" ]; then
			_preflight_report ok resolver "$name resolves to $out"
		else
			_preflight_report warn resolver "$name resolved to '$out', expected $SANDBOX_GATEWAY_ADDRESS; a resolver with DNS rebinding protection drops private answers"
		fi
	fi

	printf 'preflight: %d failed, %d warnings\n' "$failed" "$warned"
	[ "$failed" -eq 0 ]
}
