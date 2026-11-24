#!/usr/bin/env bats
# scripts/lib/crd-schema.jq: a CustomResourceDefinition to the JSON schemas
# kubeconform reads, on documents built here.

setup() {
	load helpers
}

# convert: runs crd-schema.jq on the input as scripts/validate.sh does.
convert() {
	jq -c -f "$SANDBOX_ROOT/scripts/lib/crd-schema.jq"
}

# crd <versions>: prints a CRD of the kind Widget in the group demo.c5c3.io
# with the JSON array of versions.
crd() {
	jq -n --argjson versions "$1" '{apiVersion: "apiextensions.k8s.io/v1", kind: "CustomResourceDefinition",
		metadata: {name: "widgets.demo.c5c3.io"},
		spec: {group: "demo.c5c3.io", names: {kind: "Widget", plural: "widgets"}, scope: "Namespaced", versions: $versions}}'
}

# schema_of <openAPIV3Schema>: prints the converted schema of a CRD with one
# version v1 of the schema.
schema_of() {
	crd "[{\"name\": \"v1\", \"served\": true, \"storage\": true, \"schema\": {\"openAPIV3Schema\": $1}}]" | convert | jq -c '.schema'
}

@test "an empty input and a document that is no CRD print nothing" {
	run convert </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run convert <<<'{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "demo"}, "data": {"properties": "x"}}'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run convert <<<'null'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "each version of a CRD gives one line named after the group, the kind and the version" {
	run convert <<<"$(crd '[{"name": "v1alpha1", "schema": {"openAPIV3Schema": {"type": "object"}}},
		{"name": "v1", "schema": {"openAPIV3Schema": {"type": "object"}}}]')"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
	[ "$(jq -r '.file' <<<"${lines[0]}")" = demo.c5c3.io_widget_v1alpha1.json ]
	[ "$(jq -r '.file' <<<"${lines[1]}")" = demo.c5c3.io_widget_v1.json ]
}

@test "a node with properties is closed at the root, under properties, under items and under additionalProperties" {
	local out
	out=$(schema_of '{"type": "object", "properties": {
		"spec": {"type": "object", "properties": {
			"list": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}}}},
			"tuple": {"type": "array", "items": [{"type": "object", "properties": {"a": {"type": "string"}}}]},
			"map": {"type": "object", "additionalProperties": {"type": "object", "properties": {"b": {"type": "string"}}}}}}}}')
	[ "$(jq -c '[.additionalProperties, .properties.spec.additionalProperties,
		.properties.spec.properties.list.items.additionalProperties,
		.properties.spec.properties.tuple.items[0].additionalProperties,
		.properties.spec.properties.map.additionalProperties.additionalProperties]' <<<"$out")" = '[false,false,false,false,false]' ]
	# A node without properties stays open.
	[ "$(jq -c '.properties.spec.properties.list | has("additionalProperties")' <<<"$out")" = false ]
}

@test "a node that preserves unknown fields or has its own additionalProperties is left as it is" {
	local out
	out=$(schema_of '{"type": "object", "properties": {
		"free": {"type": "object", "x-kubernetes-preserve-unknown-fields": true, "properties": {"a": {"type": "string"}}},
		"open": {"type": "object", "additionalProperties": true, "properties": {"a": {"type": "string"}}}}}')
	[ "$(jq -c '.properties.free' <<<"$out")" = '{"type":"object","x-kubernetes-preserve-unknown-fields":true,"properties":{"a":{"type":"string"}}}' ]
	[ "$(jq -c '.properties.open' <<<"$out")" = '{"type":"object","additionalProperties":true,"properties":{"a":{"type":"string"}}}' ]
}

@test "a nullable string admits null and a field named properties is closed like any other field" {
	local out
	out=$(schema_of '{"type": "object", "properties": {
		"note": {"type": "string", "nullable": true},
		"count": {"type": "integer"},
		"properties": {"type": "object", "properties": {"size": {"type": "integer"}}}}}')
	[ "$(jq -c '.properties.note.type' <<<"$out")" = '["string","null"]' ]
	[ "$(jq -c '.properties.count.type' <<<"$out")" = '"integer"' ]
	[ "$(jq -c '.properties.properties' <<<"$out")" = '{"type":"object","properties":{"size":{"type":"integer"}},"additionalProperties":false}' ]
}

@test "nothing under anyOf, allOf, oneOf and not changes" {
	local branch='{"type": "object", "nullable": true, "properties": {"a": {"type": "string", "nullable": true}}}' out
	out=$(schema_of "{\"type\": \"object\", \"properties\": {\"value\": {
		\"anyOf\": [$branch], \"allOf\": [$branch], \"oneOf\": [$branch], \"not\": $branch}}}")
	[ "$(jq -S -c '.properties.value' <<<"$out")" = "$(jq -S -c -n "{anyOf: [$branch], allOf: [$branch], oneOf: [$branch], not: $branch}")" ]
}

@test "a version without openAPIV3Schema fails with the name of the CRD and the version" {
	run convert <<<"$(crd '[{"name": "v1alpha1", "schema": {"openAPIV3Schema": {"type": "object"}}}, {"name": "v1"}]')"
	[ "$status" -ne 0 ]
	[[ $output == *"CustomResourceDefinition widgets.demo.c5c3.io: version v1 has no openAPIV3Schema"* ]]
}
