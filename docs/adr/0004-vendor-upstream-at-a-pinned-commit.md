# ADR-0004: Vendor C5C3/cobaltcore at a pinned commit and reference it by path

- Status: Accepted
- Date: 2026-11-24
- Source: D4 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox composes upstream material from C5C3/cobaltcore and adds only what kind and the split across three clusters need.

Upstream: `deploy/bases` and `deploy/overlays` of C5C3/cobaltcore hold the reusable Flux stages `operators`, `tls`, `shared-openbao`, `eso-store` and `controlplane-operator`, the development sizing in `bases/devstack`, and the lab manifests under `overlays/metal-stack`. Upstream ships these bases and leaves the source, the Flux stages, the environment patches and the bootstrap execution to the repository that deploys them.

Many stages of the sandbox build on these bases, and each of them has to render against a revision of upstream.

## Decision

Upstream is vendored at a pinned commit and referenced by path. `make vendor` checks out C5C3/cobaltcore at the commit recorded in the configuration file `config.yaml` into `vendor/cobaltcore`. Stages reference `vendor/cobaltcore/deploy/...` and patch what differs.

All stages share one revision of upstream, and there are no copies of upstream to keep in step.

## Alternatives not taken

Remote references per stage. Each stage would carry its own reference to upstream, so the stages would not share one revision, and the references would have to be kept in step.

## Consequences

`make vendor` checks out the commit recorded in `config.yaml` into `vendor/cobaltcore`, which Git ignores and which becomes part of the OCI artifact Flux reads ([ADR-0003](0003-oci-artifact-of-the-working-tree.md)).

Stages reference `vendor/cobaltcore/deploy/...` and patch what differs.

All stages render against one revision. How that revision moves is recorded in [ADR-0013](0013-move-the-upstream-pin-by-scheduled-pull-request.md).

[#5](https://github.com/C5C3/sandbox/issues/5) builds `make vendor` and the pin.
