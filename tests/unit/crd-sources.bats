#!/usr/bin/env bats
# scripts/crd-sources.yaml: the schemas of Flux name the versions the hub
# runs, and the CRD streams the remote resources the stages read.

setup() {
	load helpers
	SOURCES=$SANDBOX_ROOT/scripts/crd-sources.yaml
}

# source_url <name>: prints the URL of the schemas of the entry.
source_url() {
	NAME=$1 yq '.sources[] | select(.name == strenv(NAME)) | .schemas' "$SOURCES"
}

# crds_url <name>: prints the URL of the CRD stream of the entry.
crds_url() {
	NAME=$1 yq '.sources[] | select(.name == strenv(NAME)) | .crds' "$SOURCES"
}

@test "every entry has a name and exactly one of schemas, path and crds, and every URL is https" {
	[ "$(yq '.sources | length' "$SOURCES")" -gt 0 ]
	[ "$(yq '[.sources[] | select((.name // "") == "" or ([has("schemas"), has("path"), has("crds")] | map(select(.)) | length) != 1)] | length' "$SOURCES")" = 0 ]
	[ "$(yq '[.sources[] | (.schemas, .crds) | select(. != null and (test("^https://") | not))] | length' "$SOURCES")" = 0 ]
}

@test "the CRD streams of the Gateway API, Envoy Gateway and MetalLB are the resources the stages read" {
	[ "$(yq -o=json -I=0 '.resources' "$SANDBOX_ROOT/infrastructure/crds/kustomization.yaml")" = \
		"[\"$(crds_url gateway-api)\",\"$(crds_url envoy-gateway)\"]" ]
	[ "$(yq '.resources[0]' "$SANDBOX_ROOT/infrastructure/loadbalancer/kustomization.yaml")" = "$(crds_url metallb)" ]
}

@test "the chart version of Envoy Gateway is the version of its CRD stream" {
	local version
	version=$(yq '.patches[] | select(.target.name == "envoy-gateway") | .patch' "$SANDBOX_ROOT/infrastructure/controllers/kustomization.yaml" |
		yq '.[] | select(.path == "/spec/chart/spec/version") | .value')
	[[ $(crds_url envoy-gateway) =~ ^https://github\.com/envoyproxy/gateway/releases/download/v([0-9.]+)/envoy-gateway-crds\.yaml$ ]]
	[ "$version" = "${BASH_REMATCH[1]}" ]
}

@test "the schemas of flux are a release of the version of the FluxInstance" {
	local version
	version=$(yq '.spec.distribution.version' "$SANDBOX_ROOT/flux/flux-instance.yaml")
	[[ $version =~ ^([0-9]+)\.([0-9]+)\.x$ ]]
	[[ $(source_url flux) =~ ^https://github\.com/fluxcd/flux2/releases/download/v${BASH_REMATCH[1]}\.${BASH_REMATCH[2]}\.[0-9]+/crd-schemas\.tar\.gz$ ]]
}

@test "the schemas of flux-operator are the release of flux.operator of config.yaml" {
	[ "$(source_url flux-operator)" = "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v$(yq '.flux.operator' "$SANDBOX_ROOT/config.yaml")/crd-schemas.tar.gz" ]
}
