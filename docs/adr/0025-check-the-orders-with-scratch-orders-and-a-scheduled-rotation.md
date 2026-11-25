# ADR-0025: Check the orders with scratch orders and a scheduled rotation

- Status: Proposed
- Date: 2026-11-25
- Source: [#11](https://github.com/C5C3/sandbox/issues/11), decided by the repository owner on 2026-11-25

## Context

The module `orders` gives the owner `workflow` its namespace on the management cluster, assigns it on the `ControlPlane` and applies the seven example orders of Part 1 of upstream's Quick Start (Orders) in the stage `management-orders` ([ADR-0011](0011-orders-on-the-management-cluster-only.md)). The profiles `identity` and `controlplane` list it. `make verify` is the quick start turned into a script, and Part 1 checks more than the presence of the orders: Step 7 watches an application credential rotate on a schedule of 3m with a grace period of 2m, and Step 10 deletes the orders in the order their holds allow and finds nothing they created.

The example orders belong to the stage. A check that rotated or deleted them would fight Flux, and the sandbox would lose its example orders until the next reconcile. A rotation of the example credential on the 3m schedule of Step 6 would go on for the life of the sandbox.

Flux takes back a field that `kubectl patch` changed on an object it applies, and the order CRDs refuse to lower `spec.passwordGeneration` and `spec.credentialGeneration` ("may only increase"). An owner who rotates a password by hand, as the upstream guide shows, would fail the stage at its next reconcile.

Upstream serves vhost orders on a bus with `clusterRef` alone. On the brownfield TLS bus of `identity` a `RabbitMQVhost` reports `VhostReady=False` with `MessagingNotManaged`, for good, which [ADR-0010](0010-six-of-seven-order-kinds-beside-a-compute-cluster.md) accepts; a stage that waits for every order to be Ready would never turn Ready there.

## Decision

`make verify` checks the orders whenever the live `ControlPlane` assigns a namespace on the management cluster. Two checks read what the assigned namespaces hold: `orders-ready` finds every order Ready, or a vhost refused with the reason of its bus, and `orders-secrets` finds the Secret of each Ready order that delivers one, controlled by the order and with its keys.

Three checks order a scratch set of their own, named `sandbox-verify*`, in the first assigned namespace that allows the role `member` and catalog entries: six orders on a bus without `clusterRef`, seven with the vhost on a managed one. `orders-converge` waits up to 300 s for them and their Secrets. `orders-rotation` is the scheduled rotation of Step 7 with `interval: 3m` and `gracePeriod: 2m`: generation 1 authenticates, generation 2 comes on the schedule, generation 1 still authenticates inside its grace period, the schedule is turned off, the Secret takes generation 2, which authenticates, and generation 1 is refused once deleted. `orders-teardown` deletes the scratch orders in the order of the holds of Step 10 and finds no Secret, no object with the labels of an order among the 16 kinds the operator creates, and no user, project or service in Keystone. verify deletes the scratch orders of an earlier run before its first check and tears them down after a failed one, and only reads the example orders.

verify authenticates from the host against `OS_AUTH_URL` with the id and the secret of the delivered Secret, in the environment of `openstack`. The `clouds.yaml` in that Secret names the in-cluster Keystone Service, which the host does not reach.

The stage `management-orders` counts a `RabbitMQVhost` as settled when its `VhostReady` has the reason `MessagingNotManaged` or `MessagingNotDeclared`. The example orders carry `kustomize.toolkit.fluxcd.io/ssa: Merge`, so Flux keeps fields that other tools added. The example `workflow-appcred` carries no `rotation` block and rotates every 720h, the form of Part 2 of the upstream page.

## Alternatives not taken

verify deleting the example orders. The teardown would test the orders an owner sees, but the stage would apply them again at its next reconcile, and verify and Flux would race for them.

A teardown proven by the host test alone. `make verify` would not show on a running sandbox that the operator removes what an order created, and the host test would be the only place the teardown runs.

A rotation by hand, raising `spec.credentialGeneration`. It is quicker, but it skips the schedule and the grace period, which are what Step 7 shows.

The rotation of the user's password. A Keystone user holds one password, so the old one stops at once and there is no grace period to check.

## Consequences

`make verify` takes longer on a sandbox with orders: the rotation alone waits for the 3m schedule and the 2m grace period, an estimated 6 to 8 minutes in all, not yet measured on a host. Its waits are bounded at 300 s for the scratch orders, 300 s, 180 s and 300 s for the steps of the rotation, and 180 s for each of the seven deletes.

On `controlplane` `make verify` runs 21 checks, on `identity` 7. A `ControlPlane` without an assigned namespace on the management cluster keeps the checks of its services alone.

A scratch order that a killed verify left behind lives in the owner's namespace until the next run of verify deletes it.

A namespace assignment added with `kubectl patch` is taken back by Flux at the next reconcile of `management-controlplane`; a further owner is a directory under `orders/` and an entry in `controlplane/components/orders/kustomization.yaml`. The example orders keep a field an owner raised by hand, while an order an owner applies with `kubectl` in `workflow` is theirs alone.

On the TLS bus the stage `management-orders` turns Ready with the vhost refused, so `make up PROFILE=identity` counts 11 stages Ready.
