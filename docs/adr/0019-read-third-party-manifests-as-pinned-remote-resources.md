# ADR-0019: Read third-party manifests as pinned remote resources

- Status: Proposed
- Date: 2026-11-25
- Source: [#7](https://github.com/C5C3/sandbox/issues/7)

## Context

The module `crds` installs the CRDs of the Gateway API and of Envoy Gateway. Upstream applies them from [`hack/deploy-infra.sh`](https://github.com/C5C3/cobaltcore/blob/15a0323e243c7f53b91200f193a58b5b41d41f6a/hack/deploy-infra.sh#L510-L524), a path the checkout does not hold ([ADR-0016](0016-vendor-only-the-upstream-paths-that-are-read.md)). The module `loadbalancer` installs MetalLB, which upstream does not ship. Both are release assets of third parties.

`make validate` renders every stage and checks what Flux applies ([ADR-0013](0013-move-the-upstream-pin-by-scheduled-pull-request.md)). The `FluxInstance` runs with `multitenant: false`, so the kustomize-controller reads the `https://` resources of a kustomization.

## Decision

The modules `crds` and `loadbalancer` list the release assets as `https://` resources of their kustomization, pinned by the version in the URL: `standard-install.yaml` of the Gateway API `v1.6.3`, `envoy-gateway-crds.yaml` of Envoy Gateway `v1.9.3`, the versions of upstream's script, and `metallb-native.yaml` of MetalLB `v0.16.2`. `scripts/crd-sources.yaml` names the same URLs as `crds` sources, so `make validate` converts their CRDs into schemas, and its render reads the resources as Flux does. The versions follow upstream's script by hand.

## Alternatives not taken

Flux sources with nested Kustomizations, as the [CRD stage of C5C3/playground](https://github.com/C5C3/playground/blob/d2e6b59642e8d299d2c2a3a081e1cda5161fe749/infrastructure/crds/bundles.yaml) does. `make validate` renders the stages of the tree, not what a nested Kustomization applies from another source, so that content would go unchecked.

The MetalLB Helm chart. The kustomize-controller applies the CRDs of a stage before its other objects. With a `HelmRelease`, the dry run of the address pool fails before the release that installs the pool's CRD is applied, and the stage never starts.

Copies of the manifests in the tree. Several megabytes of generated YAML to replace by hand at each version, in a diff no reviewer reads.

## Consequences

The management cluster reads `github.com` and `raw.githubusercontent.com` at every reconcile of `crds` and `loadbalancer`, and `make validate` reads them as well.

A release asset is trusted by its version tag. No digest pins its content.

`kubeconform` checks no `CustomResourceDefinition` object against a schema.

When a newer upstream pin moves the versions in `hack/deploy-infra.sh`, the sandbox follows by hand: `make validate` does not read that script.
