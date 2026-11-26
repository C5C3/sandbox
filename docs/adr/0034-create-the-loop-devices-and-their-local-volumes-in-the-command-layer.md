# ADR-0034: Create the loop devices and their local volumes in the command layer

- Status: Proposed
- Date: 2026-11-26
- Source: [#12](https://github.com/C5C3/sandbox/issues/12)

## Context

Point 1 of the README: Rook brings up an OSD on a loop device offered as a static `volumeMode: Block` local volume inside a kind node ([Points to prove first](../../README.md#points-to-prove-first)). [ADR-0008](0008-one-storage-node-one-osd-single-replica-pools.md) puts the OSDs of `sandbox-storage` there, one by default, with the switches `osd-count` and `osd-size` for their number and the size of their sparse files. `sandbox-storage` has one node, `sandbox-storage-control-plane`, whose `/var` is a Docker volume, and the host check requires the kernel module `loop` for the storage role.

No manifest creates a file or attaches a loop device, and `losetup --find` hands out whichever device of the host is free. A kind node has no devtmpfs: Docker fills `/dev` of a privileged container once, at creation, so a loop device the kernel creates later has no node there, and `losetup` fails on it. kubelet holds every block volume open through a loop device of its own: it runs `losetup -f` on `<kubelet dir>/plugins/.../volumeDevices/<volume name>/<pod uid>` (`pkg/volume/util/volumepathhandler/volume_path_handler_linux.go` and `pkg/volume/local/local.go` of kubernetes/kubernetes@v1.37.0). So the node needs free loop devices beyond those of the OSDs, and a deleted node leaves kubelet's loop devices attached on the host, each holding an OSD file open. Nor does a kind node run udev: ceph-volume in the OSD prepare Job reads `/run/udev/data/b<major>:<minor>` of every block device of the host, partitions included, from `/run/udev` of the node, and the host run of this package found it failing with `RuntimeError: No udev data could be retrieved for /sys/block/loop0`, then for `/sys/block/nvme0n1/nvme0n1p1`, until each device had a record.

## Decision

`make up` creates the loop devices and one PersistentVolume per device, for exactly `osd-count` devices, and the module `block-devices` holds the StorageClass `sandbox-block` alone. The repository owner decided this on 2026-11-26.

`hub_sync` runs `ensure_block_devices` (`scripts/lib/storage.sh`) after `ensure_flux` and before `ensure_cluster_vars`, so a count the node cannot follow stops the run before the ConfigMap `cluster-vars` carries it to the stages. It does nothing unless `sandbox-storage` is attached and its modules list `block-devices`. Otherwise it works in `sandbox-storage-control-plane`:

- `loop_nodes` creates each missing device node `/dev/loop0` to `/dev/loop255` with `mknod`, and `/dev/loop-control` when the node lacks it, so `losetup` of the command layer and of kubelet finds a node for whatever free device the kernel hands out. The minor of `loop<n>` must be `<n>`, so it refuses a kernel whose `/sys/block/loop1/dev` exists and is not `7:1`, which is the case when `loop.max_part` is set.
- `udev_records` creates an empty udev record `/run/udev/data/b<major>:<minor>` for each block device of `/sys/class/block` and each loop device 0 to 255 that lacks one. ceph-volume reads nothing from an empty record but its existence; the loop devices kubelet attaches later have their record already.
- `block_device` keeps the device of a file that is attached. Otherwise it creates the sparse file `/var/lib/sandbox/osd-<index>.img` of `osd-size` with `truncate` and attaches it with `losetup --find --show`, up to five times one second apart, because another process of the host can take the free device first.
- `block_volume` prints the PersistentVolume `sandbox-osd-<index>`: `volumeMode: Block`, the capacity `osd-size`, the class `sandbox-block`, the policy `Retain`, the loop device as `local.path` and a node affinity to `sandbox-storage-control-plane`. `ensure_block_devices` applies it with `kubectl apply --server-side` and the field manager `sandbox`.

`ensure_block_devices` refuses a node with more OSD files than `osd-count`, or a file of another size than `osd-size`, with `run make down first`, as `make up` refuses another worker count: removing an OSD or resizing BlueStore is an operation on Ceph. It applies a higher count.

`make down` gains a first step. While the storage node runs, it detaches with `losetup -d` in the node the devices whose backing file contains `/volumeDevices/sandbox-osd-`, kubelet's, and then those whose backing file starts with `/var/lib/sandbox/osd-`. Its final check reads `/sys/block/loop*/loop/backing_file` and reports each device on such a file as left over.

On the host on 2026-11-26, `make up` created `/var/lib/sandbox/osd-0.img` with an apparent size of 10737418240 bytes and 0 blocks allocated, attached it to `/dev/loop0`, whose `backing_file` under `/sys/block` of the host named that path, and created the PersistentVolume `sandbox-osd-0`. A second `make up` attached nothing, and `make down` detached the device and left nothing.

## Alternatives not taken

Three fixed volumes in the module, with three devices in every profile. A fixed volume names a fixed loop device, while `losetup --find` hands out whichever device is free on the host, and a module cannot turn the count of `osd-count` into a number of objects. Every profile would also carry three files and three devices, where the default is one OSD.

The host's `/dev` mounted into the node. It gives the node every device of the host, its disks among them, where the node needs loop device nodes alone, which `mknod` creates in a running node.

A block-capable provisioner, the second fallback of point 1 of the README. It is a fallback for a failed point, which changes what the package builds and which the owner confirms first ([When a point to prove fails](README.md#when-a-point-to-prove-fails)). The local-path provisioner of kind has no block mode, so it would add a provisioner to the storage cluster.

## Consequences

`make up` of a profile with `block-devices` logs `preparing the loop devices of sandbox-storage: <count> of <size>` and one line `attaching <file> to <device> on sandbox-storage-control-plane` per new device. A second run finds every device, applies the same volumes and changes nothing. After a raised `osd-count`, `make up` can return before Rook has added the OSDs.

The module `ceph-cluster` reads the count and the size as `SWITCHES_OSD_COUNT` and `SWITCHES_OSD_SIZE` of `cluster-vars`, so its device set asks for one claim per volume, of the volume's size.

The files are sparse, so 10 GiB costs what Ceph writes. `Retain` keeps a volume and its file when the claim goes, and `make down` removes both with the node. Devices of an earlier profile stay until `make down`.

A kernel with `loop.max_part` set stops `make up` with `block-devices: the loop devices of this kernel do not number their minors by index (loop.max_part is set), <node> reads <value> for loop1`.

An OSD still holds its device when the first step of `make down` runs, so the kernel detaches that device when the node stops. A storage node deleted or stopped outside `make down` leaves its loop devices on the host, kubelet's among them, each holding an OSD file open. `make down` runs no `sudo` and reports each as `left over: loop device /dev/<name> on <backing file>; detach it with sudo losetup -d /dev/<name>`.
