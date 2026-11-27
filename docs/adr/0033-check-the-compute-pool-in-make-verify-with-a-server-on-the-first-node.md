# ADR-0033: Check the compute pool in make verify with a server on the first node

- Status: Proposed
- Date: 2026-11-26
- Source: [#17](https://github.com/C5C3/sandbox/issues/17)

## Context

Milestone 4 of PLAN.md is done when Part 2, Steps 1 to 5 of upstream's Quick Start (metal-stack) pass on one node, and of Step 6 the metadata call and the noVNC console: a `Hypervisor` onboarded, the pool Ready, a server `ACTIVE`. The quick start runs these by hand. `make verify` runs the checks of the services the ControlPlane declares and the checks of the orders ([ADR-0025](0025-check-the-orders-with-scratch-orders-and-a-scheduled-rotation.md)), and reads the hub only. The `Hypervisor` objects live on the compute cluster. The lab has no provider network, so a server is reached through its console only.

## Decision

`scripts/lib/compute.sh` adds eight checks to `make verify`, after those of the services and before those of the orders, whenever a `NovaCompute` in `openstack` names the registration `sandbox-compute`: `compute-pool`, `compute-chassis`, `compute-metadata-agent`, `compute-hypervisor`, `compute-network`, `compute-server`, `compute-metadata` and `compute-console`.

- The pool's checks read the `NovaCompute`, `OVNChassis` and `NeutronMetadataAgent` objects on the hub and the agents Neutron lists. `compute-hypervisor` is the one check that leaves the hub: it reads the `Hypervisor` of each node on `sandbox-compute` with the kubeconfig file of the role, and the aggregate of the node's zone in Nova.
- `compute-network` creates `sandbox-verify-compute-net` and checks its MTU of 1442. `compute-server` boots `sandbox-verify-compute-server` from the image `cirros-kvm` and the flavor `1` of the module `hypervisor-fixtures` on that network, with `--availability-zone <zone>:<node>` for the first node of the pool, and waits up to 600 s for it to turn `ACTIVE`.
- `compute-metadata` reads the server's console log until cirros 0.6 reports the instance id it read from the metadata service, `successful after <n>/20 tries: up <seconds>. iid=<id>`, and fails at once on `failed to read iid from metadata`.
- `compute-console` reads the noVNC URL, gets its page without the query with curl and the sandbox CA, and opens a WebSocket to the console proxy with `openssl s_client`: the upgrade request for the path the URL's parameter `path` names reaches openssl on stdin, which stays open for 5 s, and the check passes on a `101` status line and the bytes `RFB 003.`, which a server frame carries unmasked. The console token is never an argument of a command or a line of the output.

A check whose input an earlier check failed to create reports `FAIL <id>: skipped, <earlier id> failed`, so the count stays eight. The waits are bounded: 600 s for each onboarding, 600 s for the boot of the server, whose status the check reads every 2 s because the `--wait` of `openstack server create` has no bound, and 300 s for the console log. Before `compute-network` the checks delete what an earlier run left of their names, and after `compute-console` what they created, also after a failure.

## Alternatives not taken

A WebSocket client beside `curl` and `openssl`, such as `websocat` or a Python script. It adds a host requirement for one check.

The console URL alone, or its page alone. Neither shows that the proxy reaches the VNC of a node on another cluster, interface 7 of PLAN.md.

A ping or an SSH login to the server. The lab has no provider network and the sandbox no floating IPs.

## Consequences

`make verify` needs `openssl` beside `curl`. On the host test's profile it reports 18 checks: the ten of Keystone, Glance, Placement, Neutron and Nova and the eight of the pool. The compute checks add the boot of one cirros server to its run time, and up to 600 s for a node that does not onboard.

The check of the console relies on the RFB greeting arriving within 5 s of the upgrade, and the check of the metadata on the strings of cirros 0.6, the version of the fixture image.
