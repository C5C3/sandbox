# ADR-0035: Apply Rook's namespace and CRD in a module of their own before the release from the hub

- Status: Proposed
- Date: 2026-11-26
- Source: [#12](https://github.com/C5C3/sandbox/issues/12)

## Context

The storage cluster runs no Flux, so a Helm release for it is a `HelmRelease` on the management cluster that names `kubeconfig-storage` ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md), [ADR-0026](0026-release-a-vendored-chart-through-an-artifactgenerator-on-the-hub.md)). One stage applies to one cluster: point 4 of the stage contract of `tests/unit/modules.bats` lets a stage of storage either name `kubeconfig-storage` or apply to the management cluster a path whose `HelmRelease` objects each name that Secret.

Upstream's `ceph` overlay mixes the two clusters (`vendor/cobaltcore/deploy/overlays/metal-stack/ceph/kustomization.yaml`). Its `HelmRepository` `rook-release` and `HelmRelease` `rook-ceph` belong on the hub. Its Namespace `rook-ceph` and CRD `clientprofiles.csi.ceph.io` belong on the storage cluster before the operator starts: the Rook 1.21 operator watches `ClientProfile`, upstream's release turns off the CSI operator, whose subchart carries the CRD, and without the CRD the operator exits after about two minutes (`csi-clientprofile-crd.yaml` of that overlay).

Rook accepts a loop device only when asked to. With the chart value `allowLoopDevices` (`deploy/charts/rook-ceph/values.yaml` of rook/rook@v1.21.0) the operator sets `ROOK_CEPH_ALLOW_LOOP_DEVICES`, the prepare Job gets `CEPH_VOLUME_ALLOW_LOOP_DEVICES=true` (`pkg/operator/ceph/cluster/osd/provision_spec.go`), and only then is `loop` a supported device type (`pkg/clusterd/disk.go`). A claim-backed OSD names its device `/mnt/<claim>` as an exact device, so the branches that keep loop devices away from `useAllDevices` and the filters (`pkg/daemon/ceph/osd/daemon.go`) do not apply. Upstream's release sets no such value, and the OSDs of the sandbox sit on loop devices ([ADR-0034](0034-create-the-loop-devices-and-their-local-volumes-in-the-command-layer.md)).

## Decision

The storage cluster's part of upstream's overlay is the module `rook-crds`, and the hub's part is the module `rook-operator`, whose stage depends on that of `rook-crds`. The repository owner decided this on 2026-11-26.

- `rook-crds` applies upstream's `namespace.yaml` and `csi-clientprofile-crd.yaml` unchanged to `sandbox-storage`, through the stage `storage-rook-crds` with `kubeconfig-storage` and no `dependsOn`.
- `rook-operator` holds copies of upstream's source and release in `flux-system` of the hub, under names of their own: the `HelmRepository` `storage-rook-release` with upstream's `spec`, and the `HelmRelease` `storage-rook-ceph`, which installs the chart `rook-ceph` at `v1.21.0` as the release `rook-ceph` into `rook-ceph` on `sandbox-storage` through `kubeconfig-storage`, with its history there (`storageNamespace`). Chart, version, `install`, `upgrade` and five values are upstream's. `tests/unit/modules.bats` compares each copy with upstream's file, as it does for `compute/controllers/releases.yaml`.
- The stage `storage-rook-operator` names no kubeconfig, depends on `storage-rook-crds`, has `timeout: 10m` and waits for the release with the `healthCheckExprs` of `clusters/compute/controllers/stage.yaml`.

The release adds one value to upstream's: `allowLoopDevices: true`. The stage `storage-ceph-cluster` depends on `storage-rook-operator` and `storage-block-devices`.

## Alternatives not taken

Three modules, with the Namespace and the CRD in the stage of `ceph-cluster`. That stage runs after the release, so the CRD would reach the operator after its start, and the operator would exit after about two minutes and restart with a growing back-off until then.

## Consequences

A profile with `rook-operator` lists `rook-crds` too, as `profile_load` refuses a stage whose dependency the profile does not list. The release history and the objects of the chart sit in `rook-ceph` on `sandbox-storage`, which holds no namespace `flux-system`.

`make validate` checks Rook's kinds against the CRDs of rook/rook@v1.21.0, the source `rook` of `scripts/crd-sources.yaml`, and `tests/unit/crd-sources.bats` ties that version to the chart version of the release. A move of the pin that changes upstream's source, or the chart, version, `install`, `upgrade` or values of its release, fails `make test` until the copies follow.

`allowLoopDevices` is the sandbox's own value. The pull request of this package records it for [C5C3/cobaltcore#1339](https://github.com/C5C3/cobaltcore/issues/1339), Ceph on kind.

The Ceph modules are not taken off a running sandbox: upstream's teardown needs six ordered steps and a confirmed cleanup policy (`vendor/cobaltcore/deploy/overlays/metal-stack/ceph/kustomization.yaml`), which no stage order reproduces. `make down` is the way out.
