#!/usr/bin/env bats
# The profile gateway against a real Docker: the Gateway openstack-gw on
# addresses.gateway with a certificate of the sandbox CA, reached from the
# host and from a pod of each cluster, and the resolver fallback. It needs a
# host that passes the host check for all three roles, refuses to start while
# a sandbox exists and ends with make down.
#
# The tests run in file order, and each one starts from the state the one
# before left. The tests that rely on the host's resolver skip when the host
# check warns about it.

ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
KUBECONFIG_DIR=$ROOT/.sandbox/kubeconfig
ROLES=(management storage compute)
SERVICE_OPERATORS=(keystone horizon glance placement barbican ovn neutron cinder nova)
CURL_IMAGE=quay.io/curl/curl:8.23.0

sb_make() {
	make --no-print-directory -C "$ROOT" "$@"
}

# config_value <yq expression>: prints the value of config.yaml.
config_value() {
	yq "$1" "$ROOT/config.yaml"
}

# config_copy <yq expression>: prints the path of a copy of config.yaml that
# the expression changed.
config_copy() {
	local path=$BATS_FILE_TMPDIR/config-$BATS_TEST_NUMBER.yaml
	yq "$1" "$ROOT/config.yaml" >"$path"
	printf '%s\n' "$path"
}

# sandbox_exists: succeeds when any object of a sandbox exists on the host.
sandbox_exists() {
	docker network inspect cobaltcore-sandbox >/dev/null 2>&1 ||
		[ -n "$(docker ps -aq --filter label=cobaltcore-sandbox=true)" ] ||
		kind get clusters | grep -qxE 'sandbox-(management|storage|compute)' ||
		[ -e "$ROOT/.sandbox" ]
}

# eventually <seconds> <command>...: runs the command every 2 s until it
# succeeds, for at most the seconds given.
eventually() {
	local deadline=$((SECONDS + $1))
	shift
	until "$@"; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			return 1
		fi
		sleep 2
	done
}

# kc <role> <argument>...: runs kubectl against the role's cluster.
kc() {
	kubectl --kubeconfig "$KUBECONFIG_DIR/$1.yaml" "${@:2}"
}

# probe_host: prints the hostname of the probe route, probe.<a-b-c-d>.nip.io.
probe_host() {
	local address
	address=$(config_value .addresses.gateway)
	printf 'probe.%s.nip.io\n' "${address//./-}"
}

# probe_url: prints the URL of the probe route.
probe_url() {
	printf 'https://%s/\n' "$(probe_host)"
}

# corefile <role>: prints the Corefile of the ConfigMap kube-system/coredns.
corefile() {
	kc "$1" -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
}

# corefile_loaded <role>: the ConfigMap of CoreDNS holds the sandbox block and
# every CoreDNS pod has reloaded its Corefile.
corefile_loaded() {
	local pod
	[[ $(corefile "$1") == *"# sandbox: begin"* ]] || return 1
	for pod in $(kc "$1" -n kube-system get pods -l k8s-app=kube-dns -o name); do
		kc "$1" -n kube-system logs "$pod" | grep -q 'Reloading complete' || return 1
	done
}

# template_matches <role>: prints the number of A queries the template block
# of the role's CoreDNS answered, summed over its pods. A fetch can succeed
# through forward on a host whose resolver answers nip.io names; this counter
# shows that the block answered.
template_matches() {
	local pod sum=0 n
	for pod in $(kc "$1" -n kube-system get pods -l k8s-app=kube-dns -o name); do
		n=$(kc "$1" get --raw "/api/v1/namespaces/kube-system/pods/${pod#pod/}:9153/proxy/metrics" |
			awk '/^coredns_template_matches_total\{/ && /type="A"/ { s += $2 } END { print s + 0 }')
		sum=$((sum + n))
	done
	printf '%s\n' "$sum"
}

# skip_without_resolver: skips the test, with the line of the host check as
# the reason, when the host's resolver does not answer the nip.io name of the
# Gateway.
skip_without_resolver() {
	local line
	line=$("$ROOT/scripts/preflight.sh" management | grep '^warn resolver: ' || :)
	if [ -n "$line" ]; then
		skip "$line"
	fi
}

# pod_done <role>: the pod default/probe of the role's cluster has ended.
pod_done() {
	[[ $(kc "$1" -n default get pod probe -o jsonpath='{.status.phase}') =~ ^(Succeeded|Failed)$ ]]
}

# pod_fetch <role>: fetches the probe with the sandbox CA from a pod of the
# role's cluster, which reads the CA from a ConfigMap, and prints the HTTP
# status, or the error of curl.
pod_fetch() {
	kc "$1" -n default create configmap sandbox-ca --from-file=ca.crt="$BATS_FILE_TMPDIR/ca.crt" \
		--dry-run=client -o yaml | kc "$1" apply -f - >/dev/null
	kc "$1" -n default delete pod probe --ignore-not-found --wait >/dev/null
	kc "$1" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: $CURL_IMAGE
      command: [curl]
      args: [-sS, -o, /dev/null, -w, "%{http_code}", --cacert, /ca/ca.crt, "$(probe_url)"]
      volumeMounts:
        - name: ca
          mountPath: /ca
  volumes:
    - name: ca
      configMap:
        name: sandbox-ca
EOF
	eventually 180 pod_done "$1" || return 1
	kc "$1" -n default logs probe
}

