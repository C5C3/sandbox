# ADR-0029: Install the system bus of the hypervisor nodes from the Debian archive

- Status: Proposed
- Date: 2026-11-26
- Source: [#16](https://github.com/C5C3/sandbox/issues/16), decided by the repository owner on 2026-11-26

## Context

Point 6 of the points to prove first runs the libvirt DaemonSet of upstream's lab and the kvm-node-agent on a kind node. The agent needs the system bus of its node. Its chart mounts the host path `/run/dbus/system_bus_socket` with type `Socket`, and the agent asks systemd over the bus at start and `systemd-hostnamed` when it sets up its controllers, and ends when either fails (`charts/kvm-node-agent/templates/daemonset.yaml`, `internal/systemd/systemd.go` and `internal/controller/hypervisor_controller.go` of [cobaltcore-dev/kvm-node-agent@1e4e4b8](https://github.com/cobaltcore-dev/kvm-node-agent/tree/1e4e4b8e7050bbfa2d5a990aa21b849ba7b51700), the commit of the pinned chart). The libvirt DaemonSet mounts `/run/dbus` and `/run/systemd` of the node, and its script starts libvirtd in a scope of the node's systemd. A node of the lab is a full Linux host with a bus. The kind node images carry systemd, `busctl`, `apt-get` and the sources of `deb.debian.org`, but no D-Bus daemon and no `/run/dbus`, as checked in `kindest/node` v1.37.0 and v1.34.0 on 2026-11-26.

## Decision

The command layer installs the package `dbus` in every worker node of `sandbox-compute` whose profile lists the module `node-prep`, and starts it. `node_bus` in `scripts/lib/nodes.sh` returns at once when systemd of the node answers on the bus. Otherwise it runs `apt-get update` and `apt-get install --no-install-recommends dbus` from the archive the node image names, which apt checks against the keyring of the image, and `systemctl start dbus.service`, because the `policy-rc.d` of the image keeps the package from starting it. It then waits up to `SANDBOX_NODE_TIMEOUT` seconds, by default 30, until systemd answers. A failed step stops `make up` with a message that names it. `ensure_node_prep` calls it for each worker from `hub_sync`, after the registration and before the wait for the stages, so apt runs while Flux applies them.

On the host on 2026-11-26 the node image, Debian 13 with systemd 257, got `dbus` 1.16.2, systemd joined the bus within the timeout, and the bus activated `systemd-hostnamed` for the agent.

## Alternatives not taken

A node image of the sandbox, built from `kindest/node` with `dbus`. It would start with a bus and need no egress to `deb.debian.org`, but the sandbox would build, store and move an image of its own with every kind release.

A bus run from a DaemonSet with stand-in units. It would leave the node image as it is, but the agent and libvirtd's script talk to the node's own systemd, which would have to join a bus that a pod runs, and the stand-ins would be a second implementation of what systemd serves on the bus.

The fallback of point 6 without a try: the DaemonSet of upstream's `tests/e2e-nova-libvirt`, without the kvm-node-agent and without migration TLS, which costs the live migration of milestone 6.

## Consequences

`make up` of a profile with `node-prep` needs `deb.debian.org` from the nodes, and the Network row of the host requirements names it. The version of `dbus` is the one of the archive at the time of the install; it is not pinned, and a failed install stops `make up` with a message that names the host. The package stays on the node when the module is taken off the profile and goes with `make down`. A later node image without `apt-get` or without the sources of the archive stops `make up` at the same message.
