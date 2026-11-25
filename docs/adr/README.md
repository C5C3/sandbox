# Architecture decision records

Each file in this directory records one decision with its context, the alternatives not taken and its consequences. ADR-0001 to ADR-0014 record D1 to D14 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), and the number of each ADR is the number of its decision. All fourteen are accepted: D10 to D14 were decided by the repository owner on 2026-11-24, and D1 to D9, proposals of the README, were accepted on the same day in [#2](https://github.com/C5C3/sandbox/issues/2).

| ADR | Title | Status |
| --- | --- | --- |
| [ADR-0001](0001-three-kind-clusters-on-one-docker-network.md) | Run three kind clusters on one Docker network of their own | Accepted |
| [ADR-0002](0002-flux-on-the-management-cluster-as-hub.md) | Run Flux on the management cluster as the hub for all three clusters | Accepted |
| [ADR-0003](0003-oci-artifact-of-the-working-tree.md) | Serve the Flux source as an OCI artifact of the working tree from a local registry | Accepted |
| [ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md) | Vendor C5C3/cobaltcore at a pinned commit and reference it by path | Accepted |
| [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md) | Publish on MetalLB addresses with nip.io names and one sandbox CA, on port 443 | Accepted |
| [ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md) | Use a brownfield RabbitMQ with TLS from the first milestone on the path to full | Accepted |
| [ADR-0007](0007-ceph-client-keys-through-openbao.md) | Hand the Ceph client keys over through the OpenBao of the management cluster | Accepted |
| [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) | Run the storage cluster on one node with one OSD and single-replica pools by default | Accepted |
| [ADR-0009](0009-resource-names-of-the-upstream-guides.md) | Name resources as the upstream guides do | Accepted |
| [ADR-0010](0010-six-of-seven-order-kinds-beside-a-compute-cluster.md) | Accept six of the seven order kinds beside a compute cluster | Accepted |
| [ADR-0011](0011-orders-on-the-management-cluster-only.md) | Run orders from namespaces on the management cluster only | Accepted |
| [ADR-0012](0012-external-clusters-over-a-vpn.md) | Connect external clusters over a VPN that routes the Docker subnet | Accepted |
| [ADR-0013](0013-move-the-upstream-pin-by-scheduled-pull-request.md) | Move the upstream pin by a scheduled pull request gated on validation | Accepted |
| [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) | Target a 16 GiB host for the profiles up to full | Accepted |
| [ADR-0015](0015-select-modules-through-one-root-kustomization-per-cluster.md) | Select modules through one root Kustomization per cluster | Accepted |
| [ADR-0016](0016-vendor-only-the-upstream-paths-that-are-read.md) | Vendor only the upstream paths that are read | Accepted |
| [ADR-0017](0017-open-the-pin-pull-request-with-the-built-in-token.md) | Open the pin pull request with the built-in token | Accepted |
| [ADR-0018](0018-print-the-host-resolver-settings-of-the-nip-io-fallback.md) | Print the host's resolver settings of the nip.io fallback | Accepted |
| [ADR-0019](0019-read-third-party-manifests-as-pinned-remote-resources.md) | Read third-party manifests as pinned remote resources | Proposed |
| [ADR-0020](0020-unseal-the-shared-openbao-once-with-upstream-scripts.md) | Unseal the shared OpenBao once with upstream's scripts | Accepted |
| [ADR-0021](0021-install-the-c5c3-operator-without-the-keystone-operator.md) | Install the c5c3-operator without the keystone-operator | Accepted |
| [ADR-0022](0022-let-a-module-patch-the-stages-of-other-modules.md) | Let a module patch the stages of other modules | Proposed |
| [ADR-0023](0023-select-the-services-of-the-controlplane-as-modules-without-a-stage.md) | Select the services of the ControlPlane as modules without a stage | Proposed |
| [ADR-0024](0024-run-cinder-on-upstreams-nfs-export-in-the-profile-controlplane.md) | Run Cinder on upstream's NFS export in the profile controlplane | Proposed |

## Points to prove first

The [points to prove first of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#points-to-prove-first) are assumptions of the design that no upstream run covers. Each row names the Sub Issue of [#2](https://github.com/C5C3/sandbox/issues/2) that proves the point and the ADRs whose Decision or Consequences can change if the point fails.

| Point | Assumption | Proved by | ADR |
| --- | --- | --- | --- |
| 1 | Rook brings up an OSD on a loop device offered as a static `volumeMode: Block` local volume inside a kind node. | [#12](https://github.com/C5C3/sandbox/issues/12) | [ADR-0001](0001-three-kind-clusters-on-one-docker-network.md), [ADR-0002](0002-flux-on-the-management-cluster-as-hub.md), [ADR-0007](0007-ceph-client-keys-through-openbao.md), [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) |
| 2 | With host networking on the storage cluster, Cinder on the management cluster and QEMU on the compute node reach monitor and OSDs, and the monitor address stays valid for the life of the sandbox. | [#12](https://github.com/C5C3/sandbox/issues/12) | [ADR-0001](0001-three-kind-clusters-on-one-docker-network.md), [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md) |
| 3 | OpenBao on the management cluster authenticates service accounts of the storage and compute clusters through `kubernetes/<cluster>` mounts, and those clusters obtain the client certificate its mutual TLS requires. | [#13](https://github.com/C5C3/sandbox/issues/13) | [ADR-0007](0007-ceph-client-keys-through-openbao.md) |
| 4 | A `RabbitmqCluster` owned by the sandbox, with a TLS listener on a load-balancer address, is accepted as brownfield bus, and all control-plane services run on it. | [#9](https://github.com/C5C3/sandbox/issues/9) and [#10](https://github.com/C5C3/sandbox/issues/10) | [ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md) |
| 5 | `nova-compute` and the openstack-hypervisor-operator (hvo) on the compute cluster trust the Gateway's certificate. | [#17](https://github.com/C5C3/sandbox/issues/17) | [ADR-0005](0005-metallb-addresses-nip-io-names-one-ca-port-443.md), [ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md), [ADR-0012](0012-external-clusters-over-a-vpn.md) |
| 6 | The libvirt DaemonSet of the upstream lab runs on a kind node, with `/dev/kvm` present, `vhost_net` loadable, libvirtd in a systemd scope of the node and the kvm-node-agent writing the TLS files. | [#16](https://github.com/C5C3/sandbox/issues/16) | none |
| 7 | hvo onboards a node across the cluster boundary with the patched images upstream publishes. | [#17](https://github.com/C5C3/sandbox/issues/17) | [ADR-0002](0002-flux-on-the-management-cluster-as-hub.md) |
| 8 | A chassis on the compute cluster registers with the Southbound database through node ports. | [#17](https://github.com/C5C3/sandbox/issues/17) | none |
| 9 | Flux on the management cluster applies stages and Helm releases to the other clusters through kubeconfig Secrets, the hvo release with values from a Secret on the management cluster. | [#4](https://github.com/C5C3/sandbox/issues/4) and [#17](https://github.com/C5C3/sandbox/issues/17) | [ADR-0002](0002-flux-on-the-management-cluster-as-hub.md), [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) |
| 10 | The working set of `full` fits a 16 GiB host. | [#19](https://github.com/C5C3/sandbox/issues/19) | [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) |
| 11 | The ControlPlane admits the reduced service sets of `storage` and `full`. | [#10](https://github.com/C5C3/sandbox/issues/10) | [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) |
| 12 | Geneve tunnels and live migration work between two kind nodes of one host. | [#20](https://github.com/C5C3/sandbox/issues/20) | none |

A point with `none` is expected to change no ADR of D1 to D14. Its failure is still recorded as a new ADR under item 1 of "When a point to prove fails", and that ADR supersedes each ADR whose Decision or Consequences the fallback taken changes.

## Adding a decision

Take the next free number, from ADR-0015 on, and name the file `NNNN-<title in kebab case>.md` like the others. Copy the header and the four sections `Context`, `Decision`, `Alternatives not taken` and `Consequences`. Set Source to the issue or pull request the decision comes from. Add a row with the ADR's title and Status to the table above. Open the pull request with Status `Proposed` and set it to `Accepted`, in the file and in the table, before merging.

Do not edit the `Decision` of an accepted ADR. A changed decision is a new ADR, and the old one's Status becomes `Superseded by [ADR-NNNN](<file>)`, or `Superseded in part by [ADR-NNNN](<file>): <what changed>`, in its file and in the table.

## When a point to prove fails

The package that finds the failure writes the new ADR before it builds the modules that rest on the point. Its pull request changes four things:

1. It adds the new ADR. Its Context names the point, what was run and what failed. Its Decision is the fallback taken. It supersedes, in whole or in part, each ADR whose Decision or Consequences the fallback taken changes, and no other. The ADRs in the point's ADR cell are the ones to check first.
2. It sets the Status of each superseded ADR, in its file and in the table of ADRs above.
3. It puts the new ADR into the ADR cell of the point's row in the points table.
4. It adds the new ADR's link beside the old one in the row of each superseded decision in the [design decisions of the README](../../README.md#design-decisions).

Where the new ADR supersedes nothing, the second and the fourth item do not apply.

A gap in upstream behind the failure is linked from the new ADR as its issue at [C5C3/cobaltcore](https://github.com/C5C3/cobaltcore/issues).
