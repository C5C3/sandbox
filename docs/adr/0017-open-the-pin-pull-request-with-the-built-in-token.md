# ADR-0017: Open the pin pull request with the built-in token

- Status: Accepted
- Date: 2026-11-24
- Source: [#5](https://github.com/C5C3/sandbox/issues/5), decided by the repository owner on 2026-11-24

## Context

A scheduled workflow moves the upstream pin and opens a pull request, and a passing validation is the gate for merging it ([ADR-0013](0013-move-the-upstream-pin-by-scheduled-pull-request.md)). The workflow needs a token that may push the branch `upstream-pin` and open its pull request.

C5C3/sandbox is a private repository. Its setting "Allow GitHub Actions to create and approve pull requests" is off, and without it the built-in `GITHUB_TOKEN` of a workflow cannot open a pull request. An event caused by `GITHUB_TOKEN` starts no workflow, except `workflow_dispatch` and `repository_dispatch`, so a pull request opened with that token starts no `pull_request` workflow.

## Decision

The workflow `upstream-pin` opens and updates the pull request with `GITHUB_TOKEN`, with the permissions `contents: write`, `pull-requests: write` and `actions: write`. The repository setting "Allow GitHub Actions to create and approve pull requests" is on. The workflow starts the workflow `validate` on the branch by `workflow_dispatch`, which runs its jobs on the head commit of the pull request.

## Alternatives not taken

A GitHub App token or a personal access token in a secret. The pull request would start the `pull_request` workflows itself, and the token is a credential to keep and rotate.

A branch without a pull request. It needs no setting and no token for pull requests, and it notifies nobody.

## Consequences

The repository and every fork of it switch the setting on. Without it, a run of `upstream-pin` pushes the branch and fails at `gh pr create`.

The setting also lets `GITHUB_TOKEN` approve pull requests, in every workflow of the repository, including a workflow that a collaborator pushes on a branch. The review that the protection of `main` requires must therefore be one that github-actions[bot] cannot give, such as the review of a code owner.

The checks of the pull request come from the dispatched run of `validate` on the branch, not from a `pull_request` event.