# resolver_gone: the three resolver stages and the Service nip-io are gone.
resolver_gone() {
	! kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io \
		management-resolver storage-resolver compute-resolver -o name 2>/dev/null | grep -q . &&
		! kc management -n kube-system get service nip-io >/dev/null 2>&1
}

setup_file() {
	if sandbox_exists; then
		echo "a sandbox exists on this host; run make down first" >&2
		return 1
	fi
	touch "$BATS_FILE_TMPDIR/owned"
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/owned" ]; then
		sb_make down
	fi
}

@test "make up PROFILE=gateway brings five stages Ready on three clusters" {
	SANDBOX_STAGE_TIMEOUT=1800 run sb_make up PROFILE=gateway
	[ "$status" -eq 0 ]
	[[ ${lines[-4]} =~ ^up:\ 5\ stages\ Ready\ on\ 3\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[[ ${lines[-3]} == "export KUBECONFIG="* ]]
}

@test "exactly the nine service operators are suspended and run no pod, every other release is Ready" {
	local json operator name
	json=$(kc management get helmreleases.helm.toolkit.fluxcd.io -A -o json)
	[ "$(jq -r '[.items[] | select(.spec.suspend == true) | .metadata.name] | sort | join(" ")' <<<"$json")" = \
		"$(printf '%s-operator\n' "${SERVICE_OPERATORS[@]}" | sort | paste -sd ' ')" ]
	for operator in "${SERVICE_OPERATORS[@]}"; do
		[ -z "$(kc management -n "$operator-system" get pods -o name)" ]
	done
	[ "$(jq '[.items[] | select(.spec.suspend != true)] | length' <<<"$json")" -gt 0 ]
	[ "$(jq -r '[.items[] | select(.spec.suspend != true)
		| select(([.status.conditions[]? | select(.type == "Ready")][0].status) != "True")
		| .metadata.name] | join(" ")' <<<"$json")" = "" ]
	for name in k-orc rabbitmq-cluster-operator messaging-topology-operator; do
		[ "$(kc management -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io "$name" \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]
	done
}

@test "the address pool holds addresses.pool and gives a Service that does not ask none" {
	[ "$(kc management -n metallb-system get ipaddresspools.metallb.io sandbox -o jsonpath='{.spec.addresses[*]} {.spec.autoAssign}')" = \
		"$(config_value .addresses.pool) false" ]
	kc management -n default create service loadbalancer unasked --tcp=80:80 >/dev/null
	sleep 20
	[ "$(kc management -n default get service unasked -o jsonpath='{.status.loadBalancer.ingress}')" = "" ]
	kc management -n default delete service unasked >/dev/null
}

@test "the proxy of openstack-gw is a LoadBalancer Service on addresses.gateway, port 443" {
	run kc management -n envoy-gateway-system get services -l gateway.envoyproxy.io/owning-gateway-name=openstack-gw \
		-o jsonpath='{range .items[*]}{.spec.type} {.status.loadBalancer.ingress[*].ip} {.spec.ports[*].port}{"\n"}{end}'
	[ "$status" -eq 0 ]
	[ "$output" = "LoadBalancer $(config_value .addresses.gateway) 443" ]
}

@test "the sandbox CA is name-constrained to nip.io, the Gateway certificate covers *.<a-b-c-d>.nip.io" {
	local address
	address=$(config_value .addresses.gateway)
	[ "$(kc management -n cert-manager get certificate sandbox-ca \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.nameConstraints.critical} {.spec.nameConstraints.permitted.dnsDomains}')" = \
		'True true ["nip.io"]' ]
	[ "$(kc management -n openstack get certificate openstack-gw-tls \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.dnsNames}')" = \
		"True [\"*.${address//./-}.nip.io\"]" ]
	[ "$(kc management -n openstack get gateway openstack-gw -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')" = True ]
}

@test "the probe answers the host with the sandbox CA, and curl refuses it without" {
	kc management -n cert-manager get secret sandbox-ca -o jsonpath='{.data.tls\.crt}' | base64 -d >"$BATS_FILE_TMPDIR/ca.crt"
	PROBE_HOST=$(probe_host) yq '(select(.kind == "HTTPRoute") | .spec.hostnames) = [strenv(PROBE_HOST)]' \
		"$BATS_TEST_DIRNAME/fixtures/probe-route.yaml" | kc management apply -f - >/dev/null
	skip_without_resolver

	# The route is programmed a few seconds after it is applied; until then
	# Envoy answers 404.
	eventually 60 curl -fsS -o /dev/null --cacert "$BATS_FILE_TMPDIR/ca.crt" "$(probe_url)"
	run curl -sS -o "$BATS_FILE_TMPDIR/body" -w '%{http_code}' --cacert "$BATS_FILE_TMPDIR/ca.crt" "$(probe_url)"
	[ "$status" -eq 0 ]
	[ "$output" = 200 ]
	[ "$(cat "$BATS_FILE_TMPDIR/body")" = sandbox ]

	run curl -sS -o /dev/null "$(probe_url)"
	[ "$status" -eq 60 ]
}

@test "a pod on each cluster fetches the probe with the sandbox CA" {
	local role
	skip_without_resolver
	for role in "${ROLES[@]}"; do
		run pod_fetch "$role"
		echo "$role: $output"
		[ "$status" -eq 0 ]
		[ "$output" = 200 ]
	done
}

@test "no Corefile holds the sandbox block after the first make up" {
	local role
	for role in "${ROLES[@]}"; do
		[[ $(corefile "$role") != *"# sandbox: begin"* ]]
	done
}

@test "the Corefile of the module resolver is the one of the storage cluster with the sandbox block" {
	[ "$(corefile storage)" = "$(yq '.data.Corefile' "$ROOT/infrastructure/resolver/coredns/configmap.yaml" |
		sed '/# sandbox: begin/,/# sandbox: end/d')" ]
}

@test "make up with the resolver switch on brings eight stages Ready and prints the resolver settings" {
	local config dns bridge
	config=$(config_copy '.switches["resolver-fallback"] = true')
	dns=$(config_value .addresses.dns)
	bridge=$(docker network inspect -f '{{json .Options}}' cobaltcore-sandbox | jq -r '."com.docker.network.bridge.name" // empty')
	if [ -z "$bridge" ]; then
		bridge=br-$(docker network inspect -f '{{.Id}}' cobaltcore-sandbox | cut -c 1-12)
	fi
	# The name is the one of a link of the host.
	[ -e "/sys/class/net/$bridge" ]
	run sb_make up PROFILE=gateway CONFIG="$config"
	[ "$status" -eq 0 ]
	[[ ${lines[-7]} =~ ^up:\ 8\ stages\ Ready\ on\ 3\ clusters\ at\ latest@sha256:[0-9a-f]{64}$ ]]
	[ "${lines[-6]}" = "up: the resolver fallback answers nip.io names on $dns; route the host's lookups to it:" ]
	[ "${lines[-5]}" = "  sudo resolvectl dns $bridge $dns && sudo resolvectl domain $bridge '~nip.io'   # systemd-resolved" ]
	[ "${lines[-4]}" = "  server=/nip.io/$dns   # dnsmasq" ]
	[[ ${lines[-3]} == "export KUBECONFIG="* ]]
}

@test "the Service nip-io answers on addresses.dns for a container on the Docker network" {
	local dns
	dns=$(config_value .addresses.dns)
	[ "$(kc management -n kube-system get service nip-io -o jsonpath='{.status.loadBalancer.ingress[*].ip}')" = "$dns" ]
	# make up returns once the ConfigMap is applied; CoreDNS reads the block
	# after the kubelet has synced its volume and the reload plugin has seen
	# the change.
	eventually 120 corefile_loaded management
	docker pull -q "$CURL_IMAGE" >/dev/null
	run docker run --rm --network cobaltcore-sandbox --dns "$dns" -v "$BATS_FILE_TMPDIR/ca.crt:/ca.crt:ro" \
		--entrypoint curl "$CURL_IMAGE" -sS -o /dev/null -w '%{http_code}' --cacert /ca.crt "$(probe_url)"
	[ "$status" -eq 0 ]
	[ "$output" = 200 ]
	[ "$(template_matches management)" -gt 0 ]
}

@test "every cluster loads the sandbox block within 120 s and its pods fetch the probe by name" {
	local role
	for role in "${ROLES[@]}"; do
		eventually 120 corefile_loaded "$role"
	done
	for role in "${ROLES[@]}"; do
		run pod_fetch "$role"
		echo "$role: $output"
		[ "$status" -eq 0 ]
		[ "$output" = 200 ]
		[ "$(template_matches "$role")" -gt 0 ]
	done
}

@test "make up with the committed configuration removes the resolver stages and the Service and keeps the block" {
	local role
	run sb_make up PROFILE=gateway
	[ "$status" -eq 0 ]
	[[ ${lines[-4]} =~ ^up:\ 5\ stages\ Ready\ on\ 3\ clusters ]]
	eventually 120 resolver_gone
	for role in "${ROLES[@]}"; do
		[[ $(corefile "$role") == *"# sandbox: begin"* ]]
	done
}

@test "make down leaves no network, container, cluster or state directory" {
	run sb_make down
	[ "$status" -eq 0 ]
	run sandbox_exists
	[ "$status" -ne 0 ]
	rm "$BATS_FILE_TMPDIR/owned"
}
