# ADR-0042: Append each volume backend of Cinder as a Flux patch of the stage of controlplane

- Status: Proposed
- Date: 2026-11-27
- Source: [#14](https://github.com/C5C3/sandbox/issues/14)

## Context

Upstream refuses `services.cinder` without a volume backend: `backends` of the `ControlPlane` requires at least one entry (`minItems: 1` in `vendor/cobaltcore/operators/c5c3/config/crd/bases/c5c3.io_controlplanes.yaml`). [ADR-0024](0024-run-cinder-on-upstreams-nfs-export-in-the-profile-controlplane.md) gave Cinder its one backend `nfs1` through `components/cinder-nfs`, whose merge patch sets `backends` to `[nfs1]`, and made it the only Component that sets the list.

[#14](https://github.com/C5C3/sandbox/issues/14) adds a second backend module, `cinder-rbd` with upstream's RBD backend `ceph1` on the Ceph of `sandbox-storage`, and [#21](https://github.com/C5C3/sandbox/issues/21) will add a third on an external Ceph. A merge patch replaces a list, so a second module that sets `backends` the same way replaces `nfs1`. `make validate` renders the profile `all`, every module of the tree in name order, and fails each patch whose removal leaves every render unchanged. In that render the second merge patch drops `nfs1`, so validation fails the patch of `cinder-nfs` as dead, and a profile that lists both modules keeps one backend without a word.

Flux applies the `spec.patches` of a stage after all of its components ([ADR-0022](0022-let-a-module-patch-the-stages-of-other-modules.md)), whatever the order of the components.

## Decision

`components/cinder` sets `backends` to the empty list in the cinder block. Each backend module appends its entry with a Flux patch of the stage of `controlplane`: its patches Component adds, at `/spec/patches/-` of `management-controlplane`, a patch of the `ControlPlane` `controlplane` with the one op `add` at `/spec/services/cinder/backends/-`, and the dependency on the stage that serves the backend at `/spec/dependsOn/-`.

- `cinder-nfs` appends `nfs1`, unchanged, and depends on `management-cinder-nfs`. `components/cinder-nfs` is deleted.
- `cinder-rbd` appends upstream's `ceph1` of `controlplane-lab.yaml` with two fields replaced: `monitors` is `sandbox-storage-control-plane:3300`, the container name of the storage node on the Docker network, and `networks` is `${NETWORK_SUBNET}`, which the stage of `controlplane` substitutes from `cluster-vars`. It depends on `management-ceph-keys`, so the `ControlPlane` names `ceph1` only once both key Secrets are Ready. The monitor is the one place the entry names its storage cluster; a backend on another Ceph is another module that appends another entry.

The root `cluster-management` substitutes nothing, so `${NETWORK_SUBNET}` reaches the stage object as text and the stage substitutes it in its render.

## Alternatives not taken

A merge patch per backend module, as `components/cinder-nfs` had. It fails `make validate` as soon as two backend modules exist, and keeps one backend of a profile that lists two.

A Component with a JSON patch per backend module, appended to `spec.components` of the stage. Components run in the order of the profile, so a backend module listed before `cinder` fails the build on the missing `/spec/services/cinder/backends`.

A Flux variable per storage cluster on the stage of `controlplane`, such as the `COMPUTE_CLUSTER` the stage of `compute-pool` substitutes. `cinder-rbd` has no stage of its own, and a variable that a JSON patch adds to `postBuild.substitute` of the stage of `controlplane` replaces the map any other module adds there.

## Consequences

Each append runs after `components/cinder`, whatever the order of the profile, and a profile with `cinder-nfs` and `cinder-rbd` gets both entries. The profile `controlplane` renders the same stage `management-controlplane` as before, byte for byte, so a running `controlplane` sandbox sees no change at its next `make up`.

`cinder` without a backend module renders the empty list, and the API server refuses the `ControlPlane`: the stage `management-controlplane` reports the refusal. `cinder-rbd` without `cinder` fails the build of `management-controlplane` on the missing path `/spec/services/cinder/backends`, and without `ceph-keys` the stage waits for a dependency that does not exist. Nothing checks either beside the stage, as for `glance` without `objectstore`.

A backend entry lives in a YAML string inside a JSON patch inside a Component, two levels of quoting deeper than a merge patch. `tests/unit/modules.bats` parses it and compares the entry of `cinder-rbd` with upstream's `ceph1`.

This ADR supersedes [ADR-0024](0024-run-cinder-on-upstreams-nfs-export-in-the-profile-controlplane.md) in part: its Decision that `components/cinder-nfs` is the only Component that sets `backends` no longer holds. The backend `nfs1` and its export stay as ADR-0024 decided.
