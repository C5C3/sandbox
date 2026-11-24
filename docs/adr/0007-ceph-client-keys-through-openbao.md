# ADR-0007: Hand the Ceph client keys over through the OpenBao of the management cluster

- Status: Accepted
- Date: 2026-11-24
- Source: D7 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The storage cluster `sandbox-storage` runs Rook Ceph with the `CephClient` users `cinder` and `cinder-backup`, one cephx user per consumer. The consumers sit on other clusters: `cinder-volume` and `cinder-backup` on the management cluster, and libvirt on the compute cluster, which defines a libvirt secret from the `cinder` key so that QEMU can attach RBD volumes.

The management cluster runs a shared OpenBao and the External Secrets Operator.

Upstream: the hand-off of the keys must always work by hand. The owner of a Ceph cluster creates the user and its key with `ceph auth get-or-create` and the Secret with `kubectl create secret`. Pushing the keys into OpenBao is the automated variant, with a `PushSecret` on the side of Ceph and an `ExternalSecret` on the side of each consumer.

A Ceph cluster that the sandbox does not create can later replace or join `sandbox-storage`, and its owner has to hand over its keys too.

## Decision

Ceph client keys travel through the management cluster's OpenBao. On the storage cluster, one `PushSecret` per client writes its key into the OpenBao of the management cluster, and the consumers read it from there with an `ExternalSecret`.

It is the hand-off upstream designed (`PushSecret`, `ExternalSecret`), and the same path an external Ceph can use.

## Alternatives not taken

Copying Secrets between clusters with a script. It is simpler, but it is not what a site would run.

## Consequences

OpenBao answers on port 8200 with mutual TLS on a load-balancer address, for the External Secrets Operators of the storage and compute clusters. The load-balancer addresses are those of [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md).

External Secrets on the storage cluster authenticates through the auth mount `kubernetes/storage` with the policy `push-ceph-keys`. External Secrets on the compute cluster authenticates through the auth mount `kubernetes/hypervisor` with a sandbox policy that reads `ceph/client-cinder`. Both present a client certificate for OpenBao's mutual TLS.

OpenBao reviews the tokens of those service accounts against the Kubernetes APIs of the storage and compute clusters, configured in `auth/kubernetes/<cluster>/config`, which the upstream bootstrap leaves for the time those clusters exist.

The External Secrets Operator runs on the storage and compute clusters as well as on the management cluster.

The hand-off takes four modules. `openbao-remote-auth` on the management cluster holds the auth mounts, roles and policies for the storage and compute clusters and puts OpenBao on a load-balancer address. `ceph-keys` on the management cluster holds the ExternalSecrets `ceph-client-cinder` and `ceph-client-cinder-backup` in the namespace `openstack`. `key-push` on the storage cluster holds a SecretStore against the management OpenBao and the two PushSecrets. `ceph-libvirt-secret` on the compute cluster holds the ExternalSecret for the `cinder` key that the `ceph-secret` container of libvirt reads.

[#13](https://github.com/C5C3/sandbox/issues/13) builds the hand-off, and [#18](https://github.com/C5C3/sandbox/issues/18) builds it for libvirt.

This decision rests on point 3 of "Points to prove first": OpenBao on the management cluster authenticates service accounts of the storage and compute clusters through `kubernetes/<cluster>` mounts, and those clusters obtain the client certificate its mutual TLS requires, which upstream issues from a ClusterIssuer of the management cluster. [#13](https://github.com/C5C3/sandbox/issues/13) proves it in milestone 3, which builds Ceph on the storage cluster and the key hand-off. The fallbacks are AppRole or a token for the remote stores, which changes how the remote stores authenticate, and copying the key Secrets with a script, which is the alternative not taken above. If the point fails, the package that finds the failure records the fallback it takes as a new ADR, which supersedes this one in whole or in part.
