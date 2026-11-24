# ADR-0014: Target a 16 GiB host for the profiles up to full

- Status: Accepted
- Date: 2026-11-24
- Source: D14 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox offers profiles, named selections of clusters, modules and switches. `identity` runs Keystone on the management cluster. `controlplane` runs all eight services with a fake compute on the management cluster. `storage` adds the storage cluster with Cinder on Ceph. `full` runs Keystone, Glance, Placement, Neutron, Nova and Cinder on Ceph across the management, storage and compute clusters, with one hypervisor node. `parity` is `full` plus Barbican, Horizon, `cinder-backup`, a second hypervisor node and three OSDs.

The goal is a 16 GiB host where possible. Everything that costs memory and is not needed for the part under evaluation is a switch.

Upstream: one kind node with the control plane of all eight services, Cinder on NFS, the backing services, every operator and Kubernetes requests 14,754 MiB of memory on the `Minimal` sizing profile. That is the total of upstream's CI node, checked against a gate of 4 vCPU and 16 GiB. By these figures the control plane of the profile `controlplane` alone fills a 16 GiB host, and adding two clusters to it does not fit.

After the reductions below, `full` sums to roughly 18 GiB of requests: 12.4 GiB on the management cluster (the platform about 4.6 GiB, the six services with MariaDB, Memcached and RabbitMQ about 7.8 GiB), about 3 GiB estimated on the storage cluster and about 3 GiB estimated on the compute cluster.

Requests are not use. Upstream derives them from VPA recommendations, which lie above what the pods were seen to use, and kind schedules each cluster on its own, so the sum of requests blocks nothing. What decides is the working set of all three clusters together, which nobody has measured.

## Decision

16 GiB of host memory is the target for the profiles `identity`, `controlplane`, `storage` and `full`. `parity` may need more.

A sandbox should run on a common workstation.

## Alternatives not taken

One profile sized for parity only. Every evaluation would then need the host `parity` needs, which is not a common workstation.

## Consequences

The sandbox reduces its footprint in six ways:

- Services by profile. `full` leaves out `cinder-backup`, Horizon and Barbican, which removes about 3.1 GiB of requests, and the operators of services that are off stay suspended.
- One hypervisor node, with the metadata agent at 768 MiB and guests of flavor `1` with 256 MiB.
- One OSD of about 1 GiB with single-replica pools, and reduced requests for monitor and manager ([ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md)).
- One Flux, on the management cluster ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md)).
- No observability and no UIs by default.
- A sizing profile of its own, `sandbox` on base `Minimal`, which lowers a request wherever a measurement on the sandbox shows room.

`identity`, `controlplane`, `storage` and `full` aim at 16 GiB. `parity` adds back what `full` leaves out and a second hypervisor node, and is estimated at 24 to 32 GiB.

`make footprint` reports the memory requests and the working set per cluster and in total, and every milestone records its output. Milestone 1, the control plane, gives the first hard number for the largest part.

[#19](https://github.com/C5C3/sandbox/issues/19) settles the target for `full`.

This decision rests on point 10 of "Points to prove first": the working set of `full` fits a 16 GiB host. [#19](https://github.com/C5C3/sandbox/issues/19) proves it, with measurements from [#10](https://github.com/C5C3/sandbox/issues/10) on, over milestones 1, 3, 4 and 5. If the working set does not fit, the first step is lower requests in the sizing profile `sandbox`. The fallbacks of the point are further switches and, failing those, a documented requirement above 16 GiB, which replaces this target. If the point fails, the package that finds the failure records the fallback it takes as a new ADR, which supersedes this one in whole or in part.
