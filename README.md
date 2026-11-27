# CobaltCore OpenStack Sandbox

A modular sandbox for evaluating
[CobaltCore OpenStack](https://github.com/C5C3/cobaltcore) on a single Linux
host. It rebuilds the lab of the upstream
[Quick Start (metal-stack)](https://c5c3.github.io/cobaltcore/quick-start-metal-stack.html)
on [kind](https://kind.sigs.k8s.io/) clusters: one for management and the
control plane, one for storage (Ceph), one for compute (KVM).

The idea for this sandbox and its implementation come out of the
[IPCEI-CIS Hackathon Potsdam](https://apeirora.eu/content/news/apeirora-ipcei-cis-hackathon/)
of the IPCEI-CIS and NeoNephos community, November 24 to 26, 2026.

> **Status: milestones 0 to 4 built, 5 to 7 open**, see
> [#2](https://github.com/C5C3/sandbox/issues/2). The design, the milestones
> and the details of every module are in [PLAN.md](PLAN.md), the decisions
> in [docs/adr/](docs/adr/README.md).

This quick start brings up the profile `controlplane`: Keystone, Glance,
Placement, Barbican, Neutron, Cinder, Nova and Horizon on one kind cluster,
with Cinder on NFS and a fake compute. Then it shows the OpenStack CLI,
Horizon and a first server, and at the end a server on a real KVM
hypervisor.

## Contents

- [Host requirements](#host-requirements)
- [1. Start the sandbox](#1-start-the-sandbox)
- [2. Use the OpenStack CLI](#2-use-the-openstack-cli)
- [3. Log in to Horizon](#3-log-in-to-horizon)
- [4. Create a server](#4-create-a-server)
- [5. A server on a KVM hypervisor](#5-a-server-on-a-kvm-hypervisor)
- [6. Tear down](#6-tear-down)
- [Profiles](#profiles)
- [Commands](#commands)
- [Troubleshooting](#troubleshooting)

## Host requirements

| Requirement | Detail |
| --- | --- |
| Host | Linux on x86-64 with cgroup v2 and rootful Docker |
| Memory | 16 GiB or more. `controlplane` works in about 10 GiB |
| Disk | About 60 GB free, an estimate. Every kind node keeps its own image store |
| Kernel | `fs.inotify.max_user_instances` at 512 or more, the modules `nfs` and `nfsv4` for `controlplane`. For the KVM hypervisor also `/dev/kvm` and the modules `openvswitch`, `geneve` and `vhost_net` |
| Tools | `docker`, `kind`, `kubectl`, `helm`, `flux`, `git`, `yq` v4.40.1 or newer, `jq`, `make`, `curl`, `openssl` |
| OpenStack CLI | `python-openstackclient` with `osc-placement` and `python-barbicanclient`. It brings the `cinder` CLI of `python-cinderclient` along |
| DNS | The host's resolver answers `*.nip.io` names with private addresses |
| Network | Egress to GitHub, the container registries (`ghcr.io`, `quay.io`, `docker.io`, `registry.k8s.io`), the Helm repositories and, for the KVM hypervisor, `deb.debian.org` |

The full list, with the reason for each item, is in
[PLAN.md](PLAN.md#host-requirements).

```bash
sudo sysctl -w fs.inotify.max_user_instances=512

python3 -m venv ~/.venvs/openstack
~/.venvs/openstack/bin/pip install python-openstackclient osc-placement python-barbicanclient
export PATH=$HOME/.venvs/openstack/bin:$PATH

scripts/preflight.sh management               # checks the host, creates nothing
getent hosts keystone.172-30-255-10.nip.io    # must print 172.30.255.10
```

If `getent` prints nothing, the resolver drops private answers. Set
`switches.resolver-fallback: true` in `config.yaml`; `make up` then prints
the two commands that route the host's `nip.io` lookups to the sandbox.

All addresses come from [`config.yaml`](config.yaml). With the defaults,
every service is published on the Gateway address `172.30.255.10`, as
`https://<service>.172-30-255-10.nip.io`.

## 1. Start the sandbox

```bash
SANDBOX_STAGE_TIMEOUT=3600 make up PROFILE=controlplane
```

`make up` checks the host, creates the Docker network `cobaltcore-sandbox`,
a local registry and the kind cluster `sandbox-management`, installs Flux
and waits until every stage of the profile is Ready. The first run pulls the
images of all eight services and can take longer than the default wait
of 600 s, hence `SANDBOX_STAGE_TIMEOUT`. If it stops anyway, a second
`make up PROFILE=controlplane` continues where the first one stopped.

At the end it prints the kubeconfig of the cluster:

```bash
export KUBECONFIG=$PWD/.sandbox/kubeconfig/management.yaml
make status                            # Flux, the source and every stage, Ready or not
kubectl -n openstack get controlplane  # the ControlPlane of all eight services
make verify                            # the checks of upstream's Quick Start (ControlPlane)
```

`make verify` runs 21 checks on `controlplane`, from a Keystone token to a
Horizon login, and ends with `verify: 21 of 21 checks passed`. The checks
of the orders add an estimated 6 to 8 minutes.

## 2. Use the OpenStack CLI

```bash
eval "$(make --no-print-directory env)"
openstack token issue
openstack catalog list
openstack compute service list
openstack volume service list
```

`make env` prints the `OS_*` variables of the user `admin` as `export`
lines and writes the CA of the sandbox to `.sandbox/sandbox-ca.pem`, which
`OS_CACERT` names. The CLI verifies every certificate; no `--insecure` is
needed.

## 3. Log in to Horizon

Open <https://horizon.172-30-255-10.nip.io> and log in:

| Field | Value |
| --- | --- |
| Domain | `Default` |
| User name | `admin` |
| Password | `printf '%s\n' "$OS_PASSWORD"` after step 2 |

The browser does not know the CA of the sandbox. Either accept the warning,
or import `.sandbox/sandbox-ca.pem` as a certificate authority (Firefox:
Settings, Privacy & Security, View Certificates, Authorities, Import). The
CA is name-constrained to `nip.io`, so the browser trusts it for no other
name. Each new
sandbox creates a new CA, so import it again after `make down`.

The addresses live on a Docker network of the host and are reachable from
the host only. From another machine, route the subnet through SSH, or open
a SOCKS proxy for the browser:

```bash
sshuttle -r <user>@<host> 172.30.0.0/16   # route the Docker subnet
ssh -D 1080 <user>@<host>                 # SOCKS proxy on localhost:1080
```

## 4. Create a server

In `controlplane`, Nova runs a fake compute: the scheduler places a server
and it turns `ACTIVE`, but no VM runs. The fake compute has no OVN chassis,
and Neutron's OVN driver binds a port only on a host with one, so the server
boots without a network, as in `make verify`. A real VM is
[step 5](#5-a-server-on-a-kvm-hypervisor).

```bash
curl -fLO https://github.com/cirros-dev/cirros/releases/download/0.6.3/cirros-0.6.3-x86_64-disk.img
openstack image create --disk-format qcow2 --container-format bare --public \
  --file cirros-0.6.3-x86_64-disk.img cirros
openstack flavor create --vcpus 1 --ram 128 --disk 1 m1.tiny

# The CLI speaks compute API 2.1 by default and refuses --nic none below 2.37.
openstack --os-compute-api-version 2.37 server create \
  --image cirros --flavor m1.tiny --nic none --wait demo
openstack server list
```

The other services work beside it:

```bash
openstack network create demo-net
openstack subnet create --network demo-net --subnet-range 192.0.2.0/24 demo-subnet
openstack volume create --size 1 demo-volume
openstack secret store --name demo-secret --payload 'hello sandbox'
openstack resource provider list
```

Everything created here shows in Horizon as well, under Project and Admin.

## 5. A server on a KVM hypervisor

The profile `full`, with servers on KVM and RBD volumes, is not built yet
([#18](https://github.com/C5C3/sandbox/issues/18)). Until then, the profile
of the host test `tests/host/compute-pool.bats` runs a real hypervisor:
Keystone, Glance, Placement, Neutron and Nova on the TLS message bus of
`sandbox-management`, and one KVM hypervisor node on the cluster
`sandbox-compute`. It has no Horizon.

It runs on a different message bus than `controlplane`, and a running
`ControlPlane` cannot change its bus, so tear the sandbox down first. The
profile lives outside the tree, in a directory that
`SANDBOX_PROFILE_DIR` names:

```bash
make down
scripts/preflight.sh management compute    # /dev/kvm and the modules of the hypervisor
mkdir -p ~/sandbox-profiles
cat >~/sandbox-profiles/kvm.yaml <<'EOF'
clusters: [management, compute]
modules:
  management: [crds, controllers, loadbalancer, pki, gateway, openbao, objectstore, platform, sizing, messaging-tls, controlplane, placement, neutron, nova, remote-compute, hypervisor-fixtures, compute-pool]
  compute: [access, controllers, node-prep, trust, libvirt, kvm-node-agent, hypervisor-operator]
switches:
  glance: true
EOF
SANDBOX_PROFILE_DIR=$HOME/sandbox-profiles SANDBOX_STAGE_TIMEOUT=3600 make up PROFILE=kvm
```

After `make up`, the hypervisor operator onboards the node. `make verify`
runs 18 checks here: it waits up to 600 s for the onboarding, then boots a
server of its own, checks it and deletes it.

```bash
export KUBECONFIG=$PWD/.sandbox/kubeconfig/management.yaml
eval "$(make --no-print-directory env)"
make verify
openstack hypervisor list

openstack network create demo-net
openstack subnet create --network demo-net --subnet-range 198.51.100.0/24 demo-subnet
openstack server create --image cirros-kvm --flavor 1 --network demo-net --wait demo-vm
openstack console log show demo-vm
openstack console url show --novnc demo-vm
```

The image `cirros-kvm` and the flavor `1` come with the profile. The noVNC
URL opens in the browser under `https://nova-console.172-30-255-10.nip.io`,
with the same CA as Horizon; cirros logs in as `cirros` with the password
`gocubsgo`. The sandbox has no provider network and no floating IPs, so the
console is the way into a server.

## 6. Tear down

```bash
make down
```

`make down` deletes the clusters, the registry, the Docker network, the loop
devices of the storage cluster and `.sandbox/`. The sandbox does not survive
a host reboot or a restart of Docker; `make down` and `make up` build it
again.

## Profiles

`make up PROFILE=<name>` reads `profiles/<name>.yaml`. Without `PROFILE`,
`make up` runs `scaffold`.

| Profile | Clusters | What runs |
| --- | --- | --- |
| `scaffold` | management, storage, compute | A test stage on each cluster: Flux reaches all three |
| `gateway` | management, storage, compute | The Gateway on port 443 with the sandbox CA |
| `platform` | management | `gateway` plus OpenBao, External Secrets, Garage and the c5c3-operator |
| `identity` | management | Keystone on the TLS message bus and the orders of the owner `workflow` |
| `controlplane` | management | All eight services, Cinder on NFS, a fake compute, the orders |
| `storage` | management, storage | Keystone and Cinder on the Ceph of the storage cluster, the Ceph keys handed over through OpenBao |
| `full`, `parity` | management, storage, compute | Planned: [#18](https://github.com/C5C3/sandbox/issues/18), [#20](https://github.com/C5C3/sandbox/issues/20) |

The switches in `config.yaml` add parts, such as `cinder-backup` to
`storage`, or change sizes, such as `osd-count` and `hypervisor-nodes`. A
profile can set them too. `CONFIG=<file>` selects another configuration
file. What each profile runs and evaluates is in
[PLAN.md](PLAN.md#profiles).

## Commands

| Command | Does |
| --- | --- |
| `make up PROFILE=<name>` | Creates or updates the sandbox and waits until it is Ready |
| `make up-management`, `make up-storage`, `make up-compute` | The same for one cluster |
| `make push` | Publishes the working tree to Flux without waiting, after a change to a manifest |
| `make status` | Flux, the source, the roots and the stages, per cluster |
| `make env` | The `OS_*` variables of `admin` as `export` lines; writes `.sandbox/sandbox-ca.pem` |
| `make verify` | The checks of the services that run; exits 1 when one fails |
| `make footprint` | Memory requests and working set, per cluster |
| `make down` | Deletes everything `make up` created |
| `make vendor` | Checks out upstream at the pin of `config.yaml` into `vendor/cobaltcore` |
| `make validate` | Renders every root and stage against `vendor/cobaltcore` |
| `make test`, `make test-validate`, `make test-host` | The tests of the command layer; `test-host` builds real sandboxes and takes hours |

A changed profile is applied by `make up`, not by `make push`. The details,
timeouts and environment variables are in
[PLAN.md](PLAN.md#planned-command-surface).

## Troubleshooting

- **A stage is not Ready.** `make status` names it with the message of its
  Ready condition. After a timeout, run `make up` again.
- **The CLI or `make verify` cannot resolve a name.** See the `getent` check
  under [Host requirements](#host-requirements).
- **`management-openbao` is not Ready after the pod `openbao-0`
  restarted.** OpenBao is sealed, and nothing unseals it by itself. Running
  its bootstrap Job again unseals it, see
  [PLAN.md](PLAN.md#the-shared-openbao):

  ```bash
  kubectl -n shared-services delete job openbao-bootstrap
  flux -n flux-system reconcile kustomization management-openbao
  ```
- **The host rebooted or Docker restarted.** Run `make down` and `make up`.
