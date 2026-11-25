# ADR-0023: Select the services of the ControlPlane as modules without a stage

- Status: Proposed
- Date: 2026-11-25
- Source: [#10](https://github.com/C5C3/sandbox/issues/10), decided by the repository owner on 2026-11-25

## Context

A profile selects what runs by listing modules ([ADR-0015](0015-select-modules-through-one-root-kustomization-per-cluster.md)), and a module may change the stages of other modules through a patches Component ([ADR-0022](0022-let-a-module-patch-the-stages-of-other-modules.md)). Until [#10](https://github.com/C5C3/sandbox/issues/10) every module had a stage, and the command layer counted, waited for and synced one stage per module.

The `ControlPlane` `controlplane` is one object in the stage `management-controlplane`, and each OpenStack service is one block under its `spec.services`. Of the seven services that [#10](https://github.com/C5C3/sandbox/issues/10) adds beside Keystone, five apply nothing beside their block: Glance, Placement, Barbican, Cinder and Nova. Neutron adds the `OVNCentral` it references and Horizon the ExternalSecret of its secret key, and both belong to the same stage as the block. A stage per service would apply an empty directory five times.

Neutron, Cinder and Nova require `spec.infrastructure.messaging`, and upstream's defaulting webhook turns an empty block into the managed bus `openstack-rabbitmq`. The module `messaging-tls` adds the brownfield block of the TLS bus.

## Decision

A module of a cluster has one of two shapes. A module with a stage is `clusters/<role>/<module>/` with `kustomization.yaml` and `stage.yaml`, and may hold `patches/kustomization.yaml`. A module without a stage holds `patches/kustomization.yaml` alone. A profile lists both shapes under `modules`. The root lists a module as a component only when it has a stage, and the patches Component of every module after all of them. `profile_load` reads `dependsOn` from the modules with a stage only, and only their stages count: `make up` counts, waits for and syncs stages, not modules.

Each of the seven services is a module without a stage: `glance`, `placement`, `barbican`, `neutron`, `cinder`, `nova` and `horizon`. Its patches Component appends the Component `components/<service>` to the stage of `controlplane` and resumes the release of its operator on one replica in the stage of `controllers`; `glance` also makes the stage of `controlplane` depend on that of `objectstore`, and `neutron` resumes the ovn-operator beside its own. The Component patches the block of Step 4 of upstream's Quick Start (ControlPlane) into the `ControlPlane`.

The switches `glance`, `barbican`, `horizon` and `fake-compute` of the configuration, each `false` by default, add the module of their name to `sandbox-management`, so a smaller profile gains one of them without a profile file of its own. `make up` stops before anything is created when a switch lacks a module it needs.

The bus follows from the profile. The Components of Neutron, Cinder and Nova declare `spec.infrastructure.messaging: {}` in the patch of their block. Without `components/messaging-tls` the block stays empty and the webhook makes it the managed bus; with it, before or after them, the block is the brownfield one. A profile runs on the TLS bus when it lists `messaging-tls` and on the managed bus when it does not.

## Alternatives not taken

A stage per service. Five of the seven stages would apply an empty directory, and each would only add a dependency of the stage `management-controlplane`, which holds the one object they all change.

A switch per service, with the profiles turning them on. It is the second selection mechanism that [ADR-0022](0022-let-a-module-patch-the-stages-of-other-modules.md) rejects: the knowledge of which switch changes which stage would live in shell, outside the tree that Flux applies and `make validate` renders. The four switches of the decision add a module each and stay within the module model.

## Consequences

A module without a stage has no `dependsOn`. What it needs beside it is checked where it is applied: admission refuses Nova without Glance, Placement and Neutron, Cinder without a backend, and the three bus consumers without a bus, and the stage `management-controlplane` reports the refusal. `make status` shows no row for such a module.

The last line of `make up` counts stages: `identity` runs 10 stages, `controlplane` 19 modules and 12 stages.

The database tenant Job writes the role of each service the `ControlPlane` declares when it runs. The Component of each service with a database adds a variable `TENANT_SERVICE_<SERVICE>` to the Job, so a changed set of services changes the Job, Flux creates it again, and `controlplane/tenant.sh` waits until the `ControlPlane` declares those services.

The patches of the seven modules that resume an operator test that `controllers` suspended its release before they set `suspend: false`. kustomize's `replace` adds a missing field, so in the render of every module, which `make validate` checks, the suspension of `infrastructure/controllers/kustomization.yaml` would otherwise change nothing and fail the check. The patch of `controlplane` that resumes the keystone-operator keeps its two operations.

The messaging mode is fixed when the `ControlPlane` is created. A running `identity` grows into a profile that adds the services beside `messaging-tls`, but not into `controlplane`, and `make down` is the way out.
