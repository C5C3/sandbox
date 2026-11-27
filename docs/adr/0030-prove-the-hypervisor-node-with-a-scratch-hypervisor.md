# ADR-0030: Prove the hypervisor node with a scratch Hypervisor

- Status: Proposed
- Date: 2026-11-26
- Source: [#16](https://github.com/C5C3/sandbox/issues/16)

## Context

The kvm-node-agent installs the TLS files of libvirt only for a `Hypervisor` of its node. The hypervisor operator (hvo) creates one cluster-scoped `Hypervisor` per node and requests the Certificate `libvirt-<node>`, and the agent copies the Secret `tls-libvirt-<node>` under `/etc/pki` of the node when `spec.installCertificate` is `true` (`internal/controller/secret_controller.go` of [cobaltcore-dev/kvm-node-agent@1e4e4b8](https://github.com/cobaltcore-dev/kvm-node-agent/tree/1e4e4b8e7050bbfa2d5a990aa21b849ba7b51700)). Without the CRD `hypervisors.kvm.cloud.sap` or without the object, the agent ends at start, and the libvirt pod waits for the files without a timeout. The CRD ships in the `crds/` of the hvo chart. hvo, its pool and the onboarding of a node are the modules of [#17](https://github.com/C5C3/sandbox/issues/17), which build on the node that point 6 proves.

## Decision

`tests/host/hypervisor-node.bats` stands in for hvo with scratch objects, as [ADR-0028](0028-prove-the-delivery-to-a-compute-cluster-with-a-scratch-pool.md) does for the pool. It applies the two CRDs of the pinned hvo chart, which `helm show crds` reads at the `ref.tag` of the `OCIRepository` `openstack-hypervisor-operator` of upstream's `deploy/overlays/metal-stack/hypervisor/sources.yaml`, so they follow the pin. It then applies `tests/host/fixtures/hypervisor-node-scratch.yaml`: the `Hypervisor` `sandbox-compute-worker` with `installCertificate` `true` and `createCertManagerCertificate`, `highAvailability` and `evacuateOnReboot` `false`, and the Certificate `libvirt-sandbox-compute-worker` of the Issuer of the module `libvirt`, the objects hvo creates for that node. It deletes the agent's pod once, so the agent starts beside its `Hypervisor` without the back-off of its earlier restarts.

The test then finds the five TLS files on the node within 600 s, the keys with mode 600, the libvirt pod Ready, libvirtd in the scope `cobaltcore-libvirtd.scope` of the node's systemd, the conditions `TLSCertificateInstalled`, `libvirtd.service` and `LibVirtConnection` of the `Hypervisor` `True`, the TLS listener on port 16514 serving the installed certificate, and transient domains without a disk `running`: one of type `kvm` and one of type `qemu` on a node with `/dev/kvm`, one of type `qemu` on a node without it. It destroys the domains and deletes the scratch objects, the Secret of the Certificate and the two CRDs before it takes the modules off the profile.

`evacuateOnReboot: false` keeps the agent from asking logind for a shutdown inhibitor, which is no part of point 6. The CRD defaults the field to `true` for the `Hypervisor` hvo creates, so the pull request of this package records for #17 whether logind answers on the bus of a kind node.

## Alternatives not taken

A `Hypervisor` in a module. It would collide with the one hvo creates for the same node in #17.

Leaving the TLS files to #17. libvirtd would not start in this package, and point 6 would be proven only with a control plane, a pool and hvo in play.

## Consequences

Point 6 is proven on a host by the test of this package, not on a running sandbox. Until #17 a sandbox with these modules has its libvirt pod `Running` and not Ready and the agent's pod restarting, which PLAN.md describes. The scratch objects leave the TLS files under `/etc/pki` of the node behind, which go with `make down`.
