# ADR-0022: Let a module patch the stages of other modules

- Status: Proposed
- Date: 2026-11-25
- Source: [#9](https://github.com/C5C3/sandbox/issues/9)

## Context

A module of a cluster is the directory `clusters/<role>/<module>/`, a kustomize Component whose only resource is its stage, and the root `cluster-<role>` lists the modules of the profile as its components ([ADR-0015](0015-select-modules-through-one-root-kustomization-per-cluster.md)). Each stage applies one directory of the tree.

Two modules of [#9](https://github.com/C5C3/sandbox/issues/9) change a stage they do not own. The `ControlPlane` `controlplane` is one object in the stage `management-controlplane`, and the module `messaging-tls` has to add its brownfield messaging block to it and order that stage after its own. The keystone-operator is a release of the stage `management-controllers`, which suspends it with the other service operators in `infrastructure/controllers/kustomization.yaml`, and the module `controlplane` has to resume it. The service modules of [#10](https://github.com/C5C3/sandbox/issues/10), [#11](https://github.com/C5C3/sandbox/issues/11), [#14](https://github.com/C5C3/sandbox/issues/14) and [#15](https://github.com/C5C3/sandbox/issues/15) add their blocks to the same `ControlPlane` and resume their operators the same way.

Three properties, each verified by a render with flux 2.10.0, decide how such a change is written:

- A patch whose target stage the root does not contain changes nothing and is no error, so `messaging-tls` runs without `controlplane`.
- To add to a list of a stage, the stage declares the list, empty if need be, and the patch appends with `op: add` and a path that ends in `/-`.
- To change an object that the `kustomization.yaml` of the stage's path already patches, the patch appends a Flux patch to `spec.patches` of the stage. A component named in `spec.components` of the stage runs before the patches of that `kustomization.yaml` and loses against them: a component that set `suspend: false` on the keystone-operator left it suspended.

## Decision

A module may carry a third file, `clusters/<role>/<module>/patches/kustomization.yaml`: a kustomize Component with `patches` and no `resources`. Each patch targets a Flux `Kustomization` `<role>-<other module>` of the same cluster by `group: kustomize.toolkit.fluxcd.io`, `kind` and `name`.

The command layer lists `<module>/patches` in the root, after all modules, for every module of the profile that has the file, in the order of the modules. Every stage therefore exists before the first patch runs, and the order of the modules in a profile stays free. Counting, waiting and syncing do not change, because a patches Component adds no stage.

`make validate` checks each patch of such a Component against the root of its cluster and fails for a patch without which the root renders the same, and its `reach` follows `spec.components` of a stage, so the patches of a service component are checked too.

## Alternatives not taken

Switches that the command layer maps to patches. The knowledge of which module changes which stage would live in shell, outside the tree that Flux applies and `make validate` renders, and a profile is a convenience on top of the module lists, not a second mechanism.

A fixed `ControlPlane` and the keystone-operator in every profile. `gateway` and `platform` would run an operator and a control plane before any service, and the messaging mode, which cannot change after the `ControlPlane` exists, would be the same for every profile, where `controlplane` keeps the managed bus and `identity` runs on the TLS bus ([ADR-0006](0006-brownfield-rabbitmq-with-tls-from-milestone-1.md)).

## Consequences

A module states in its own directory what it adds to other stages, and a profile that leaves out the target stage leaves the patch without effect.

A stage that other modules extend declares the lists they append to: `management-controllers` carries `patches: []`, and `management-controlplane` its `components` and `dependsOn`.

Taking `messaging-tls` off a profile whose `ControlPlane` runs on its bus removes the messaging block from the `ControlPlane`, which upstream refuses; the stage `management-controlplane` reports the refusal, and `make down` is the way out.
