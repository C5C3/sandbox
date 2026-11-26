# ADR-0031: Carry the sandbox CA to a compute cluster through the command layer

- Status: Proposed
- Date: 2026-11-26
- Source: [#17](https://github.com/C5C3/sandbox/issues/17)

## Context

Point 5 of the README: `nova-compute`, the metadata agent and the hypervisor operator (hvo) on `sandbox-compute` reach Keystone, the public catalog rows and the metadata API through the Gateway on port 443, whose certificate the sandbox CA signs ([ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md)). Upstream's remote compute contract carries `ca.crt` for the broker alone, and no field of the ControlPlane, the `NovaCompute` or the hvo chart names a trust anchor for the Gateway. Upstream's guide Connect a Compute Cluster leaves the CA of the metadata API to the owner of the compute cluster, as the Secret `nova-metadata-ca`.

hvo at its pinned commit builds its Keystone client with `clientconfig.AuthenticatedClient` (`internal/openstack/service_client.go` of [cobaltcore-dev/openstack-hypervisor-operator@a2baf3f](https://github.com/cobaltcore-dev/openstack-hypervisor-operator/tree/a2baf3f4002e39ff93f105fae9594b357ba55b21)), and in the gophercloud/utils version it vendors only `NewServiceClient` reads `OS_CACERT`. The gap is [C5C3/cobaltcore#1885](https://github.com/C5C3/cobaltcore/issues/1885).

The CA lives in the Secret `cert-manager/sandbox-ca` on the management cluster. A stage on the hub substitutes only from ConfigMaps and Secrets in `flux-system`, and the README assigns CA bundles that cross a cluster boundary to the command layer.

## Decision

`make up` runs `ensure_trust` (`scripts/lib/trust.sh`) after the node preparation and before it waits for the stages, when a cluster other than management lists the module `trust`. It waits for `tls.crt` of `cert-manager/sandbox-ca` up to `SANDBOX_STAGE_TIMEOUT` and applies the ConfigMap `flux-system/sandbox-trust` with the one key `SANDBOX_CA_B64` and the label `reconcile.fluxcd.io/watch: Enabled`.

The module `trust` is the stage `compute-trust`, after `compute-access` and `management-pki`, which substitutes from that ConfigMap alone and writes two Secrets with `ca.crt` into `openstack` on `sandbox-compute`: `nova-metadata-ca`, which `caBundleSecretRef` of the metadata agent names, and `sandbox-ca`, which the post-renderer of the hvo release mounts and names in `SSL_CERT_FILE`, the file Go's default trust store reads. Until the ConfigMap exists, the build of the stage fails and it retries.

`nova-compute` mounts nothing of the module. One CA signs the broker and the Gateway, so the pool's `extraConfig` points `cafile` of `[keystone_authtoken]`, `[service_user]`, `[placement]`, `[neutron]` and `[glance]` at `/etc/nova/compute-config/ca.crt`, the broker's CA of the mirrored contract. `cafile` is no key the pool owns.

`make validate` renders a stage that substitutes from `sandbox-trust` with the placeholder `c2FuZGJveC1jYQ==`.

## Alternatives not taken

The CA of the mirrored contract for the metadata agent and hvo too, without the module `trust`. Neither reads the contract, and the shortcut holds only while one CA signs the broker and the Gateway.

`OS_CACERT` in hvo. The pinned image ignores it.

A certificate from a public CA through DNS-01 on a real domain, the README's fallback for point 5. It needs a domain only the owner of the sandbox has.

A copy of the CA by a stage, through External Secrets on the hub. The source is a cert-manager Secret on the same cluster and the target a ConfigMap in `flux-system`; the command layer already holds the hub's kubeconfig and writes `cluster-vars` the same way.

## Consequences

`make up` of a profile with `trust` waits for the sandbox CA before it waits for the stages and stops with the stage `management-pki` to look at when the CA does not come. A second run applies the same ConfigMap and changes nothing.

The copy follows the CA only at `make up`. cert-manager renews the CA 720 hours before the end of its 8760 hours, and a sandbox older than that needs a `make up` for the compute cluster to trust the new one.

A profile without `trust` leaves the ConfigMap of an earlier run in place; it holds a public certificate and no stage reads it.

`SSL_CERT_FILE` and `cafile` go once upstream carries a trust anchor for the Gateway in the remote compute contract or in hvo (C5C3/cobaltcore#1885).
