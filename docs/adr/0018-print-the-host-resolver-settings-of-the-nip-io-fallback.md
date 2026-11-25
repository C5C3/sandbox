# ADR-0018: Print the host's resolver settings of the nip.io fallback

- Status: Accepted
- Date: 2026-11-24
- Source: [#7](https://github.com/C5C3/sandbox/issues/7), decided by the repository owner on 2026-11-24

## Context

Every name the sandbox publishes has the form `<name>.<a-b-c-d>.nip.io`, which the public nip.io DNS resolves to a private address on the Docker network ([ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md)). A resolver with DNS rebinding protection drops such answers. The pods of a kind cluster ask the CoreDNS of their cluster, which forwards to the host's resolver, so on such a host the names resolve to nothing, on the host and in the pods alike. The host check warns about it, and ADR-0005 names a module with a CoreDNS template and a local resolver entry as the way out.

Changing the host's resolver needs root. No other step of `make up` does.

## Decision

The switch `switches.resolver-fallback`, off by default, adds the module `resolver` to every cluster. The module adds a block to the Corefile of the cluster's CoreDNS that answers `<name>.<a-b-c-d>.nip.io` with `a.b.c.d`, taken from the name. On the management cluster it also publishes CoreDNS as the Service `kube-system/nip-io` on the MetalLB address `addresses.dns`.

The fallback changes nothing on the host. `make up` prints the settings that route the host's lookups of `nip.io` to `addresses.dns` over the bridge of the Docker network, for systemd-resolved and for dnsmasq, and the user applies them. The switch is set in the configuration or in a profile, never by the host check.

## Alternatives not taken

`make up` running `sudo resolvectl` itself. It would be the one step of `make up` that needs root, and `make down` would have to undo a change to the host.

A block in `/etc/hosts`. It has no wildcards, so every service name would need a line of its own, and it needs root as well.

Switching the fallback on from the host check. The modules of a run would depend on one DNS lookup.

## Consequences

On an affected host, the user runs one privileged command after each `make up` that creates the Docker network: the name of the bridge follows the network's ID.

The CoreDNS of the management cluster answers queries from the Docker network, from the host and from every container on it.

The Corefile of `infrastructure/resolver/coredns/configmap.yaml` is a copy of the one kubeadm creates on a kind cluster. `tests/host/gateway.bats` compares the two, so a kind release that changes it fails there. The block stays in the Corefile after the switch goes off, until `make down`, because pruning the ConfigMap would delete the configuration of CoreDNS.
