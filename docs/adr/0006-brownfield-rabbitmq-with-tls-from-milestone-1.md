# ADR-0006: Use a brownfield RabbitMQ with TLS from the first milestone on the path to full

- Status: Accepted
- Date: 2026-11-24
- Source: D6 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox offers profiles, named selections of clusters, modules and switches. `identity` runs Keystone on the management cluster. `controlplane` runs all eight services with a fake compute on the management cluster. `storage` adds the storage cluster with Cinder on Ceph. `full` adds the compute cluster with one hypervisor node. `parity` is `full` plus Barbican, Horizon, `cinder-backup`, a second hypervisor node and three OSDs. Milestone 1 builds the control plane, and milestone 4 attaches the first hypervisor on the compute cluster.

Upstream: a compute cluster needs a brownfield message bus with TLS. The ControlPlane webhook admits `spec.services.nova.remoteCompute` only with `spec.infrastructure.messaging.secretRef` and `.tls`.

Upstream: the managed `RabbitmqCluster` the ControlPlane provisions has no TLS listener.

Upstream: the messaging mode cannot be changed after the ControlPlane exists. A profile chooses it up front, and a change means recreating the ControlPlane.

## Decision

The path to `full` uses a brownfield RabbitMQ with TLS from the first milestone. The module `messaging-tls` on the management cluster holds a `RabbitmqCluster` the sandbox owns, with a TLS listener, its certificate and the transport URL Secrets, and publishes AMQPS on a load-balancer address of its own, `rabbitmq.<a-b-c-d>.nip.io:5671`. The profiles `storage`, `full` and `parity` use this bus, and `identity` can be started on it to grow into them without a rebuild. `controlplane` keeps the managed bus.

The bus is required for a compute cluster, and the messaging mode is immutable once the ControlPlane exists.

## Alternatives not taken

Starting on the managed bus and rebuilding the ControlPlane at milestone 4. Because the messaging mode cannot change after the ControlPlane exists, attaching the compute cluster would then mean recreating the ControlPlane.

## Consequences

The module `messaging-tls` belongs to milestone 1, before any compute cluster exists. Its certificate comes from the sandbox CA, and its address is a MetalLB address with a nip.io name, as [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md) records.

The profiles `storage`, `full` and `parity` run on the TLS bus, and `identity` can start on it.

The profile `controlplane` keeps the managed bus and is the place to evaluate `RabbitMQVhost` orders.

Upstream: a brownfield bus serves no `RabbitMQVhost` orders, so on the TLS bus they report `MessagingNotManaged`. [ADR-0010](0010-six-of-seven-order-kinds-beside-a-compute-cluster.md) accepts this.

[#9](https://github.com/C5C3/sandbox/issues/9) builds the TLS bus for Keystone, and [#10](https://github.com/C5C3/sandbox/issues/10) for the remaining services.

This decision rests on point 4 of "Points to prove first": a `RabbitmqCluster` owned by the sandbox, with a TLS listener on a load-balancer address, is accepted as brownfield bus, and all control-plane services run on it. [#9](https://github.com/C5C3/sandbox/issues/9) proves it for Keystone and [#10](https://github.com/C5C3/sandbox/issues/10) for the remaining services, both in milestone 1. The point has no fallback beside a compute cluster, because the webhook requires a brownfield bus with TLS there. If the point fails, the package that finds the failure records the fallback it takes as a new ADR, which supersedes this one in whole or in part.
