# The read half of the key hand-off for libvirt on the compute cluster: the
# role read-ceph-client-cinder on kubernetes/hypervisor binds it to the
# ServiceAccount openstack/ceph-keys-read there. It reads the cinder key and
# nothing else; upstream's eso-hypervisor grants ceph/client-nova instead
# (C5C3/cobaltcore#1901).

path "kv-v2/data/ceph/client-cinder" {
  capabilities = ["read"]
}
