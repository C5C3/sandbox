# ADR-0002: Run Flux on the management cluster as the hub for all three clusters

- Status: Accepted
- Date: 2026-11-24
- Source: D2 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox runs three kind clusters: `sandbox-management` for management and the control plane, `sandbox-storage` for Ceph and `sandbox-compute` for the hypervisors.

Every part of the sandbox is a module that can be enabled, left out or replaced. A module is one directory with a kustomization and one Flux `Kustomization` that names its dependencies. A cluster enables a module by listing it. Modules need ordering, health gates and pruning.

C5C3/playground, whose repository shape the sandbox follows, runs Flux stages per cluster under `clusters/`. A stage there is a Flux `Kustomization` with `dependsOn`, `wait` and health checks.

Upstream sketches a management cluster on which Flux is the hub for all clusters. Upstream also ships `make deploy-infra`, which deploys the infrastructure of its quick start into one cluster.

## Decision

Flux runs on the management cluster as the hub, with stages per module, following C5C3/playground. The management cluster runs the flux-operator and a `FluxInstance` and reconciles `clusters/<cluster>/` for all three clusters. A stage is a Flux `Kustomization` with `dependsOn`, `wait` and health checks. The storage and compute clusters are deployed through kubeconfig Secrets: their stages name a kubeconfig Secret in `spec.kubeConfig`, and Helm releases for those clusters are `HelmRelease` objects on the management cluster with the same field.

Modules need ordering, health gates and pruning, which Flux stages give. One Flux instead of three saves memory, which the 16 GiB target of [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) needs, and it is the management cluster upstream sketches.

## Alternatives not taken

Flux on every cluster. The clusters would be independent of each other, at the cost of more memory for three Flux installations instead of one.

Driving upstream's `make deploy-infra` with an own overlay. It is closest to the quick start for one cluster, but it has no modules, and its Ceph path puts Ceph into the same cluster as the control plane, where the sandbox gives Ceph a cluster of its own.

## Consequences

The storage and compute clusters run without Flux controllers.

The command layer of the sandbox, a Makefile and a few scripts, creates the kubeconfig Secrets together with the clusters, because Flux cannot reach a cluster before its Secret exists. The kubeconfigs point at `https://<cluster>-control-plane:6443`, the address `kind get kubeconfig --internal` gives.

The release of the openstack-hypervisor-operator (hvo) for the compute cluster reads its values straight from the Secret the ControlPlane writes on the management cluster.

This path exists only because the sandbox owns all three clusters. An external cluster is deployed by its owner, not by the Flux of the sandbox.

Flux reads its source as an OCI artifact of the working tree, which [ADR-0003](0003-oci-artifact-of-the-working-tree.md) records.

[#4](https://github.com/C5C3/sandbox/issues/4) builds this decision, and [#17](https://github.com/C5C3/sandbox/issues/17) builds it for Helm releases.

This decision rests on point 9 of "Points to prove first": Flux on the management cluster applies stages and Helm releases to the other clusters through kubeconfig Secrets, the hvo release with values from a Secret on the management cluster. [#4](https://github.com/C5C3/sandbox/issues/4) proves it for stages in milestone 0, and [#17](https://github.com/C5C3/sandbox/issues/17) for a Helm release in milestone 4. The fallback is Flux on every cluster, at the cost of its memory, which is the first alternative not taken above. If the point fails, the package that finds the failure records the fallback it takes as a new ADR, which supersedes this one in whole or in part.
