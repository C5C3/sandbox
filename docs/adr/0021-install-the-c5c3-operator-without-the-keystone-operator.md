# ADR-0021: Install the c5c3-operator without the keystone-operator

- Status: Accepted
- Date: 2026-11-25
- Source: [#8](https://github.com/C5C3/sandbox/issues/8)

## Context

Upstream's release of the c5c3-operator (`vendor/cobaltcore/deploy/bases/controlplane-operator/helmrelease.yaml`) depends on four releases, the first of them the keystone-operator. The sandbox suspends the release of every service operator until its service is enabled, the keystone-operator until [#9](https://github.com/C5C3/sandbox/issues/9), and the helm-controller writes no status for a suspended release. A dependency on it never becomes ready, so the c5c3-operator would never be installed. The operator does not need the keystone-operator to start: it watches the Keystone kinds only once the cluster serves them, and restarts when they appear later.

## Decision

The module `platform` replaces `spec.dependsOn` of the release with its three other entries, in upstream's order: `external-secrets`, `mariadb-operator` and `memcached-operator`. The replacement is a patch of its own in `platform/operator/kustomization.yaml`, apart from the patch to one replica. The upstream side is tracked in [C5C3/cobaltcore#1876](https://github.com/C5C3/cobaltcore/issues/1876).

## Alternatives not taken

Lifting the suspension of the keystone-operator here. That is the work of [#9](https://github.com/C5C3/sandbox/issues/9), and it would run an operator without a service.

Waiting for C5C3/cobaltcore#1876. No module that needs the c5c3-operator could be built until upstream changes its release.

## Consequences

The c5c3-operator restarts once when the Keystone kinds are first served, after #9 enables the keystone-operator.

On the day upstream drops the dependency, the patch changes nothing, `make validate` reports it as dead, and it is deleted.
