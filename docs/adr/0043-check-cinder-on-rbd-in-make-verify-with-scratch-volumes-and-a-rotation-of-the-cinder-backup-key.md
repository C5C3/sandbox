# ADR-0043: Check Cinder on RBD in make verify with scratch volumes and a rotation of the cinder-backup key

- Status: Proposed
- Date: 2026-11-27
- Source: [#14](https://github.com/C5C3/sandbox/issues/14)

## Context

Milestone 3 of PLAN.md is done when `cinder-volume` on `controlplane-cinder@ceph1` is `up`, a volume is created and its image shows in `rbd info`, and, with `cinder-backup` on, backup, restore and a rotation of the `cinder-backup` key pass. These are Part 1 Step 4 and Part 2 Steps 7, 10 and 11 of upstream's Quick Start (metal-stack), less what needs a hypervisor. Upstream runs them by hand. Upstream states there that the volume service runs on the host `controlplane-cinder@ceph1`, that the Deployments are `controlplane-cinder-volume-ceph1` and `controlplane-cinder-backup`, and that a new key rolls both.

`make verify` runs the checks of the services the `ControlPlane` declares, the compute checks ([ADR-0033](0033-check-the-compute-pool-in-make-verify-with-a-server-on-the-first-node.md)) and the order checks ([ADR-0025](0025-check-the-orders-with-scratch-orders-and-a-scheduled-rotation.md)). The images of the volumes and the backups live in the pools `volumes` and `backups` of the Ceph of `sandbox-storage`, and the keys rotate by `keyGeneration` of the `CephClient`s there ([ADR-0040](0040-rotate-a-ceph-client-key-by-its-key-generation-with-flux-creating-the-clients-once.md)).

## Decision

`scripts/lib/rbd.sh` adds five checks to `make verify`, after those of the services and before those of the compute pool. `rbd-backend` and `rbd-volume` run when the live `ControlPlane` declares an entry of `spec.services.cinder.backends` named `ceph1` of type `RBD`; `rbd-backup`, `rbd-restore` and `rbd-rotation` also need `spec.services.cinder.backupBackend` named `cephbk`.

- `rbd-backend` waits up to 300 s for `openstack volume backend pool list` to list a pool of `@ceph1#`, then finds the `cinder-volume` service on `controlplane-cinder@ceph1` `up`.
- `rbd-volume` creates the 1 GiB volume `sandbox-verify-rbd-volume`, waits up to 120 s for it to be `available` on a host that starts with `controlplane-cinder@ceph1#`, and reads `rbd info` of `volumes/volume-<id>` in the Rook toolbox on `sandbox-storage`: 1073741824 bytes.
- `rbd-backup` writes 4 MiB into the image with `rbd bench`, backs the volume up as `sandbox-verify-rbd-backup`, waits up to 600 s, and finds an image `volume-<id>.backup.*` in the pool `backups`.
- `rbd-restore` creates the 1 GiB volume `sandbox-verify-rbd-restored`, restores the backup onto it, waits up to 600 s, and compares the sha256 of the first 4 MiB of `rbd export` of both images, computed in the toolbox.
- `rbd-rotation` raises `keyGeneration` of the `CephClient` `rook-ceph/cinder-backup` by one with a merge patch, waits up to 300 s for the sha256 of `userKey` of `openstack/ceph-client-cinder-backup` to change and to equal that of `ceph auth get-key client.cinder-backup`, up to 600 s for a new generation of the Deployment `openstack/controlplane-cinder-backup` and up to 300 s for its rollout, and then backs the volume up as `sandbox-verify-rbd-rotated` within 600 s.

The checks reach `sandbox-storage` through the kubeconfig file of the role, as `compute-hypervisor` reaches `sandbox-compute`. A failed `rbd-volume` reports the three checks after it as `skipped, rbd-volume failed`, a failed `rbd-backup` reports `rbd-restore` as `skipped, rbd-backup failed`, and `rbd-rotation` still runs, so the checks report two lines without `cephbk` and five with it. No key reaches an argument, a file or a line: the Secret goes from kubectl through jq into `sha256sum` by pipes, Ceph's key into `sha256sum` inside the toolbox, and only the digests are kept. Before the first create and after the last check, also after a failure, the checks delete the two backups and then the two volumes. Nothing sets `keyGeneration` back.

## Alternatives not taken

The rotation in the host test alone. `make verify` would then lack a check that milestone 3 names, and a sandbox would have no command that shows a rotation under a running backup service.

A marker written and read back by a guest, as Part 2 Step 10 of the quick start does. It needs a hypervisor, which the profile `storage` does not run ([#18](https://github.com/C5C3/sandbox/issues/18)); the digests of the first 4 MiB of both images stand in for it.

A volume type that pins the backend `ceph1`. No shipped profile lists two backends, so the scheduler has one backend to choose, and `rbd-volume` checks the host the volume landed on.

## Consequences

`make verify` reports 6 checks on `storage` and 9 with `cinder-backup` on; `controlplane` stays at 21 and `identity` at 7. The waits of the five checks are bounded at 3540 s in all: 300 s for the pool, 120 s for the volume, 600 s for the backup, 720 s for the restore and 1800 s for the rotation. On the host run of `tests/host/storage.bats` on 2026-11-27 the nine checks took 132 s and 171 s, and the six 76 s.

Each `make verify` with `cephbk` raises `keyGeneration` of `cinder-backup` by one, and Flux leaves the raised value ([ADR-0040](0040-rotate-a-ceph-client-key-by-its-key-generation-with-flux-creating-the-clients-once.md)). A run that fails after the patch leaves the raised generation, and the next run rotates once more. The backup service restarts on every such run.

`openstack volume create` builds a client of the image service even without `--image`, and fails with `public endpoint for image service not found` in a cloud without Glance (python-openstackclient 6.6.0, and its master at the time of writing). The profile `storage` runs no Glance, so `make verify` creates every scratch volume, that of `cinder-volume` too, with `cinder create` of `python-cinderclient`, which the OpenStack CLI depends on, and reads the id from its table. `openstack volume backup restore` of 6.6.0 sends the restore and then fails on its own answer with `too many values to unpack (expected 2)`, which its master no longer does, so `rbd-restore` restores with `cinder backup-restore --volume`. Everything else stays with `openstack`.

`make verify` reads `sandbox-storage` and patches a `CephClient` there; without that cluster `rbd-volume` fails with `sandbox-storage does not exist`. A deleted volume or backup is gone from Cinder only once its service has removed it, so a backup or volume an earlier run could not delete is deleted again by name at the start of the next.
