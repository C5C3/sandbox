# ADR-0037: Publish OpenBao under a nip.io name named in its certificate from the start

- Status: Proposed
- Date: 2026-11-27
- Source: [#13](https://github.com/C5C3/sandbox/issues/13)

## Context

The External Secrets of the storage and compute clusters reach the shared OpenBao of the management cluster on port 8200 with mutual TLS ([ADR-0007](0007-ceph-client-keys-through-openbao.md)). Inside the management cluster, OpenBao answers on its chart's Service, and its server certificate `openbao-tls`, upstream's `vendor/cobaltcore/deploy/bases/tls/openbao-tls-cert.yaml`, names only cluster-internal names and loopback addresses. A client on another cluster reaches neither the Service nor such a name.

Every other published endpoint of the sandbox is a MetalLB address of the configuration with a nip.io name ([ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md)). OpenBao reads its certificate only at its start, and a restart of its pod seals it until the bootstrap unseals it again ([ADR-0020](0020-unseal-the-shared-openbao-once-with-upstream-scripts.md)).

## Decision

OpenBao gets the address `addresses.openbao` of the configuration, by default `172.30.255.12`, inside `addresses.pool`. The module `openbao-remote-auth` publishes it as the Service `shared-services/openbao-published` of type `LoadBalancer` on that address, with the one port 8200 and the selector of the chart's Service, which stays as it is.

The module `pki` adds `openbao.<a-b-c-d>.nip.io` of that address to the dnsNames of `openbao-tls` in every profile, through a patch that the stage `management-pki` substitutes from `cluster-vars`. Clients dial `https://openbao.<a-b-c-d>.nip.io:8200` and verify the server with `ca.crt` of their client certificate's Secret, the `openbao-ca` that also signs `openbao-tls`.

## Alternatives not taken

The name in the certificate only when a profile lists `openbao-remote-auth`. A profile that adds the module to a running sandbox would then need a new server certificate in a running OpenBao, which reads it only at its start; a restart seals it, and a reload is an operation on the sandbox that no stage does.

## Consequences

A sandbox grows into the key hand-off without a new server certificate. The certificate of every profile carries one name more, which costs nothing while nothing publishes it.

A sandbox built before this change serves the old certificate until `make down`. Its clients fail the verification of the name.

The configuration has one required key more, and `config_load` refuses an `addresses.openbao` outside the pool or equal to the Gateway, DNS or RabbitMQ address.
