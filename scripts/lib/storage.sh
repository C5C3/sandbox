# shellcheck shell=bash
# The block devices of sandbox-storage, which no manifest can create: one
# sparse file per OSD in the storage node, a loop device over each, and one
# static PersistentVolume with volumeMode Block per device, which the module
# block-devices offers to Rook through the StorageClass sandbox-block
# (ADR-0034). Source scripts/lib/common.sh, scripts/lib/profile.sh and
# scripts/lib/hub.sh first.
#
# A kind node has no devtmpfs: Docker fills /dev of the node once, when it
# creates the container, so a loop device the kernel creates later has no
# node there. kubelet holds every block volume open through a loop device of
# its own, so the node needs device nodes beyond those of the OSDs. Nor does
# a kind node run udev, whose records ceph-volume reads.

# storage_node: prints the node of sandbox-storage.
storage_node() {
	printf '%s-control-plane\n' "$(cluster_name storage)"
}

# loop_nodes <node>: creates in the node each missing device node /dev/loop0
# to /dev/loop255, so losetup of the command layer and of kubelet finds a
# node for whatever free device the kernel hands out, and /dev/loop-control
# when the node lacks it, as on a host that had not loaded loop when the node
# was created. The minor of loop<n> must be <n>, so it first reads
# /sys/block/loop1/dev and fails when the file exists and is not 7:1, which
# is the case when loop.max_part is set.
loop_nodes() {
	local node=$1 out script='' i
	local -A present=()
	out=$(docker exec "$node" sh -c 'if [ -e /sys/block/loop1/dev ]; then cat /sys/block/loop1/dev; fi' 2>&1) ||
		die "block-devices: cannot create the loop device nodes on $node: $(_last_line "$out")"
	if [ -n "$out" ] && [ "$out" != 7:1 ]; then
		die "block-devices: the loop devices of this kernel do not number their minors by index (loop.max_part is set), $node reads $out for loop1"
	fi
	out=$(docker exec "$node" ls /dev 2>&1) ||
		die "block-devices: cannot create the loop device nodes on $node: $(_last_line "$out")"
	for i in $out; do
		present[$i]=1
	done
	if [ -z "${present[loop-control]:-}" ]; then
		script+=$'mknod -m 660 /dev/loop-control c 10 237\n'
	fi
	for ((i = 0; i < 256; i++)); do
		if [ -z "${present[loop$i]:-}" ]; then
			script+="mknod -m 660 /dev/loop$i b 7 $i"$'\n'
		fi
	done
	[ -n "$script" ] || return 0
	out=$(docker exec "$node" sh -ec "$script" 2>&1) ||
		die "block-devices: cannot create the loop device nodes on $node: $(_last_line "$out")"
}

# udev_records <node>: creates in the node an empty udev record
# /run/udev/data/b<major>:<minor> for each block device of /sys/class/block
# and for each loop device 0 to 255 that lacks one. ceph-volume in the OSD
# prepare Job reads the record of every block device of the host, partitions
# included, from /run/udev of the node and fails without it, and a kind node
# runs no udev. The loop devices kubelet attaches later have a record
# already; a device the host adds after make up gets one at the next run.
udev_records() {
	local node=$1 out record script='' i
	local -a records=()
	local -A present=()
	out=$(docker exec "$node" sh -c 'for f in /sys/class/block/*/dev; do cat "$f"; done' 2>&1) ||
		die "block-devices: cannot create the udev records on $node: $(_last_line "$out")"
	for record in $out; do
		records+=("b$record")
	done
	for ((i = 0; i < 256; i++)); do
		records+=("b7:$i")
	done
	out=$(docker exec "$node" sh -c 'if [ -d /run/udev/data ]; then ls /run/udev/data; fi' 2>&1) ||
		die "block-devices: cannot create the udev records on $node: $(_last_line "$out")"
	for record in $out; do
		present[$record]=1
	done
	for record in "${records[@]}"; do
		if [ -z "${present[$record]:-}" ]; then
			present[$record]=1
			script+=": >/run/udev/data/$record"$'\n'
		fi
	done
	[ -n "$script" ] || return 0
	out=$(docker exec "$node" sh -ec "mkdir -p /run/udev/data"$'\n'"$script" 2>&1) ||
		die "block-devices: cannot create the udev records on $node: $(_last_line "$out")"
}

