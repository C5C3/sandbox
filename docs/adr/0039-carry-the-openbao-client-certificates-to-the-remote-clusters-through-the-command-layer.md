# ADR-0039: Carry the OpenBao client certificates to the remote clusters through the command layer

- Status: Proposed
- Date: 2026-11-27
- Source: [#13](https://github.com/C5C3/sandbox/issues/13)

## Context

OpenBao requires and verifies a client certificate signed by `openbao-ca` ([ADR-0007](0007-ceph-client-keys-through-openbao.md)). Upstream issues its client certificates with cert-manager from the ClusterIssuer `openbao-ca-issuer` of the management cluster, in the namespace of each store, as `keys-push.yaml` does for its SecretStore. The storage cluster runs no cert-manager, and no cluster but the management cluster holds `openbao-ca`.

A stage on the hub substitutes only from ConfigMaps and Secrets in `flux-system`, and a Flux variable cannot be named `tls.crt`. The command layer already copies the sandbox CA into `flux-system` for the compute cluster ([ADR-0031](0031-carry-the-sandbox-ca-to-a-compute-cluster-through-the-command-layer.md)).

## Decision

The module `openbao-remote-auth` issues `openbao-client-storage` and `openbao-client-compute` in `shared-services` from `openbao-ca-issuer`, for client auth alone. `make up` waits for each Secret of an attached remote cluster and copies its `tls.crt`, `tls.key` and `ca.crt` into the Secret `flux-system/openbao-client-<role>` as `OPENBAO_CLIENT_CRT_B64`, `OPENBAO_CLIENT_KEY_B64` and `OPENBAO_CA_B64`, with the labels `reconcile.fluxcd.io/watch` and `sandbox.c5c3.io/openbao-client`. The key goes from kubectl through jq into kubectl on stdin and reaches no file and no argument list.

The stage `storage-key-push` substitutes the Secret of the storage cluster into `rook-ceph/ceph-keys-push-client-tls`, under the name of upstream's Certificate, which the module deletes. Until the Secret exists, the build fails and the stage retries. A profile without `openbao-remote-auth` deletes the copies by their label. `make validate` renders a stage that substitutes one of the two Secrets with the placeholder `b3BlbmJhby1jbGllbnQ=`.

## Alternatives not taken

cert-manager on each remote cluster with a copy of the `openbao-ca` key. It would put the key of the CA that OpenBao trusts on every cluster, and run cert-manager where nothing else needs it.

A copy by a stage, through an ExternalSecret on the hub. Its target would hold the keys under the names of the source, and `tls.crt` cannot be a Flux variable.

## Consequences

The storage cluster runs External Secrets without cert-manager. `make up` of a profile with `openbao-remote-auth` waits for the client certificates before it waits for the stages, and stops with the stage `management-openbao-remote-auth` to look at when they do not come.

The copies follow the certificates only at `make up`. cert-manager renews them 720 hours before the end of their 8760 hours, and a sandbox older than that needs a `make up` for the remote clusters to present the new ones.
