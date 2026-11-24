#!/usr/bin/env bats
# scripts/crd-sources.yaml: the schemas of Flux name the versions the hub
# runs.

setup() {
	load helpers
	SOURCES=$SANDBOX_ROOT/scripts/crd-sources.yaml
}

# source_url <name>: prints the URL of the schemas of the entry.
source_url() {
	NAME=$1 yq '.sources[] | select(.name == strenv(NAME)) | .schemas' "$SOURCES"
}

@test "every entry has a name and exactly one of schemas and path, and every URL is https" {
	[ "$(yq '.sources | length' "$SOURCES")" -gt 0 ]
	[ "$(yq '[.sources[] | select((.name // "") == "" or ((has("schemas")) == (has("path"))))] | length' "$SOURCES")" = 0 ]
	[ "$(yq '[.sources[] | select(has("schemas") and (.schemas | test("^https://") | not))] | length' "$SOURCES")" = 0 ]
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
