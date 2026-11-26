# ADR-0032: Release the hypervisor operator from the hub with a copy of its auth Secret

- Status: Proposed
- Date: 2026-11-26
- Source: [#17](https://github.com/C5C3/sandbox/issues/17)

## Context

Points 7 and 9 of the README: the openstack-hypervisor-operator (hvo) onboards a node across the cluster boundary, and Flux on the management cluster releases it on `sandbox-compute` with values from a Secret on the management cluster. The ControlPlane writes hvo's account, seven keys with a cloud-admin password, into `openstack/controlplane-nova-hypervisor-operator-auth`. Upstream's release (`deploy/overlays/metal-stack/hypervisor/hvo-release.yaml`) sits in `openstack` beside that Secret, because `valuesFrom` reads only the namespace of the release; so does `spec.kubeConfig`. The other releases for the compute cluster live in `flux-system` of the hub with the Secret `kubeconfig-compute` ([ADR-0026](0026-release-a-vendored-chart-through-an-artifactgenerator-on-the-hub.md)).

For a `Hypervisor` with `evacuateOnReboot: true`, the CRD's default, the kvm-node-agent asks logind for its shutdown inhibitors over the system bus of the node ([ADR-0029](0029-install-the-system-bus-of-the-hypervisor-nodes-from-the-debian-archive.md)), and the pull request of [#16](https://github.com/C5C3/sandbox/issues/16) found logind inactive on the worker. On 2026-11-26 a probe in a container of `kindest/node` v1.37.0 with `dbus` installed as `node_bus` does found the first call to `org.freedesktop.login1` start `systemd-logind.service` through bus activation.

## Decision

The module `hypervisor-operator` puts every object onto the hub and all but one Role and its RoleBinding into `flux-system`: upstream's `OCIRepository` unchanged, and the `HelmRelease` `compute-hypervisor-operator`, which installs the chart in `openstack` on `sandbox-compute` through `kubeconfig-compute`, with the release history there. An `ExternalSecret` copies the auth Secret from `openstack` into `flux-system` under the same name, every 5 minutes, through a `SecretStore` of the provider `kubernetes` whose ServiceAccount may `get` that one Secret, as the transport URL Secrets of the module `messaging-tls` do. The copy carries the label `reconcile.fluxcd.io/watch: Enabled`, so helm-controller upgrades the release when it changes.

The release reads upstream's six entries of `valuesFrom` and `auth_url`, the public Keystone of the Gateway, as step 7 of upstream's guide Connect a Compute Cluster maps them, and keeps upstream's values but `osAuthUrl`, `serviceMonitor.enabled` and `prometheusRules.create`: the ServiceMonitor and the PrometheusRules, which upstream turns on, are off because the compute cluster has no Prometheus Operator, and the dashboards and the custom-resource metrics stay off as upstream has them. Its post-renderer keeps upstream's `imagePullPolicy: Always` and `--default-high-availability=false` and adds the sandbox CA ([ADR-0031](0031-carry-the-sandbox-ca-to-a-compute-cluster-through-the-command-layer.md)). It sets no `OS_INTERFACE`, so the patched image reads the public catalog rows. Install and upgrade are retried three times, as for the releases of `compute/controllers`, so a first wait that runs out on a slow pull does not leave the release failed.

The stage `compute-hypervisor-operator` waits for the release after `compute-libvirt`, whose Issuer signs the libvirt certificates, `compute-trust` and `management-hypervisor-fixtures`, without which hvo exits at start. It has no edge to the stage of the pool, and the pool's stage none to it: upstream applies both at once, and a `NovaCompute` is Ready only once `nova-compute` runs, which waits for libvirtd, which waits for the TLS files of the `Hypervisor` hvo creates.

The system bus of the node stays as ADR-0029 installs it. On the first host run, hvo at its pinned commit created the `Hypervisor` with `evacuateOnReboot: false`, so the agent asks logind for nothing, and libvirtd started logind through bus activation when it started; `tests/host/compute-pool.bats` asserts that logind is active on the worker.

## Alternatives not taken

The `HelmRelease` in `openstack` of the management cluster, beside the auth Secret. It would need the cluster-admin kubeconfig of `sandbox-compute` in the namespace the CobaltCore operators read; the author declined it on 2026-11-26.

The password as a Flux variable of the release. It would put a cloud-admin password into a ConfigMap.

Flux on the compute cluster. It costs the memory one Flux saves ([ADR-0002](0002-flux-on-the-management-cluster-as-hub.md)).

An edge from the pool's stage to hvo's. With the pool's stage waiting for a Ready pool, it would wait for a Hypervisor nobody creates yet.

## Consequences

The cloud-admin password of hvo exists twice on the hub, in `openstack` and in `flux-system`, where the kubeconfig Secrets of Flux already live. The copy follows its source within 5 minutes, and helm-controller then restarts hvo with it; no check rotates the account.

Taking the module off deletes the `ExternalSecret`, whose Secret goes with it as its owner, and the release, which Helm uninstalls on `sandbox-compute`.

Point 7 and the part of point 9 for hvo are proven by `tests/host/compute-pool.bats` on a host.
