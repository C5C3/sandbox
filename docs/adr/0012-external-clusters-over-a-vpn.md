# ADR-0012: Connect external clusters over a VPN that routes the Docker subnet

- Status: Accepted
- Date: 2026-11-24
- Source: D12 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

Once the initial build stands, a Ceph cluster and a compute cluster that the sandbox does not create can be registered in place of, or beside, the kind ones. The initial build must not block this: the clusters talk to each other only through addresses and credentials that an external cluster can use too.

The kind clusters of the sandbox share the Docker network `cobaltcore-sandbox` ([ADR-0001](0001-three-kind-clusters-on-one-docker-network.md)). The sandbox publishes its endpoints on MetalLB addresses of that network with nip.io names, and nothing binds a port on a host interface ([ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md)).

External nodes need the Gateway, the message broker, the node ports of the OVN Southbound database, OpenBao and the kind Ceph. In the other direction, the management cluster needs the API server of an external compute cluster and the VNC ports of its hypervisors, and Cinder needs the monitors and OSDs of an external Ceph.

## Decision

External clusters reach the sandbox over a VPN that routes between the Docker subnet of the sandbox and the external networks.

Kind clusters and external clusters use one address plan, and nothing is published on a host interface.

## Alternatives not taken

The host's address with published ports. Endpoints would be published on a host interface, and external clusters would reach the sandbox on other addresses than the kind clusters, so the address plan would need a second mode.

A routed subnet without a VPN. The decision of 2026-11-24 records no further reason for preferring the VPN to it.

## Consequences

The published addresses and their nip.io names stay as they are. External nodes reach the Gateway, the broker, the Southbound node ports, OpenBao and the kind Ceph on the same addresses the kind clusters use, so the address plan needs no second mode.

The Docker subnet must not overlap a network of the external site, which is one reason it is configurable.

Resolvers on the external site have to return the private addresses behind the nip.io names.

In the other direction, the management cluster reaches the external API server and the VNC ports of external hypervisors, and Cinder reaches an external Ceph.

The initial build owes three things to this decision. Published addresses and the Docker subnet are configuration. Registration of a cluster is a module of its own with inputs (kubeconfig, names), not a side effect of creating a kind cluster. The compute and storage modules on the management cluster take the cluster they attach to as a parameter, so a second instance of each is a second entry.

The VPN software and where its endpoint runs are open. Both are settled in milestone 7, which attaches external storage and external compute over the VPN.

[#21](https://github.com/C5C3/sandbox/issues/21) builds the VPN and the external clusters.
