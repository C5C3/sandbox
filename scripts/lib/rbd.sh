# shellcheck shell=bash
# The RBD checks of make verify. Source scripts/lib/hub.sh first; the
# functions use report, poll, os_error, os_quiet, cinder_error,
# volume_create, errfile, tmp and controlplane of scripts/verify.sh, which
# sources this file, and
# compute_skip of scripts/lib/compute.sh, which it sources before.
#
# They run when the ControlPlane declares an entry of
# spec.services.cinder.backends named ceph1 of type RBD, after the checks of
# the services and before those of the compute pool, in this order:
#
#   rbd-backend   within 300 s the backend ceph1 reports a pool, and the
#                 cinder-volume service on controlplane-cinder@ceph1 is up
#   rbd-volume    the 1 GiB volume sandbox-verify-rbd-volume is available
#                 within 120 s on controlplane-cinder@ceph1, and its image
#                 volumes/volume-<id> on sandbox-storage has 1 GiB
#
# and, when spec.services.cinder.backupBackend is named cephbk:
#
#   rbd-backup    after rbd bench wrote 4 MiB to the image, the backup
#                 sandbox-verify-rbd-backup is available within 600 s, and
#                 the pool backups holds an image volume-<id>.backup.*
#   rbd-restore   the backup restored onto the 1 GiB volume
#                 sandbox-verify-rbd-restored is available within 600 s, and
#                 the first 4 MiB of both images have the same sha256
#   rbd-rotation  after keyGeneration of the CephClient rook-ceph/cinder-backup
#                 rose by one, the Secret openstack/ceph-client-cinder-backup
#                 holds Ceph's new key within 300 s, the Deployment
#                 openstack/controlplane-cinder-backup rolls within 600 s,
#                 and the backup sandbox-verify-rbd-rotated is available
#                 within 600 s
#
# A check whose input an earlier check failed to create reports "skipped,
# <earlier id> failed": a failed rbd-volume skips the three after it, a
# failed rbd-backup skips rbd-restore. So they report two lines without
# cephbk and five with it. The checks read sandbox-storage with the
# kubeconfig file of the role and run rbd and ceph in deploy/rook-ceph-tools
# of rook-ceph there. Before the first create and after the last check,
# also after a failure, they delete the two backups and then the two
# volumes, by name before their ids exist and by id after. No key reaches
# an argument, a file or a line: the Secret goes from kubectl through jq
# into sha256sum by pipes, Ceph's key into sha256sum inside the toolbox,
# and only the digests are kept. Each run with cephbk raises keyGeneration
# by one, and nothing sets it back (ADR-0040).

# The kubeconfig file of sandbox-storage, which rbd_storage sets.
rbd_kubeconfig=
# What the last call of rbd_kubectl or rbd_secret_digest printed, and the
# last line of the error of the last one that failed.
rbd_out=
rbd_error=

