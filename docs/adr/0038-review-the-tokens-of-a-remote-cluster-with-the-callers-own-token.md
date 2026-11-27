# ADR-0038: Review the tokens of a remote cluster with the caller's own token

- Status: Proposed
- Date: 2026-11-27
- Source: [#13](https://github.com/C5C3/sandbox/issues/13)

## Context

OpenBao authenticates the ServiceAccounts of the storage and compute clusters through the auth mounts `kubernetes/storage` and `kubernetes/hypervisor` ([ADR-0007](0007-ceph-client-keys-through-openbao.md)). To review a login it calls the TokenReview API of the cluster that issued the token, configured in `auth/kubernetes/<mount>/config` with the API server and its CA. Upstream's `setup-auth.sh` enables both mounts and leaves their config unwritten, for the time those clusters exist.

The API server and CA of a kind cluster are known to kind, and through it to the command layer, which already reads `kind get kubeconfig --internal` for the kubeconfig Secrets of Flux. Writing into OpenBao needs the root token, which the bootstrap keeps in `shared-services/openbao-init-keys` on the management cluster.

## Decision

The review uses the token of the login itself: the config sets `disable_local_ca_jwt=true` and no `token_reviewer_jwt`, so OpenBao presents the ServiceAccount token of the login to the TokenReview API of that cluster. The account that logs in holds `system:auth-delegator` on its cluster: the module `key-push` binds `rook-ceph/ceph-keys-push`, and [#18](https://github.com/C5C3/sandbox/issues/18) binds `openstack/ceph-keys-read` on the compute cluster.

`make up` writes the API server and the base64 of the CA of each attached remote cluster into the ConfigMap `flux-system/openbao-remote-auth`. The stage `management-openbao-remote-auth` substitutes them, as an optional source, into the Job `openbao-remote-auth`, which reads the root token in the cluster, as the Job `openbao-bootstrap` does, and writes `auth/kubernetes/storage/config` and `auth/kubernetes/hypervisor/config`. A changed CA changes the Job's spec, and Flux creates it again.

## Alternatives not taken

A `token_reviewer_jwt` of a long-lived ServiceAccount token of each remote cluster. It would carry a credential across the cluster boundary and into OpenBao's storage.

The command layer writing into OpenBao itself, with the root token on the host. The token would leave the management cluster, and the configuration of OpenBao would no longer be what its stages apply.

## Consequences

No credential crosses the cluster boundary for the review. Each account that logs in on a remote mount needs `system:auth-delegator` on its own cluster, which lets it create TokenReviews there.

Without a remote cluster attached the ConfigMap holds no data, and the Job leaves the config of the mounts as it is. A cluster attached later gets its config at the next `make up`.
