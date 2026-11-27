# ADR-0020: Unseal the shared OpenBao once with upstream's scripts

- Status: Accepted
- Date: 2026-11-25
- Source: [#8](https://github.com/C5C3/sandbox/issues/8), decided by the repository owner on 2026-11-25

## Context

The shared OpenBao of the management cluster starts uninitialised and sealed, and every ExternalSecret of the sandbox reads through it. The stage that runs it therefore has to initialise, unseal and configure it, with no step typed by hand after `make up`. The README named two models for that step, upstream's bootstrap scripts and the Job of the playground, and they unseal differently. Upstream's `init-unseal.sh` initialises with Shamir shares, keeps the shares and the root token in the Secret `openbao-init-keys` and unseals each pod from it. Upstream leaves running the scripts to the repository that deploys its bases (`vendor/cobaltcore/deploy/README.md`). The playground configures a static seal key, so that OpenBao unseals itself after a restart, and initialises with recovery keys of its own.

Upstream holds the one-replica settings of the server as a patch in `deploy/bases/devstack/base`, a kustomization that also installs every operator, and kustomize cannot import a patch.

## Decision

The module `openbao` runs upstream's release `shared-services/openbao` on one replica, with upstream's one-replica settings restated as a patch, and the Job `openbao-bootstrap` in the same stage. The Job runs `infrastructure/openbao/bootstrap.sh`. It waits until `openbao-0` answers, runs upstream's `init-unseal.sh` with 5 Shamir shares and threshold 3, then `setup-secret-engines.sh`, `setup-auth.sh`, `setup-policies.sh` and `write-bootstrap-secrets.sh` with the root token from the Secret, and annotates the `ClusterSecretStore` `openbao-cluster-store` so that External Secrets validates it at once.

The Job runs once. Flux creates it again when a ConfigMap it mounts changes its name. Nothing unseals OpenBao after a restart of its pod: PLAN.md names the symptom and the two commands that run the Job again.

## Alternatives not taken

A static seal key, as on the playground. It needs a `seal` stanza in the configuration of the server and an initialisation of the sandbox's own, which a move of the pin does not update.

A CronJob that runs `init-unseal.sh` every few minutes. It would unseal after a restart without a command, but it starts a pod that reads the unseal keys for as long as the sandbox runs.

## Consequences

After a restart of `openbao-0`, OpenBao stays sealed until the Job is deleted and the stage reconciled, as the section "The shared OpenBao" of PLAN.md describes. The sandbox is rebuilt, not repaired, so this is the one repair it documents.

The restated patch in `infrastructure/openbao/kustomization.yaml` is compared with upstream's patch at each move of the pin. `make validate` reports it only once it changes nothing.

All five shares and the root token sit in one Secret, `shared-services/openbao-init-keys`, which the Role of the Job reads and deletes by name. Whoever can read Secrets in `shared-services` can unseal OpenBao and act as its root.
