# ADR-0010: Accept six of the seven order kinds beside a compute cluster

- Status: Accepted
- Date: 2026-11-24
- Source: D10 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

A service owner orders Keystone, MariaDB and RabbitMQ pieces from a namespace on the management cluster that the ControlPlane assigns to them, as in Part 1 of the upstream Quick Start (Orders). The module `orders` creates the owner's namespace, adds the `namespaceAssignments` entry to the ControlPlane and applies example orders of the seven order kinds:

- `KeystoneUser`
- `KeystoneProject`
- `KeystoneRoleAssignment`
- `KeystoneCatalogEntry`
- `KeystoneApplicationCredential`
- `MariaDBDatabase`
- `RabbitMQVhost`

Upstream: a compute cluster needs a brownfield message bus with TLS, because the ControlPlane webhook admits `spec.services.nova.remoteCompute` only with `spec.infrastructure.messaging.secretRef` and `.tls`.

Upstream: a brownfield bus serves no `RabbitMQVhost` orders. They report `MessagingNotManaged`. With a compute cluster attached, six of the seven order kinds work.

The profile `controlplane`, which runs all eight services with a fake compute and no compute cluster, keeps the managed bus. The profiles `storage`, `full` and `parity` run on the brownfield TLS bus, and `identity` can start on it ([ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md)).

## Decision

Beside a compute cluster, six of the seven order kinds are enough. `RabbitMQVhost` is evaluated on the profile `controlplane`.

The TLS bus a compute cluster needs is a brownfield bus, which serves no vhost orders.

## Alternatives not taken

Waiting for an upstream change before building the compute cluster. The compute cluster would wait until upstream lets a brownfield bus serve vhost orders.

## Consequences

On the TLS bus `RabbitMQVhost` reports `MessagingNotManaged`, and the other six kinds converge.

On the managed bus of the profile `controlplane` all seven kinds converge, and `RabbitMQVhost` is evaluated there.

Milestone 2, orders from namespaces on the management cluster, checks seven kinds on `controlplane` and six on the TLS bus.

[#11](https://github.com/C5C3/sandbox/issues/11) builds the orders.
