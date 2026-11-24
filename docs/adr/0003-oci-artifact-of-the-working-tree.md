# ADR-0003: Serve the Flux source as an OCI artifact of the working tree from a local registry

- Status: Accepted
- Date: 2026-11-24
- Source: D3 of the [design decisions of the README at 546377a](https://github.com/C5C3/sandbox/blob/546377a144bd1cfe259721e052b65267b3ffca7c/README.md#design-decisions), accepted in [#2](https://github.com/C5C3/sandbox/issues/2)

## Context

Flux on the management cluster reconciles the stages of all three clusters of the sandbox ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md)) and needs a source to read them from.

C5C3/playground, whose repository shape the sandbox follows, syncs Flux from its Git repository on GitHub. The playground is a long-lived shared environment.

The sandbox runs on a single host and is rebuilt, not repaired. A change to it is tested on its own clusters, and a fork of the sandbox may have no access to a Git remote.

## Decision

The Flux source is an OCI artifact of the working tree in a local registry. A small registry container on the Docker network `cobaltcore-sandbox` holds the repository as an OCI artifact. `make push` packages the working tree and pushes it, and Flux follows the tag.

Changes are tested without a commit or a push to GitHub. The clusters hold no Git credentials.

## Alternatives not taken

Git sync from GitHub, as on the playground. It fits a long-lived shared environment, not a local sandbox.

## Consequences

`make push` packages the working tree and pushes it, and Flux follows the tag.

The registry runs as a container on the Docker network. The same registry can serve as a pull-through cache for the images the clusters pull.

A fork works without access to a Git remote.

The upstream checkout in `vendor/cobaltcore`, which Git ignores, travels inside the artifact, so the stages that reference it by path find it in the source Flux reads ([ADR-0004](0004-vendor-upstream-at-a-pinned-commit.md)).

[#3](https://github.com/C5C3/sandbox/issues/3) builds the registry, and [#4](https://github.com/C5C3/sandbox/issues/4) builds `make push`.
