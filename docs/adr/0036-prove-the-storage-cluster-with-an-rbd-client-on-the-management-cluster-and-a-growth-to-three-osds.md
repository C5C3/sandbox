# ADR-0036: Prove the storage cluster with an RBD client on the management cluster and a growth to three OSDs

- Status: Proposed
- Date: 2026-11-26
- Source: [#12](https://github.com/C5C3/sandbox/issues/12)

## Context

Points 1 and 2 of the README ([Points to prove first](../../README.md#points-to-prove-first)): Rook brings up an OSD on a loop device offered as a static `volumeMode: Block` local volume inside a kind node, and with host networking on the storage cluster, Cinder on the management cluster and QEMU on the compute node reach monitor and OSDs, and the monitor address stays valid for the life of the sandbox. This package builds the storage cluster alone ([ADR-0034](0034-create-the-loop-devices-and-their-local-volumes-in-the-command-layer.md), [ADR-0035](0035-apply-rooks-namespace-and-crd-in-a-module-of-their-own-before-the-release-from-the-hub.md)): no key hand-off, which is [#13](https://github.com/C5C3/sandbox/issues/13), and no Cinder backend and no check of `make verify`, which are [#14](https://github.com/C5C3/sandbox/issues/14). `make verify` reads a `ControlPlane`, which this package does not run. The reach of QEMU is [#18](https://github.com/C5C3/sandbox/issues/18).

The stage `storage-ceph-cluster` waits for `HEALTH_OK` of the `CephCluster` and for Ready pools and clients, and does not count OSDs. [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) raises the OSDs to three through `osd-count`, with the pools at two replicas on failure domain `osd`, and the profile `parity` of [#20](https://github.com/C5C3/sandbox/issues/20) runs three. `make up` applies a higher `osd-count` to a running sandbox and refuses a lower one (ADR-0034).

## Decision

`tests/host/storage-ceph.bats` proves point 1 and, of point 2, the reach from the management cluster on a host, with two scratch profiles, as `tests/host/hypervisor-node.bats` does: `ceph`, the clusters `management` and `storage` with the four stages on `sandbox-storage` and none on `sandbox-management`, and `ceph-3`, the same with `osd-count: 3`. It refuses to start while a sandbox exists and ends with `make down`.

For point 1, after `make up PROFILE=ceph`, it finds the sparse file in the node and its loop device on the host, the PersistentVolume `sandbox-osd-0` `Bound` to a claim in `rook-ceph`, the operator Available with a restart count of 0 and `ROOK_CEPH_ALLOW_LOOP_DEVICES` `true` in its ConfigMap `rook-ceph-operator-config`, and in the toolbox `HEALTH_OK` with one monitor, an active manager and `osd.0` `up` under the host `sandbox-storage-control-plane`. It finds the pools `volumes`, `backups` and `.mgr` at size 1 with `osd` as the type of the choose step of each CRUSH rule, and the caps of the clients `cinder` and `cinder-backup`.

For point 2 it applies the Pod `sandbox-verify-ceph` of `tests/host/fixtures/storage-ceph-client.yaml` to `sandbox-management`, with the `spec.cephVersion.image` of upstream's `cluster.yaml`, so the client follows the pin. It copies `userKey` of a client's Secret from `sandbox-storage` into a file of mode 600 in the pod over stdin and runs `rbd -m sandbox-storage-control-plane:3300 --id <client> --keyfile <file>` there. As `cinder` the client creates and writes the image `volumes/sandbox-verify` and fails `rbd ls backups`, which `cinder-backup` passes. The test finds `hostNetwork` on the pods of the monitor and the OSD, the node's address on `cobaltcore-sandbox` in the ConfigMap `rook-ceph-mon-endpoints` and as the public address of `osd.0`, and no port of the node published but the API server's on `127.0.0.1`. It then deletes the monitor's pod and finds within 300 s `HEALTH_OK`, `rook-ceph-mon-endpoints` unchanged and `rbd ls volumes` of the client passing with the same `-m`.

The repository owner decided the growth to three OSDs on 2026-11-26. A second `make up PROFILE=ceph` attaches nothing and keeps the uids of the PersistentVolume and of the pod of `osd.0`. `make up PROFILE=ceph-3` attaches `osd-1.img` and `osd-2.img`, and within 900 s the test finds `num_up_osds` 3, `HEALTH_OK`, every placement group `active+clean`, the three OSDs under the one host and the three pools at size 2. `make up PROFILE=ceph` on that sandbox stops with `block-devices: sandbox-storage-control-plane holds 3 OSD files, switches.osd-count says 1; run make down first` and leaves `SWITCHES_OSD_COUNT` at `3` in `cluster-vars`. `make down` then detaches the loop devices and leaves none on the host.

No test prints a key or the data of a Secret.

## Alternatives not taken

TCP probes of the ports alone. A probe shows that a port answers, not that a client with the key of `cinder` gets the maps from the monitor under the node's name and writes to the OSD at the address they name, nor that the caps keep `cinder` out of `backups`.

Checks of `make verify`. It reads a `ControlPlane`, which this package does not run, and the checks of milestone 3 are [#14](https://github.com/C5C3/sandbox/issues/14)'s.

One OSD only. The switch `osd-count`, the pools at two replicas on failure domain `osd` and a raised count on a running sandbox would stay unproven until the profile `parity` runs them, and the refusal of a lower count needs a node with more OSD files than the count.

## Consequences

Point 1 and the reach from the management cluster of point 2 are proven on a host by the test of this package, not on a running sandbox by `make verify`, which gains the checks of milestone 3 in #14. The reach of QEMU on the compute node, the other half of point 2, stays for #18. The compute node sits on the same Docker network as the management node the test proves.

The test needs a host that passes the host check for the management and storage roles, reaches `ghcr.io`, `charts.rook.io`, `docker.io` and `quay.io`, and has more than 10 % of the filesystem under Docker free, below which the monitor raises `MON_DISK_LOW` with the sandbox's settings too. Its first `make up` pulls the images of Rook and Ceph and needs `SANDBOX_STAGE_TIMEOUT=3600`, and the growth adds up to 900 s.

The pull request of this package records the output of `make footprint` with one OSD and with three.