# rbd_storage: sets rbd_kubeconfig to the kubeconfig file of sandbox-storage.
# When sandbox_cluster or restore_kubeconfig fails, it sets rbd_error to the
# first line of their message without "error: " and returns 1.
rbd_storage() {
	local out
	# sandbox_cluster and restore_kubeconfig end the script when they cannot
	# tell, so they run in a subshell, and their message is the check's.
	if ! (sandbox_cluster storage) 2>"$errfile"; then
		out=$(_first_line "$(<"$errfile")")
		out=${out#error: }
		rbd_error=${out:-$(cluster_name storage) does not exist}
		return 1
	fi
	if ! (restore_kubeconfig storage) >&2 2>"$errfile"; then
		out=$(_first_line "$(<"$errfile")")
		rbd_error=${out#error: }
		return 1
	fi
	rbd_kubeconfig=$(kubeconfig_path storage)
}

# rbd_kubectl <argument>...: runs kubectl with the arguments against
# sandbox-storage and keeps its output in rbd_out. When kubectl fails, it
# sets rbd_error to the last line of its error and returns 1.
rbd_kubectl() {
	if ! rbd_out=$(kubectl --kubeconfig "$rbd_kubeconfig" "$@" 2>"$tmp/kubectl.err"); then
		rbd_error=$(_last_line "$(<"$tmp/kubectl.err")")
		return 1
	fi
}

# rbd_tools <argument>...: runs the arguments in deploy/rook-ceph-tools of
# rook-ceph on sandbox-storage, as rbd_kubectl does.
rbd_tools() {
	rbd_kubectl -n rook-ceph exec deploy/rook-ceph-tools -- "$@"
}

# rbd_secret_digest: keeps the sha256 of userKey of the Secret
# openstack/ceph-client-cinder-backup on the hub in rbd_out. When kubectl
# fails, it sets rbd_error to the last line of its error and returns 1.
rbd_secret_digest() {
	local out
	if ! out=$(hub_kubectl -n openstack get secret ceph-client-cinder-backup -o json 2>"$tmp/kubectl.err" |
		jq -j '.data.userKey // empty | @base64d' | sha256sum); then
		rbd_error=$(_last_line "$(<"$tmp/kubectl.err")")
		return 1
	fi
	rbd_out=${out%% *}
}

# rbd_ceph_digest: keeps the sha256 of the key Ceph holds for
# client.cinder-backup in rbd_out, as rbd_secret_digest does. The key stays
# in a variable of the shell in the toolbox, and printf is a builtin.
rbd_ceph_digest() {
	rbd_tools sh -c 'key=$(ceph auth get-key client.cinder-backup) && printf %s "$key" | sha256sum' key-digest || return
	rbd_out=${rbd_out%% *}
}

# rbd_export_digest <image>: keeps the sha256 of the first 4 MiB of the
# image in rbd_out, as rbd_secret_digest does. rbd info fails for a missing
# image, so its digest is never that of nothing.
rbd_export_digest() {
	rbd_tools sh -c 'rbd info "$1" >/dev/null && rbd export --no-progress "$1" - 2>/dev/null | head -c 4194304 | sha256sum' \
		export-digest "$1" || return
	rbd_out=${rbd_out%% *}
}

# rbd_backend: the check rbd-backend. It reads the pools of the backends,
# and again after each of up to 150 pauses of 2 s, until one belongs to
# ceph1.
rbd_backend() {
	local out pool state i
	for ((i = 0; ; i++)); do
		if ! out=$(openstack volume backend pool list -f value 2>"$errfile"); then
			report FAIL rbd-backend "$(os_error "$out")"
			return
		fi
		pool=$(grep -m 1 -F '@ceph1#' <<<"$out" || :)
		if [ -n "$pool" ]; then
			break
		fi
		if [ "$i" -ge 150 ]; then
			report FAIL rbd-backend "the backend ceph1 reports no pool after 300 s"
			return
		fi
		sleep 2
	done
	if ! out=$(openstack volume service list --service cinder-volume -f json 2>"$errfile"); then
		report FAIL rbd-backend "$(os_error "$out")"
		return
	fi
	state=$(jq -r '[.[]? | select(.Host == "controlplane-cinder@ceph1")][0].State // empty' <<<"$out" 2>/dev/null) || state=
	if [ -z "$state" ]; then
		report FAIL rbd-backend "no cinder-volume service on controlplane-cinder@ceph1"
	elif [ "$state" != up ]; then
		report FAIL rbd-backend "cinder-volume on controlplane-cinder@ceph1 is '$state', expected up"
	else
		report ok rbd-backend "the backend ceph1 reports the pool $pool, and cinder-volume on controlplane-cinder@ceph1 is up"
	fi
}

# rbd_volume: creates the 1 GiB volume sandbox-verify-rbd-volume and reports
# the check rbd-volume. It sets volume of its caller to the id of the volume
# once it exists, and returns 1 when the check failed.
rbd_volume() {
	local out host size rc=0
	if ! out=$(volume_create sandbox-verify-rbd-volume); then
		report FAIL rbd-volume "$out"
		return 1
	fi
	volume=$out
	poll available 60 openstack volume show "$volume" -f value -c status || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL rbd-volume "the volume sandbox-verify-rbd-volume is '$polled' after 120 s, expected available"
		return 1
		;;
	*)
		report FAIL rbd-volume "$polled"
		return 1
		;;
	esac
	if ! out=$(openstack volume show "$volume" -f value -c os-vol-host-attr:host 2>"$errfile"); then
		report FAIL rbd-volume "$(os_error "$out")"
		return 1
	fi
	host=$(_first_line "$out")
	if [[ $host != controlplane-cinder@ceph1#* ]]; then
		report FAIL rbd-volume "the volume sandbox-verify-rbd-volume is on '$host', expected controlplane-cinder@ceph1#<pool>"
		return 1
	fi
	if ! rbd_storage; then
		report FAIL rbd-volume "$rbd_error"
		return 1
	fi
	if ! rbd_tools rbd info --format json "volumes/volume-$volume"; then
		report FAIL rbd-volume "rbd info volumes/volume-$volume: $rbd_error"
		return 1
	fi
	size=$(jq -r '.size // empty' <<<"$rbd_out" 2>/dev/null) || size=
	if [ "$size" != 1073741824 ]; then
		report FAIL rbd-volume "the image volumes/volume-$volume has $size bytes, expected 1073741824"
		return 1
	fi
	report ok rbd-volume "the 1 GiB volume sandbox-verify-rbd-volume is available on $host, and its image volumes/volume-$volume on sandbox-storage has 1073741824 bytes"
}

# rbd_backup: writes 4 MiB to the image of the volume of its caller, backs
# the volume up as sandbox-verify-rbd-backup and reports the check
# rbd-backup. It sets backup of its caller to the id of the backup once it
# exists, and returns 1 when the check failed.
rbd_backup() {
	local out image line rc=0
	if ! rbd_tools rbd bench --io-type write --io-size 4K --io-total 4M "volumes/volume-$volume"; then
		report FAIL rbd-backup "rbd bench volumes/volume-$volume: $rbd_error"
		return 1
	fi
	if ! out=$(openstack volume backup create --name sandbox-verify-rbd-backup -f value -c id "$volume" 2>"$errfile"); then
		report FAIL rbd-backup "$(os_error "$out")"
		return 1
	fi
	backup=$(_first_line "$out")
	poll available 300 openstack volume backup show "$backup" -f value -c status || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL rbd-backup "the backup sandbox-verify-rbd-backup is '$polled' after 600 s, expected available"
		return 1
		;;
	*)
		report FAIL rbd-backup "$polled"
		return 1
		;;
	esac
	if ! rbd_tools rbd ls backups; then
		report FAIL rbd-backup "rbd ls backups: $rbd_error"
		return 1
	fi
	image=
	while IFS= read -r line; do
		if [[ $line == "volume-$volume.backup."* ]]; then
			image=$line
			break
		fi
	done <<<"$rbd_out"
	if [ -z "$image" ]; then
		report FAIL rbd-backup "rbd ls backups lists no image volume-$volume.backup.*"
		return 1
	fi
	report ok rbd-backup "the backup sandbox-verify-rbd-backup of sandbox-verify-rbd-volume is available, and the pool backups holds its image $image"
}

# rbd_restore: restores the backup of its caller onto the 1 GiB volume
# sandbox-verify-rbd-restored and reports the check rbd-restore. It sets
# restored of its caller to the id of that volume once it exists.
rbd_restore() {
	local out source rc=0
	if ! out=$(volume_create sandbox-verify-rbd-restored); then
		report FAIL rbd-restore "$out"
		return
	fi
	restored=$out
	poll available 60 openstack volume show "$restored" -f value -c status || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL rbd-restore "the volume sandbox-verify-rbd-restored is '$polled' after 120 s, expected available"
		return
		;;
	*)
		report FAIL rbd-restore "$polled"
		return
		;;
	esac
	# openstack volume backup restore of python-openstackclient 6.6.0 sends
	# the restore and then fails on its own answer with "too many values to
	# unpack", so cinder restores, as it creates the volumes. The restore
	# sets the volume to restoring-backup before it returns.
	if ! out=$(cinder backup-restore --volume "$restored" "$backup" 2>"$errfile"); then
		report FAIL rbd-restore "$(cinder_error "$out")"
		return
	fi
	poll available 300 openstack volume show "$restored" -f value -c status || rc=$?
	case $rc in
	0) ;;
	1)
		report FAIL rbd-restore "the volume sandbox-verify-rbd-restored is '$polled' after 600 s, expected available"
		return
		;;
	*)
		report FAIL rbd-restore "$polled"
		return
		;;
	esac
	if ! rbd_export_digest "volumes/volume-$volume"; then
		report FAIL rbd-restore "rbd export volumes/volume-$volume: $rbd_error"
		return
	fi
	source=$rbd_out
	if ! rbd_export_digest "volumes/volume-$restored"; then
		report FAIL rbd-restore "rbd export volumes/volume-$restored: $rbd_error"
		return
	fi
	if [ "$rbd_out" != "$source" ]; then
		report FAIL rbd-restore "the first 4 MiB of sandbox-verify-rbd-restored differ from those of sandbox-verify-rbd-volume"
		return
	fi
	report ok rbd-restore "the backup sandbox-verify-rbd-backup restored onto sandbox-verify-rbd-restored, whose first 4 MiB are those of sandbox-verify-rbd-volume"
}

