# ADR-0041: Prove the compute half of point 3 with a scratch ExternalSecret

- Status: Proposed
- Date: 2026-11-27
- Source: [#13](https://github.com/C5C3/sandbox/issues/13)

## Context

Point 3 of the README is that OpenBao authenticates ServiceAccounts of the storage and the compute cluster through their `kubernetes/<cluster>` mounts, and that both clusters present a client certificate issued on the management cluster ([ADR-0007](0007-ceph-client-keys-through-openbao.md)). [#13](https://github.com/C5C3/sandbox/issues/13) builds the storage half and its consumer on the management cluster. The consumer on the compute cluster, the module `ceph-libvirt-secret`, is [#18](https://github.com/C5C3/sandbox/issues/18), which depends on Cinder on RBD of [#14](https://github.com/C5C3/sandbox/issues/14).

## Decision

`tests/host/storage-keys.bats` proves the compute half with the scratch objects of `tests/host/fixtures/storage-keys-compute.yaml` on `sandbox-compute`, under the names [#18](https://github.com/C5C3/sandbox/issues/18) takes: the ServiceAccount `ceph-keys-read` in `openstack` with `system:auth-delegator`, the client certificate from `flux-system/openbao-client-compute`, a SecretStore on `kubernetes/hypervisor` as the role `read-ceph-client-cinder`, and two ExternalSecrets. The one for the `cinder` key turns Ready with the key of the storage cluster; the one for the `cinder-backup` key, which the policy does not grant, is refused. The test also refuses a SecretStore on the storage cluster whose account the role `push-ceph-keys` does not bind.

## Alternatives not taken

Waiting for [#18](https://github.com/C5C3/sandbox/issues/18) to prove the compute half. Point 3 is the assumption under the whole hand-off, and a failure found with [#18](https://github.com/C5C3/sandbox/issues/18) would change modules that [#13](https://github.com/C5C3/sandbox/issues/13) and [#14](https://github.com/C5C3/sandbox/issues/14) had already built on it.

## Consequences

The role, the policy and the names [#18](https://github.com/C5C3/sandbox/issues/18) uses are fixed and proved before [#18](https://github.com/C5C3/sandbox/issues/18) starts. The scratch objects live only in the test; [#18](https://github.com/C5C3/sandbox/issues/18) replaces them with its module.