# block_device <node> <index>: prints the loop device of
# SANDBOX_OSD_DIR/osd-<index>.img in the node. A file that is attached keeps
# its device. Otherwise it creates the directory and the sparse file of
# SANDBOX_OSD_SIZE and attaches it, up to five times one second apart,
# because another process of the host can take the free device first. The
# line attaching ... goes to stderr, because the caller reads the device from
# stdout.
block_device() {
	local node=$1 file=$SANDBOX_OSD_DIR/osd-$2.img out device i
	out=$(docker exec "$node" losetup --list --noheadings --output NAME --associated "$file" 2>&1) ||
		die "block-devices: cannot attach $file on $node: $(_last_line "$out")"
	device=$(_first_line "$out")
	if [ -n "$device" ]; then
		printf '%s\n' "$device"
		return 0
	fi
	out=$(docker exec "$node" mkdir -p "$SANDBOX_OSD_DIR" 2>&1 &&
		docker exec "$node" truncate -s "${SANDBOX_OSD_SIZE%Gi}G" "$file" 2>&1) ||
		die "block-devices: cannot create $file on $node: $(_last_line "$out")"
	for ((i = 1; ; i++)); do
		if out=$(docker exec "$node" losetup --find --show "$file" 2>&1); then
			break
		fi
		[ "$i" -lt 5 ] || die "block-devices: cannot attach $file on $node: $(_last_line "$out")"
		sleep 1
	done
	device=$(_last_line "$out")
	log "attaching $file to $device on $node" >&2
	printf '%s\n' "$device"
}

# block_volume <index> <device>: prints the PersistentVolume of the OSD
# file with the index, the loop device in the storage node, of
# SANDBOX_OSD_SIZE in the StorageClass sandbox-block.
block_volume() {
	cat <<EOT
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $SANDBOX_OSD_VOLUME-$1
  labels:
    sandbox.c5c3.io/cluster: storage
spec:
  capacity:
    storage: $SANDBOX_OSD_SIZE
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: sandbox-block
  local:
    path: $2
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$(storage_node)]
EOT
}

# ensure_block_devices: when cluster_modules lists block-devices for storage
# and sandbox-storage is attached, gives the storage node its device nodes
# and udev records and SANDBOX_OSD_COUNT OSD files of SANDBOX_OSD_SIZE, each
# on a loop device, and applies the PersistentVolume of each. It refuses a
# node with more OSD files than the count or a file of another size:
# removing an OSD or resizing BlueStore is an operation on Ceph, and the
# sandbox is rebuilt with make down. Devices of an earlier profile stay until
# make down. A second run finds every device, applies the same volumes and
# changes nothing.
ensure_block_devices() {
	local modules attached node kubeconfig out bytes files n file size i device manifest
	modules=$(cluster_modules storage) || exit 1
	grep -qxF block-devices <<<"$modules" || return 0
	attached=$(attached_roles) || exit 1
	[[ " $attached " == *" storage "* ]] || return 0
	node=$(storage_node)
	kubeconfig=$(kubeconfig_path storage)
	# make up writes the kubeconfig file only for the roles it is given.
	restore_kubeconfig storage

	files=$(docker exec "$node" sh -c 'for f in "$1"/osd-*.img; do if [ -e "$f" ]; then stat -c "%n %s" "$f"; fi; done' _ "$SANDBOX_OSD_DIR" 2>&1) ||
		die "block-devices: cannot read $SANDBOX_OSD_DIR on $node: $(_last_line "$files")"
	n=$(grep -c . <<<"$files" || :)
	[ "$n" -le "$SANDBOX_OSD_COUNT" ] ||
		die "block-devices: $node holds $n OSD files, switches.osd-count says $SANDBOX_OSD_COUNT; run make down first"
	bytes=$((${SANDBOX_OSD_SIZE%Gi} * 1073741824))
	while read -r file size; do
		[ -n "$file" ] || continue
		[ "$size" = "$bytes" ] ||
			die "block-devices: $file on $node has $size bytes, switches.osd-size says $SANDBOX_OSD_SIZE; run make down first"
	done <<<"$files"

	log "preparing the loop devices of $(cluster_name storage): $SANDBOX_OSD_COUNT of $SANDBOX_OSD_SIZE"
	loop_nodes "$node"
	udev_records "$node"
	for ((i = 0; i < SANDBOX_OSD_COUNT; i++)); do
		device=$(block_device "$node" "$i") || exit 1
		manifest=$(block_volume "$i" "$device")
		out=$(kubectl --kubeconfig "$kubeconfig" apply --server-side --force-conflicts --field-manager=sandbox -f - <<<"$manifest" 2>&1) ||
			die "cannot apply the PersistentVolume $SANDBOX_OSD_VOLUME-$i on $(cluster_name storage): $(_last_line "$out")"
	done
}
