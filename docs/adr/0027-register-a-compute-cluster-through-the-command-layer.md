# ADR-0027: Register a compute cluster through the command layer

- Status: Proposed
- Date: 2026-11-26
- Source: [#15](https://github.com/C5C3/sandbox/issues/15)

## Context

The CobaltCore operators reach a target cluster through its registration: a Secret in `c5c3-clusters` on the management cluster with the label `sigs.k8s.io/multicluster-runtime-kubeconfig: "true"`, a kubeconfig, and the namespaces they may use there. Upstream's guide Deploy to a Target Cluster assembles that kubeconfig from the server of `kind get kubeconfig --internal` and the token and CA of the Secret `c5c3-access/target-cluster-access-token`, which the token controller of the target fills in once the access chart is installed ([ADR-0026](0026-release-a-vendored-chart-through-an-artifactgenerator-on-the-hub.md)). The operators refuse a kubeconfig whose user runs a credential plugin and leave such a cluster unresolvable, without a message on any object.

The token comes from one cluster and the Secret goes to another, which no stage of Flux can do. The README asks that the registration be a part of its own with inputs, a kubeconfig and names, and not a side effect of creating a kind cluster, because the external compute cluster of milestone 7 is registered the same way.

## Decision

`scripts/lib/register.sh` holds the registration in three functions:

- `register_cluster <name> <namespaces> [<role>]` reads a kubeconfig on stdin and applies the Namespace `c5c3-clusters` and the Secret `c5c3-clusters/<name>` with the keys `kubeconfig` and `namespaces` and the label of the operators; a role adds the label `sandbox.c5c3.io/cluster: <role>`. It checks the name, the namespaces and the kubeconfig, credential plugins included, before it writes anything.
- `registration_kubeconfig <role>` builds the kubeconfig of upstream's guide for a kind cluster of the sandbox, one cluster and one context named after it and the user `target-cluster-access` with the token alone.
- `ensure_registrations` registers each attached cluster whose modules list `access` once its token exists, waiting up to `SANDBOX_STAGE_TIMEOUT`, and removes the registrations with the label of the role of one that does not.

`hub_sync` calls `ensure_registrations` after it has applied the roots, whose stage `compute-access` fills the token, and before it waits for the stages, so a stage that needs the registration is not waited for before it exists. The kind compute cluster is registered as `sandbox-compute`, the name every `targetClusterRef` of its modules uses.

`scripts/register.sh <name> <kubeconfig-file> [<namespaces>]` registers a cluster the sandbox did not create, from a file or stdin, with the namespaces `openstack` unless given, and without the label of a role, so `make up` leaves it alone. It has no `make` target.

The kubeconfig reaches no file and no argument list: it travels through pipes and shell variables, as the kubeconfig Secrets of Flux do.

## Alternatives not taken

A Job on the management cluster that reads the token through `kubeconfig-compute`. It would keep the registration in Flux, but it serves no external cluster, which has no such Secret, and it puts a cluster-admin kubeconfig into a pod.

The registration as a step of `ensure_cluster`, when the kind cluster is created. The token exists only after Flux has installed the access chart, which comes later, and the registration would be the side effect of creating a kind cluster that the README rules out.

## Consequences

`make up` of a profile with `access` waits for the token before it waits for the stages, up to `SANDBOX_STAGE_TIMEOUT`, and stops with the stage to look at when the token does not come. A second `make up` writes the same Secret and changes nothing.

The name `sandbox-compute` cannot change under a live `OVNChassis`, `NeutronMetadataAgent` or `NovaCompute`. A profile that drops `access` removes the registration at its next `make up`, so the objects that name the cluster go first.

The token of the registration does not expire and lives in the etcd of both clusters. Rotating it is two commands by hand, upstream's; the sandbox is rebuilt rather than repaired.
