# ADR-0009: Name resources as the upstream guides do

- Status: Accepted
- Date: 2026-11-24
- Source: D9 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The management cluster of the sandbox runs one `ControlPlane` and one `OVNCentral` in one namespace, and Cinder gets an RBD backend on Ceph and a backup target.

The upstream quick starts and guides of CobaltCore OpenStack name these resources and give their commands and troubleshooting tables with those names: the `ControlPlane` `controlplane`, the `OVNCentral` `controlplane-ovn`, the namespace `openstack`, the RBD backend `ceph1` and the backup target `cephbk`.

## Decision

Resource names follow the upstream guides. The `ControlPlane` is named `controlplane`, the `OVNCentral` is named `controlplane-ovn`, and both live in the namespace `openstack`. The Cinder RBD backend is named `ceph1`, and the backup target is named `cephbk`.

Upstream commands and troubleshooting tables apply unchanged.

## Alternatives not taken

Sandbox-specific names. The commands and troubleshooting tables of the upstream guides would then need the names translated before they run on the sandbox.

## Consequences

The commands and troubleshooting tables of the upstream guides apply unchanged. The check of milestone 3, for example, looks for `cinder-volume` on `controlplane-cinder@ceph1`.

A second instance beside the first gets a name of its own. An external Ceph registered beside the kind one becomes a second `CinderBackend` entry named `ceph2`, with a `cinder-volume` Deployment of its own, so that `ceph1` on kind and `ceph2` external can be compared in one control plane. An external compute cluster gets a chassis, a metadata agent and a pool with names of their own.

[#9](https://github.com/C5C3/sandbox/issues/9) builds the `ControlPlane`, [#10](https://github.com/C5C3/sandbox/issues/10) the `OVNCentral`, and [#14](https://github.com/C5C3/sandbox/issues/14) `ceph1` and `cephbk`. The namespace `openstack` comes from upstream's base `operators`.
