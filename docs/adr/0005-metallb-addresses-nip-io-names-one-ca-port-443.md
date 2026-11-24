# ADR-0005: Publish on MetalLB addresses with nip.io names and one sandbox CA, on port 443

- Status: Accepted
- Date: 2026-11-24
- Source: D5 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The three kind clusters of the sandbox join the Docker network `cobaltcore-sandbox`, whose subnet defaults to `172.30.0.0/16`. The host reaches every address on it directly. The workstation, the pods of every cluster and, later, external clusters have to reach the same published endpoints.

Upstream: the Quick Start (ControlPlane) runs everything on one kind cluster and publishes it behind `*.127-0-0-1.nip.io:8443`. The lab of the Quick Start (metal-stack) publishes a Gateway on port 443 with a lab CA that is name-constrained to `nip.io`.

[nip.io](https://nip.io) resolves `<name>.<a-b-c-d>.nip.io` to the address `a.b.c.d`, for the workstation and for the pods of every cluster alike. No CoreDNS rewrite and no `/etc/hosts` entry is needed.

## Decision

Published addresses are MetalLB addresses with nip.io names and one sandbox CA, on port 443. MetalLB runs in layer-2 mode on the management cluster, with a pool from the upper end of the Docker subnet. Services ask for a fixed address, so every published address is known before the first deploy. The Envoy proxy of the Gateway `openstack-gw` is a `LoadBalancer` Service on port 443, as in the upstream lab. With the address `172.30.255.10` the suffix is `172-30-255-10.nip.io`, and the endpoints are `https://keystone.<suffix>/v3`, `https://horizon.<suffix>`, `https://nova-console.<suffix>`, `https://nova-metadata.<suffix>` and one per remaining service. One sandbox CA from cert-manager, name-constrained to `nip.io` like the upstream lab CA, signs the Gateway certificate `*.<suffix>` and the certificate of the broker's TLS listener.

The same URL works from the workstation, from every cluster and through the VPN that connects external clusters ([ADR-0012](0012-external-clusters-over-a-vpn.md)). The Gateway matches the upstream lab's Gateway on port 443 instead of the kind quick start's port 8443.

## Alternatives not taken

`127-0-0-1.nip.io` with host port mappings, as in the kind quick start. These addresses are not reachable from other clusters.

## Consequences

The host's resolver must answer `*.nip.io` names with private addresses. Resolvers with DNS rebinding protection drop such answers, and for them a module with a CoreDNS template and a local resolver entry is the way out.

`sandbox-ca.pem` is what a workstation passes as `OS_CACERT`.

Nothing binds a port on a host interface. The sandbox is reachable from the host only, and a remote workstation needs an SSH tunnel or a route to the Docker subnet.

Every address comes from one configuration file and reaches the manifests through Flux `postBuild` substitution from a `cluster-vars` ConfigMap, as on C5C3/playground. No manifest carries a literal address.

The sandbox CA also signs the TLS listener of the message bus on `rabbitmq.<a-b-c-d>.nip.io:5671`, which [ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md) records.

[#7](https://github.com/C5C3/sandbox/issues/7) builds the load balancer, the sandbox CA and the Gateway.

This decision rests on point 5 of "Points to prove first": `nova-compute` and the openstack-hypervisor-operator (hvo) on the compute cluster trust the Gateway's certificate. Upstream: the remote compute contract the ControlPlane delivers to a compute cluster carries `ca.crt` for the broker only, and no field names a trust anchor for Keystone. The candidate is that one CA signs broker and Gateway, that the pool's `extraConfig` points `cafile` of the client sections at the mounted `ca.crt`, and that hvo gets `OS_CACERT` through a post-renderer. [#17](https://github.com/C5C3/sandbox/issues/17) proves it in milestone 4, which brings the first hypervisor. The fallbacks are a certificate from a public CA through DNS-01 on a real domain, which replaces the sandbox CA and the nip.io names, and an upstream change. If the point fails, the package that finds the failure records the fallback it takes as a new ADR, which supersedes this one in whole or in part.
