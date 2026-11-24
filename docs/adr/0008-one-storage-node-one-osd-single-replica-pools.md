# ADR-0008: Run the storage cluster on one node with one OSD and single-replica pools by default

- Status: Accepted
- Date: 2026-11-24
- Source: D8 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The first build of the sandbox has no high availability: one pod per component, the `Minimal` sizing profile, one Ceph monitor.

The storage cluster `sandbox-storage` runs the Rook operator and one `CephCluster` with one monitor and one manager. It holds the RBD pools `volumes` and `backups`. Upstream: CobaltCore uses pools and never creates them, so the storage cluster owns them.

Upstream: the Ceph of the lab of the Quick Start (metal-stack) runs nine OSDs on three nodes with failure domain `host`. It requests 1 GiB of memory for the monitor, 512 MiB for the manager and 2 GiB per OSD.

The sandbox targets a host with 16 GiB of memory for the profiles up to `full` ([ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md)).

## Decision

The storage cluster has one node and, by default, one OSD with single-replica pools. The pools `volumes` and `backups` keep one replica on the one OSD. The switch `osd-count` raises the number of OSDs to three, and the pools then keep two replicas on failure domain `osd`. The profile `parity`, which aims at parity with the Quick Start (metal-stack), runs three OSDs.

No high availability is required, and this is the lowest footprint, which the 16 GiB target of [ADR-0014](0014-16-gib-host-for-the-profiles-up-to-full.md) needs.

## Alternatives not taken

Three OSDs with two replicas on failure domain `osd` as the default. It is not the default, but it stays available through the switch `osd-count` and is the setting of the profile `parity`.

Three nodes with failure domain `host`, as the lab. It is not built: it adds the high availability the first build does not require, at a higher footprint than one node.

## Consequences

By default a pool holds one copy of each object.

The OSD sits on a loop device that the sandbox creates in the node and offers to Rook as a static local volume with `volumeMode: Block`, so the upstream `storageClassDeviceSets` shape stays.

The switches `osd-count` and `osd-size` set the number of OSDs of the storage cluster and the size of their sparse files. The default is one OSD, and `parity` runs three.

[#12](https://github.com/C5C3/sandbox/issues/12) builds the storage cluster.
