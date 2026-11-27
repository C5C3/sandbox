# ADR-0024: Run Cinder on upstream's NFS export in the profile controlplane

- Status: Superseded in part by [ADR-0042](0042-append-each-volume-backend-of-cinder-as-a-flux-patch-of-the-stage-of-controlplane.md): the backend nfs1 is appended by a Flux patch of the stage of controlplane
- Date: 2026-11-25
- Source: [#10](https://github.com/C5C3/sandbox/issues/10), decided by the repository owner on 2026-11-25

## Context

The profile `controlplane` is the parity with upstream's Quick Start (ControlPlane): all eight services on the management cluster, with a fake compute. Upstream refuses `services.cinder` without a volume backend: the CRD requires at least one entry in `backends`, of type `NFS` or `RBD` (`vendor/cobaltcore/operators/c5c3/config/crd/bases/c5c3.io_controlplanes.yaml:1842`). `controlplane` runs no storage cluster, so RBD on the Ceph of the profile `storage` ([#14](https://github.com/C5C3/sandbox/issues/14)) is not there.

Upstream's quick start runs its optional block-storage block on the NFS overlay of its kind devstack, `vendor/cobaltcore/deploy/overlays/kind/nfs`: an NFS-Ganesha server in `openstack` with a claim of 5Gi on the class `standard`, and the release `csi-driver-nfs`, through which the cinder-operator mounts the export as an inline CSI volume.

## Decision

The module `cinder-nfs` runs that overlay unchanged in its stage `management-cinder-nfs`, after `management-controllers`, and its patches Component appends `components/cinder-nfs` and the dependency on its own stage to the stage of `controlplane`. The Component gives Cinder one backend, `nfs1`, on the export `/volumes`, and no backup target. It is the only Component that sets `backends`, because a merge patch replaces the list. The profile `controlplane` lists `cinder` and `cinder-nfs`.

## Alternatives not taken

Seven services in `controlplane` and Cinder only with RBD in [#14](https://github.com/C5C3/sandbox/issues/14). The profile would no longer be the parity with upstream's quick start, `make verify` would not create a volume on it, and the Cinder module of the sandbox would have no profile to run in before the storage cluster exists.

## Consequences

The host needs the kernel modules `nfs` and `nfsv4`, which the kind nodes share: `csi-driver-nfs` mounts the export with the NFS client of the host's kernel. The host check of `make up` tests them for a profile that lists `cinder-nfs`, and accepts a module that is in the module tree and not loaded, on the assumption that the kernel loads it at the first mount. The host of the first runs had both loaded already, so the case of a module that is not loaded was not observed; no `cinder-volume` pod reported a `FailedMount` there.

The kind node mounts an export whose server runs in a pod of the same node. When `make down` kills the node, the kernel's NFS client waits for the server that stopped with it, and the node needed about 19 s to exit in two of two runs, more than the 12 s Docker waits. `make down` therefore waits up to 120 s for the nodes of a cluster that kind could not delete, and deletes it again.

The NFS server runs privileged, and `csi-driver-nfs` runs a privileged DaemonSet on the host network. Its inline volumes let anyone who can create a pod in a namespace that is not PSA `restricted` mount the export as root, as the header of `vendor/cobaltcore/deploy/bases/nfs/release.yaml` says. The sandbox runs no untrusted tenant, so this is accepted here as upstream accepts it for kind.

The management cluster reads the chart of `csi-driver-nfs` from `raw.githubusercontent.com`, the images of the driver from `registry.k8s.io` and the image of the server from `ghcr.io`.

The profiles `storage` and `full` back Cinder with RBD; [#14](https://github.com/C5C3/sandbox/issues/14) adds that backend to the module `cinder`, and decides how a second backend composes with `nfs1`.