# rbd_rotation: the check rbd-rotation. It raises keyGeneration of the
# CephClient rook-ceph/cinder-backup on sandbox-storage by one with a merge
# patch, waits up to 300 s for the Secret openstack/ceph-client-cinder-backup
# to hold the key Ceph then holds, up to 600 s for a new generation of the
# Deployment openstack/controlplane-cinder-backup and up to 300 s for its
# rollout, and backs the volume of its caller up as
# sandbox-verify-rbd-rotated. It sets rotated of its caller to the id of
# that backup once it exists.
rbd_rotation() {
	local out generation rolled first digest ceph i rc=0
	if ! rbd_kubectl -n rook-ceph get cephclient cinder-backup -o json; then
		report FAIL rbd-rotation "$rbd_error"
		return
	fi
	generation=$(jq -r '.spec.security.cephx.keyGeneration // empty' <<<"$rbd_out" 2>/dev/null) || generation=
	if [[ ! $generation =~ ^[0-9]+$ ]]; then
		report FAIL rbd-rotation "the CephClient rook-ceph/cinder-backup on sandbox-storage has no keyGeneration"
		return
	fi
	if ! out=$(_hub_json -n openstack get deployment controlplane-cinder-backup); then
		report FAIL rbd-rotation "$out"
		return
	fi
	rolled=$(jq -r '.metadata.generation // empty' <<<"$out")
	if ! rbd_secret_digest; then
		report FAIL rbd-rotation "$rbd_error"
		return
	fi
	first=$rbd_out
	if ! rbd_kubectl -n rook-ceph patch cephclient cinder-backup --type merge \
		-p "{\"spec\":{\"security\":{\"cephx\":{\"keyGeneration\":$((generation + 1))}}}}"; then
		report FAIL rbd-rotation "$rbd_error"
		return
	fi

	# Rook writes the new key, the PushSecret hands it to OpenBao and the
	# ExternalSecret into openstack, each within a minute.
	for ((i = 0; ; i++)); do
		if ! rbd_secret_digest; then
			report FAIL rbd-rotation "$rbd_error"
			return
		fi
		digest=$rbd_out
		if [ "$digest" != "$first" ]; then
			if ! rbd_ceph_digest; then
				report FAIL rbd-rotation "$rbd_error"
				return
			fi
			ceph=$rbd_out
			if [ "$digest" = "$ceph" ]; then
				break
			fi
		fi
		if [ "$i" -ge 150 ]; then
			if [ "$digest" = "$first" ]; then
				report FAIL rbd-rotation "the Secret openstack/ceph-client-cinder-backup holds the old key after 300 s"
			else
				report FAIL rbd-rotation "the Secret openstack/ceph-client-cinder-backup holds a key Ceph does not hold for client.cinder-backup"
			fi
			return
		fi
		sleep 2
	done

	for ((i = 0; ; i++)); do
		if ! out=$(_hub_json -n openstack get deployment controlplane-cinder-backup); then
			report FAIL rbd-rotation "$out"
			return
		fi
		if [ "$(jq -r '.metadata.generation // empty' <<<"$out")" != "$rolled" ]; then
			break
		fi
		if [ "$i" -ge 300 ]; then
			report FAIL rbd-rotation "the Deployment openstack/controlplane-cinder-backup did not roll within 600 s"
			return
		fi
		sleep 2
	done
	if ! hub_kubectl -n openstack rollout status deployment/controlplane-cinder-backup --timeout=300s >/dev/null 2>"$tmp/kubectl.err"; then
		report FAIL rbd-rotation "$(_last_line "$(<"$tmp/kubectl.err")")"
		return
	fi

	if ! out=$(openstack volume backup create --name sandbox-verify-rbd-rotated -f value -c id "$volume" 2>"$errfile"); then
		report FAIL rbd-rotation "$(os_error "$out")"
		return
	fi
	rotated=$(_first_line "$out")
	poll available 300 openstack volume backup show "$rotated" -f value -c status || rc=$?
	case $rc in
	0) report ok rbd-rotation "keyGeneration of rook-ceph/cinder-backup rose from $generation to $((generation + 1)), openstack/ceph-client-cinder-backup holds Ceph's new key, controlplane-cinder-backup rolled, and the backup sandbox-verify-rbd-rotated is available" ;;
	1) report FAIL rbd-rotation "the backup sandbox-verify-rbd-rotated is '$polled' after 600 s, expected available" ;;
	*) report FAIL rbd-rotation "$polled" ;;
	esac
}

