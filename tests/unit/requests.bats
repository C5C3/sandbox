#!/usr/bin/env bats
# scripts/lib/requests.jq: the memory requests of a pod list in bytes.

setup() {
	load helpers
}

# requests_of <pod list>: runs requests.jq on the JSON.
requests_of() {
	run jq -f "$SANDBOX_ROOT/scripts/lib/requests.jq" <<<"$1"
}

# container <memory>: prints a container that requests the memory.
container() {
	printf '{"name": "c", "resources": {"requests": {"memory": "%s"}}}' "$1"
}

# pod <namespace/name> <phase> <containers> [<init containers>]: prints a pod.
pod() {
	printf '{"metadata": {"namespace": "%s", "name": "%s"}, "status": {"phase": "%s"}, "spec": {"containers": [%s], "initContainers": [%s]}}' \
		"${1%/*}" "${1#*/}" "$2" "$3" "${4:-}"
}

@test "an empty or null pod list requests 0 bytes" {
	requests_of '{"items": []}'
	[ "$status" -eq 0 ]
	[ "$output" = 0 ]

	requests_of '{"items": null}'
	[ "$status" -eq 0 ]
	[ "$output" = 0 ]
}

@test "a container without resources requests 0 bytes" {
	requests_of "{\"items\": [$(pod default/a Running '{"name": "c"}')]}"
	[ "$status" -eq 0 ]
	[ "$output" = 0 ]
}

@test "128Mi are 134217728 bytes" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 128Mi)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = 134217728 ]
}

@test "the containers of a pod are summed across binary, decimal and plain quantities" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 1Gi), $(container 500M), $(container 1000k), $(container 1048576)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = $((1073741824 + 500000000 + 1000000 + 1048576)) ]
}

@test "every binary and decimal suffix up to Pi and P is converted" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 1Ki), $(container 1Ti), $(container 1Pi), $(container 1G), $(container 1T), $(container 1P)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = $((1024 + 1099511627776 + 1125899906842624 + 1000000000 + 1000000000000 + 1000000000000000)) ]
}

@test "a quantity with a decimal exponent is converted" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 1e9), $(container 129e6), $(container 1E6)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = $((1000000000 + 129000000 + 1000000)) ]
}

@test "the sum is rounded down" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 1Gi), $(container 500m)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = 1073741824 ]
}

@test "finished pods are left out and pending pods are counted" {
	requests_of "{\"items\": [
		$(pod default/done Succeeded "$(container 1Mi)"),
		$(pod default/crashed Failed "$(container 2Mi)"),
		$(pod default/waiting Pending "$(container 4Mi)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = 4194304 ]
}

@test "an init container counts only with restartPolicy Always" {
	sidecar='{"name": "s", "restartPolicy": "Always", "resources": {"requests": {"memory": "1Mi"}}}'
	requests_of "{\"items\": [$(pod default/a Running "$(container 4Mi)" "$sidecar, $(container 2Mi)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = 5242880 ]
}

@test "a sum above 2^53 - 1 bytes stops the program" {
	for containers in "$(container 8Ei)" "$(container 10E)" "$(container 1e19)" "$(container 4Pi), $(container 4Pi)"; do
		requests_of "{\"items\": [$(pod default/a Running "$containers")]}"
		[ "$status" -ne 0 ]
		[[ $output == *"bytes are too large to sum"* ]]
	done
}

@test "a sum of 2^53 - 1 bytes is printed in full" {
	requests_of "{\"items\": [$(pod default/a Running "$(container 9007199254740991)")]}"
	[ "$status" -eq 0 ]
	[ "$output" = 9007199254740991 ]
}

@test "an unsupported quantity stops the program and names the pod" {
	requests_of "{\"items\": [$(pod default/bad Running "$(container 12Xi)")]}"
	[ "$status" -ne 0 ]
	[[ $output == *"unsupported memory quantity 12Xi in pod default/bad"* ]]
}
