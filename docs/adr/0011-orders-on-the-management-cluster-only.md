# ADR-0011: Run orders from namespaces on the management cluster only

- Status: Accepted
- Date: 2026-11-24
- Source: D11 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The upstream [Quick Start (Orders)](https://c5c3.github.io/cobaltcore/quick-start-orders.html) has two parts. In Part 1 a service owner orders Keystone, MariaDB and RabbitMQ pieces from a namespace the ControlPlane assigns to them on the cluster of the ControlPlane. In Part 2 the owner orders from a second cluster, a target cluster.

The sandbox runs three kind clusters: `sandbox-management` for management and the control plane, `sandbox-storage` for Ceph and `sandbox-compute` for the hypervisors. None of them is a cluster for service owners.

## Decision

Orders run from namespaces on the management cluster only, as in Part 1 of the upstream quick start. The owners' namespaces live on the management cluster.

There is no fourth cluster, and the database and the message bus are not published.

## Alternatives not taken

A workload cluster for Part 2 of the orders quick start. It would be a fourth cluster, and the database and the message bus would have to be published to it.

## Consequences

Part 2 of the Quick Start (Orders) is not built.

There is no fourth cluster, and the database and the message bus are not published for orders.

A further owner is a further namespace with an assignment of its own.

[#11](https://github.com/C5C3/sandbox/issues/11) builds the orders.