# rbd_cleanup: deletes the backups backup and rotated of its caller and then
# its volumes volume and restored, by their names or their ids.
rbd_cleanup() {
	os_quiet volume backup delete "$backup"
	os_quiet volume backup delete "$rotated"
	os_quiet volume delete "$volume"
	os_quiet volume delete "$restored"
}

# check_rbd: the RBD checks, for a ControlPlane with the backend ceph1 of type
# RBD. Without it they report nothing.
check_rbd() {
	local volume=sandbox-verify-rbd-volume restored=sandbox-verify-rbd-restored backup=sandbox-verify-rbd-backup
	local rotated=sandbox-verify-rbd-rotated cephbk=false
	if ! jq -e '(.spec.services.cinder.backends // []) | any(.name? == "ceph1" and .type? == "RBD")' >/dev/null 2>&1 <<<"$controlplane"; then
		return 0
	fi
	if [ "$(jq -r '.spec.services.cinder.backupBackend.name // empty' <<<"$controlplane")" = cephbk ]; then
		cephbk=true
	fi

	rbd_cleanup
	rbd_backend
	if ! rbd_volume; then
		if $cephbk; then
			compute_skip rbd-volume rbd-backup rbd-restore rbd-rotation
		fi
	elif $cephbk; then
		if rbd_backup; then
			rbd_restore
		else
			compute_skip rbd-backup rbd-restore
		fi
		rbd_rotation
	fi
	rbd_cleanup
}
