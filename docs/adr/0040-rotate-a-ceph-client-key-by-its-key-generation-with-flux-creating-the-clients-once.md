# ADR-0040: Rotate a Ceph client key by its key generation, with Flux creating the clients once

- Status: Proposed
- Date: 2026-11-27
- Source: [#13](https://github.com/C5C3/sandbox/issues/13)

## Context

Upstream's `clients.yaml` rotates the key of a `CephClient` when `spec.security.cephx.keyGeneration` rises: Rook writes a new key into `rook-ceph-client-<name>`, and the key hand-off carries it to the consumers ([ADR-0007](0007-ceph-client-keys-through-openbao.md)). The stage `storage-ceph-cluster` applies the clients with server-side apply and owns the field, so it would set a raised generation back at its next reconcile. The checks of `make verify` of [#14](https://github.com/C5C3/sandbox/issues/14) and [#18](https://github.com/C5C3/sandbox/issues/18) rotate a key and must do so without editing the configuration.

## Decision

A patch of the module `ceph-cluster` annotates the CephClients `cinder` and `cinder-backup` with `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`. Flux creates them once and leaves them. A key rotates with:

```bash
kubectl --kubeconfig .sandbox/kubeconfig/storage.yaml -n rook-ceph patch cephclient cinder --type merge -p '{"spec":{"security":{"cephx":{"keyGeneration":2}}}}'
```

The PushSecret writes the new key to OpenBao within its refresh of one minute, and the ExternalSecret updates `openstack/ceph-client-<name>` within its own.

## Alternatives not taken

A configuration switch for the key generation of each client. A rotation would then edit the configuration and run `make up`, which `make verify` must not do.

## Consequences

A change of a client's caps in upstream's `clients.yaml` no longer reaches a running sandbox; it reaches a sandbox created after it. The CephClients stay health-checked by the stage.
