# ADR-0013: Move the upstream pin by a scheduled pull request gated on validation

- Status: Accepted
- Date: 2026-11-24
- Source: D13 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

The sandbox vendors C5C3/cobaltcore at a commit pinned in `config.yaml` into `vendor/cobaltcore`, and its stages reference upstream by path and patch what differs ([ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md)). Upstream `main` moves on, and an evaluation on the sandbox runs against the pin it started with.

`make validate` renders every stage against the checkout of upstream, checks the result against the schemas, and checks that every patch still finds its target.

## Decision

The upstream pin moves by a scheduled pull request, and a passing validation is the gate. A scheduled workflow moves the pin to upstream `main`, runs `make validate` and opens a pull request, and a passing validation is the gate for merging it.

The pin stays close to upstream without changing under a running evaluation, and a break at render time is caught before the merge.

## Alternatives not taken

Moving the pin by hand. The pin would stay close to upstream only as often as someone moves it.

Following upstream `main` directly. Upstream would change under a running evaluation, and a break at render time would reach the sandbox without a gate.

## Consequences

A scheduled workflow moves the pin to upstream `main`, runs `make validate` and opens a pull request. The validation renders every stage, checks the result against the schemas and checks that every patch still finds its target.

How the pull request is opened and validated is recorded in [ADR-0017](0017-open-the-pin-pull-request-with-the-built-in-token.md).

The validation cannot see a break that only shows at run time, so `make up` records the pin it ran with.

Holding the pin is a change of one line.

[#5](https://github.com/C5C3/sandbox/issues/5) builds the validation and the scheduled workflow.
