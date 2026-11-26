# ADR-0028: Prove the delivery to a compute cluster with a scratch pool

- Status: Proposed
- Date: 2026-11-26
- Source: [#15](https://github.com/C5C3/sandbox/issues/15), decided by the repository owner on 2026-11-25

## Context

Upstream delivers three Secrets to a compute cluster by itself. The c5c3-operator writes `controlplane-nova-compute-config`, the mirror of the remote compute contract, and `controlplane-nova-hypervisor-operator-auth` once a `NovaCompute` of the Nova names the cluster, "whether or not the pool selects a node", and `controlplane-nova-metadata-agent-secret` once a `NeutronMetadataAgent` names the cluster and that Secret (upstream's Target Clusters, "Who may name a cluster", and Connect a Compute Cluster, steps 5 and 6). It writes them with the account of the access chart, so a Role of the chart that refused a write would show only then.

The objects that name the cluster belong to the module `compute-pool` of [#17](https://github.com/C5C3/sandbox/issues/17), which also needs a hypervisor node, the CA bundle of the metadata API and the hypervisor operator. Without them, the package that registers the cluster could not tell whether the registration works.

## Decision

`tests/host/compute-attach.bats` applies `tests/host/fixtures/compute-attach-scratch.yaml`: an `OVNChassis`, a `NeutronMetadataAgent` and a `NovaCompute` named `sandbox-verify*`, each with `targetClusterRef` `sandbox-compute`, and node selectors that match no node. It waits up to 300 s for the three Secrets on the compute cluster, with their labels and, for the metadata Secret, the one key `shared_secret`, and finds `NovaReady` `True`. By SHA-256 it finds `transport_url` of the mirror equal to that of the remote contract, and `nova-compute.conf` of the mirror equal to that of the remote contract and different from that of the contract of the management cluster. `transport_url` cannot tell the two contracts apart: the module `messaging-tls` renders both transport URLs from one template, and the host showed them equal on 2026-11-26. It then deletes the pool, the agent and the chassis and finds, within 300 s of the first delete, none of the Secrets, no DaemonSet and no pod in `openstack` on the compute cluster, and no object named `sandbox-verify*` in `openstack` on the management cluster but the Events about the deleted objects, which expire after an hour.

The test waits for the Secrets, not for a Ready condition of the scratch objects, because the CA bundle `nova-metadata-ca` belongs to the module `trust` of [#17](https://github.com/C5C3/sandbox/issues/17). When a Secret does not come, the reason of `NovaReady` says which write failed: `NovaComputeConfigError`, `HypervisorOperatorError` or `NovaMetadataAgentSecretError` name a write the Role of the access chart refused, a defect of the sandbox. A gate of upstream that a pool without nodes cannot pass is recorded in this ADR and reported at [C5C3/cobaltcore](https://github.com/C5C3/cobaltcore/issues).

## Alternatives not taken

Scratch checks in `make verify`. They would create workloads on the compute cluster on every run, and the real pool of [#17](https://github.com/C5C3/sandbox/issues/17), whose checks `make verify` gains then, makes them redundant.

Leaving the arrival of the Secrets to [#17](https://github.com/C5C3/sandbox/issues/17). A refused write would show only once a hypervisor depends on it, in the package that has the most other things to get right.

## Consequences

The delivery is proven on a host by the test of this package, not on a running sandbox by `make verify`. Until [#17](https://github.com/C5C3/sandbox/issues/17), the scratch objects are the only objects that name `sandbox-compute`, and they leave nothing behind but their Events.

The test reads the Secrets by their keys and labels and compares secret values by their SHA-256 only; it prints no token, password or transport URL.
