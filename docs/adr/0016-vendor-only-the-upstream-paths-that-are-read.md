# ADR-0016: Vendor only the upstream paths that are read

- Status: Accepted
- Date: 2026-11-24
- Source: [#5](https://github.com/C5C3/sandbox/issues/5), decided by the repository owner on 2026-11-24

## Context

`make vendor` checks out C5C3/cobaltcore at the commit pinned in `config.yaml` into `vendor/cobaltcore` ([ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md)). The checkout travels in every OCI artifact of the working tree ([ADR-0003](0003-oci-artifact-of-the-working-tree.md)), which `make up` and `make push` push and the kustomize-controller fetches for each stage.

At the pin `15a0323e`, the whole tree of upstream is 70 MB in 6,474 files. The sandbox reads two parts of it: the bases under `deploy/`, on which its stages build, and the CRDs under `operators/*/config/crd/bases/`, against which `make validate` checks the objects of upstream's kinds. These two are 6.9 MB in 280 files.

## Decision

The checkout is a sparse checkout of the two patterns in `SANDBOX_VENDOR_PATHS` of `scripts/lib/vendor.sh`, `/deploy/` and `/operators/*/config/crd/bases/`. `make vendor` fetches the pinned commit at depth 1 and without the content of the files outside the patterns.

## Alternatives not taken

The whole repository. It needs no list of paths, and it puts 70 MB into every push.

## Consequences

A module that reads another path of upstream adds its pattern to `SANDBOX_VENDOR_PATHS`, and `make vendor` then fetches it. Until the pattern is there, the path is missing from the checkout, and `make validate` fails on the stage that reads it.
