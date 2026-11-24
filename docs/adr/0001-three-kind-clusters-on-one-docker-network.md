# ADR-0001: Run three kind clusters on one Docker network of their own

- Status: Accepted
- Date: 2026-11-24
- Source: D1 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox rebuilds the lab of the upstream Quick Start (metal-stack) of CobaltCore OpenStack on kind clusters on a single Linux host. It requires dedicated clusters per role: management and control plane share one kind cluster, and storage (Ceph) and compute (the KVM hypervisors) each get a kind cluster of their own and attach to the control plane over the interfaces a real site would use.

Upstream: the split across clusters is documented but not tested. The architecture describes storage and compute clusters attached to a control plane. The dedicated storage cluster is a [sketch](https://c5c3.github.io/cobaltcore/future/storage-cluster.html), and for compute upstream states that no suite crosses a cluster boundary with Nova, exposes a broker, or runs the openstack-hypervisor-operator (hvo). The sandbox would be the first environment that exercises these paths end to end.

kind attaches its nodes to a user-defined Docker network when the environment variable `KIND_EXPERIMENTAL_DOCKER_NETWORK` names one. The host reaches every address on such a network directly. A network of its own keeps the address plan of the sandbox apart from other kind clusters on the host.

## Decision

The sandbox runs three kind clusters on one Docker network of their own. `sandbox-management` holds management and the control plane, `sandbox-storage` holds Ceph, and `sandbox-compute` holds the hypervisors. All three join the user-defined Docker network `cobaltcore-sandbox`, which has a fixed, configurable subnet with the default `172.30.0.0/16` and is selected through `KIND_EXPERIMENTAL_DOCKER_NETWORK`.

Dedicated clusters per role are required. One network lets every cluster and the host reach every published address.

## Alternatives not taken

One multi-node cluster with node pools per role. It has no cluster boundary, so nothing of the attachment contract between the control plane and the storage and compute clusters is evaluated.

## Consequences

The host must run Linux. The design relies on the host and all clusters sharing one routable Docker network, and on `/dev/kvm`, so macOS and Windows hosts are not supported.

The sandbox does not survive a host reboot or a Docker restart. kind does not keep node addresses stable, and the Ceph monitors and the registration kubeconfigs depend on them. The sandbox is rebuilt, not repaired.

All kind nodes share the host kernel. Each node has its own network namespace, so each runs its own Open vSwitch datapath and its own reservation of the migration ports.

The host needs `fs.inotify.max_user_instances` at 512 or more. Upstream: a second kind cluster beside a full devstack fails at `Preparing nodes` with the default of 128.

The addresses the clusters publish on the network are recorded in [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md), and external clusters reach them over the VPN of [ADR-0012](0012-external-clusters-over-a-vpn.md).

[#3](https://github.com/C5C3/sandbox/issues/3) builds the network and the three clusters.

This decision rests on point 1 of "Points to prove first": Rook brings up an OSD on a loop device offered as a static `volumeMode: Block` local volume inside a kind node. [#12](https://github.com/C5C3/sandbox/issues/12) proves it in milestone 3, which builds Ceph on `sandbox-storage`. The fallbacks are to name the loop device to Rook directly; a block-capable provisioner; and a Ceph outside Kubernetes on the Docker network, which then is the external storage case and removes the kind cluster `sandbox-storage`. If the point fails, the package that finds the failure records the fallback it takes as a new ADR. The third fallback supersedes this one in whole or in part, and it also changes [ADR-0002](0002-flux-on-the-management-cluster-as-hub.md) (the hub for all three clusters), [ADR-0007](0007-ceph-client-keys-through-openbao.md) (the PushSecrets on the storage cluster) and [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) (the storage cluster itself). The first two leave this one standing and change the static local volume that [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) records.
