# ADR-0015: Select modules through one root Kustomization per cluster

- Status: Accepted
- Date: 2026-11-24
- Source: [#4](https://github.com/C5C3/sandbox/issues/4), decided by the repository owner on 2026-11-24

## Context

A profile of the sandbox is a named selection of clusters, modules and switches. It selects the modules per cluster: `scaffold` runs the module `test` on all three clusters, and the profiles of the later milestones run different module sets on each.

Flux on the management cluster applies the stages of all three clusters ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md)) from an OCI artifact of the working tree ([ADR-0003](0003-oci-artifact-of-the-working-tree.md)). A module of a cluster is a directory with one stage, a Flux `Kustomization`. Flux has to learn which modules the profile selects for each cluster.

The `FluxInstance` of the flux-operator can create one sync `Kustomization`, which carries one path and one list of components. The sandbox needs one module list per cluster.

## Decision

A profile is one data file, `profiles/<name>.yaml`, with the keys `clusters`, `modules` and `switches`.

The command layer applies one root `Kustomization` `cluster-<role>` per cluster to the management cluster. It applies `clusters/<role>/`, whose kustomization lists no resource, and its `spec.components` is the module list the profile gives for the cluster. Each module of a cluster is a kustomize Component that adds its stage. The `FluxInstance` has no `spec.sync`.

The artifact is the working tree, unchanged.

## Alternatives not taken

Writing the module lists into the artifact at `make push`. The artifact would no longer be the working tree, and every push would need the profile of the last `make up` to write the same lists again.

Profiles as kustomize directories that Flux syncs. Each profile would be a directory per cluster that lists its modules, so a module is listed once in every profile that uses it, and the command layer would still choose on the management cluster which directory Flux syncs.

## Consequences

The artifact is the working tree, and `make push` needs no profile.

The roots live on the management cluster and not in the artifact. A changed profile is applied by `make up`, which applies the roots again with server-side apply, and not by `make push`. With `prune`, a module taken off the list loses its stage, and the stage removes what it applied on its cluster.

Every module of a cluster needs its Component beside its stage, and a cluster without modules needs `resources: []` in `clusters/<role>/kustomization.yaml`.

Flux documents `spec.components` of a `Kustomization` as experimental. A change of the field upstream changes the roots the command layer writes.
