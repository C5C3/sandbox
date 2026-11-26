# ADR-0026: Release a vendored chart through an ArtifactGenerator on the hub

- Status: Proposed
- Date: 2026-11-26
- Source: [#15](https://github.com/C5C3/sandbox/issues/15), decided by the repository owner on 2026-11-25

## Context

The CobaltCore operators of the management cluster get their identity on a compute cluster from upstream's chart `target-cluster-access`, which the cluster's owner installs there. Upstream ships it as a directory, `deploy/bases/target-cluster-access`, which the sandbox vendors at the pin ([ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md)) and which travels in the artifact of the working tree ([ADR-0003](0003-oci-artifact-of-the-working-tree.md)).

The compute cluster runs no Flux ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md)), so a `HelmRelease` applied there would never be reconciled. A Helm release for another cluster is a `HelmRelease` on the management cluster that names the kubeconfig Secret of that cluster in `spec.kubeConfig`. A `HelmRelease` of Flux 2.10 reads its chart from a `HelmRepository`, a `GitRepository` or a `Bucket` through `spec.chart.spec.sourceRef`, or from an `OCIRepository`, a `HelmChart` or an `ExternalArtifact` through `spec.chartRef`. The `OCIRepository` `sandbox` holds the whole working tree, not a chart.

No upstream run and no earlier package of the sandbox covered this chain of a generated artifact and a release across a kubeconfig Secret, so the issue asked for it to run on a host before the other modules of the package were written.

## Decision

The `FluxInstance` runs source-watcher as a fourth controller. With it listed, the flux-operator turns on the feature gate `ExternalArtifact` of helm-controller and kustomize-controller, which Flux 2.10 leaves off by default; the sandbox adds no patch of its own for the gate, which the repository owner settled on 2026-11-26 after the host showed the operator setting it.

The module `access` of `sandbox-compute` has the stage `compute-access`, which names no kubeconfig and applies two objects from `compute/access` to `flux-system` of the management cluster:

- the `ArtifactGenerator` `target-cluster-access`, which copies `vendor/cobaltcore/deploy/bases/target-cluster-access/` out of the `OCIRepository` `sandbox` into the `ExternalArtifact` `target-cluster-access`, the chart in a directory of its name;
- the `HelmRelease` `compute-access`, which reads that `ExternalArtifact` through `spec.chartRef`, reaches the compute cluster through `kubeconfig-compute`, and installs the release `target-cluster-access` into `c5c3-access` with its history there (`storageNamespace`), with the values `namespaces` and `privilegedNamespaces` `[openstack]` and `createNamespaces: true`.

The stage waits for both with `healthCheckExprs`, as kstatus reads no Ready condition of either. The stage contract of `tests/unit/modules.bats` accepts this second shape for storage and compute: a stage without `spec.kubeConfig` whose path holds at least one `HelmRelease`, each naming `kubeconfig-<role>`.

On the host on 2026-11-25 the stage turned Ready about three minutes into `make up` of a sandbox with the module `access` alone, the token Secret was filled in, and the account could create Secrets in `openstack` and not in `default`.

## Alternatives not taken

`helm package` and `helm push` to the local registry from `push_artifact`, and an `OCIRepository` of the chart. The command layer would pack and push a second artifact on every `make up` and `make push`, and would have to know which directories of the tree are charts.

A `GitRepository` of upstream at the pin. It is the alternative [ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md) did not take: the cluster would fetch from GitHub what the working tree already holds, and the pin would live in two places.

`helm upgrade --install` from the command layer. The module would have no stage: `make status` would show no row for it, a profile without it would not remove it, and Flux would not repair a drift.

## Consequences

Every sandbox runs a fourth Flux controller, whatever its profile, and a running sandbox gains it at its next `make up`. A further chart that upstream ships as a directory reaches another cluster with one more pair of `ArtifactGenerator` and `HelmRelease`.

The chart is the one of the pin and moves with it. Helm installs the seven order CRDs of its `crds/` directory with the first install and never upgrades them, so a move of the pin that changes one needs `kubectl apply` of the changed file on the compute cluster, as the chart's `values.yaml` says.

Taking `access` off the profile removes the stage, whose objects go with it, and helm-controller uninstalls the release on the compute cluster. The namespace `openstack` stays, with the annotation `helm.sh/resource-policy: keep` and the label `pod-security.kubernetes.io/enforce: privileged`.

The sandbox depends on the flux-operator turning the gate on. A flux-operator that stopped doing so would leave the `HelmRelease` without a chart, and `tests/host/lifecycle.bats` checks the gate among the arguments of helm-controller.
