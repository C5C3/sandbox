#!/usr/bin/env bats
# compute/libvirt/host-prepare.sh, the init container of the libvirt pod, as
# a process against a stub modprobe. The stub is a file first in PATH: the
# script is a child process, which sees no function of the test. KVM_DEVICE
# points the check of /dev/kvm at a file of the test's directory.

setup() {
	load helpers
	SCRIPT=$SANDBOX_ROOT/compute/libvirt/host-prepare.sh
	STUB=$BATS_TEST_TMPDIR/stub
	mkdir -p -- "$STUB/bin"
	export STUB_LOG=$BATS_TEST_TMPDIR/modprobe.log STUB_STATUS=0
	cat >"$STUB/bin/modprobe" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
exit "$STUB_STATUS"
EOF
	chmod +x "$STUB/bin/modprobe"
}

# run_script [<variable>=<value>...]: runs the script with the stub first in
# PATH and the variables given.
run_script() {
	run env -u KVM_DEVICE PATH="$STUB/bin:$PATH" "$@" bash "$SCRIPT"
}

@test "host-prepare.sh loads vhost_net and prints nothing on a node with /dev/kvm" {
	touch "$BATS_TEST_TMPDIR/kvm"
	run_script KVM_DEVICE="$BATS_TEST_TMPDIR/kvm"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$(<"$STUB_LOG")" = vhost_net ]
}

@test "host-prepare.sh says that guests run under TCG on a node without /dev/kvm, and succeeds" {
	run_script KVM_DEVICE="$BATS_TEST_TMPDIR/no-kvm"
	[ "$status" -eq 0 ]
	[ "$output" = "host-prepare: /dev/kvm is missing on this node, guests run under TCG" ]
}

@test "host-prepare.sh checks /dev/kvm itself without KVM_DEVICE" {
	run_script
	[ "$status" -eq 0 ]
	if [ -e /dev/kvm ]; then
		[ "$output" = "" ]
	else
		[ "$output" = "host-prepare: /dev/kvm is missing on this node, guests run under TCG" ]
	fi
}

@test "host-prepare.sh fails with the module tree of the kernel when it cannot load vhost_net" {
	export STUB_STATUS=1
	run_script KVM_DEVICE="$BATS_TEST_TMPDIR/no-kvm"
	[ "$status" -eq 1 ]
	[ "$output" = "host-prepare: cannot load vhost_net from /lib/modules/$(uname -r)" ]
}
