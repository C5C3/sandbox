#!/usr/bin/env bats
# scripts/install-validate-tools.sh with uname, curl and the installed tools
# replaced by scripts in the test's directory, so no test downloads.

setup() {
	load helpers
	export SANDBOX_VALIDATE_CACHE=$BATS_TEST_TMPDIR/cache PATH=$BATS_TEST_TMPDIR/bin:$PATH
	mkdir -p -- "$BATS_TEST_TMPDIR/bin"
}

# fake_bin <path> <shell code>: writes an executable script with the code.
fake_bin() {
	mkdir -p -- "$(dirname -- "$1")"
	printf '#!/bin/sh\n%s\n' "$2" >"$1"
	chmod +x -- "$1"
}

@test "an archive whose checksum differs is refused and nothing is installed" {
	local got
	fake_bin "$BATS_TEST_TMPDIR/bin/uname" 'echo Linux x86_64'
	fake_bin "$BATS_TEST_TMPDIR/bin/curl" 'while [ "$#" -gt 0 ]; do [ "$1" = -o ] && echo tampered >"$2"; shift; done'
	got=$(echo tampered | sha256sum | cut -d ' ' -f 1)
	run "$SANDBOX_ROOT/scripts/install-validate-tools.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "install-validate-tools: error: flux_2.10.0_linux_amd64.tar.gz: checksum mismatch (expected 208dd7012c04fedeed5b2d0b6e63df3b15b1c34a381527811685c098bc9f8659, got $got)" ]
	[ ! -e "$SANDBOX_VALIDATE_CACHE/bin/flux" ]
}

@test "a tool at the pinned version is not downloaded again" {
	fake_bin "$BATS_TEST_TMPDIR/bin/uname" 'echo Linux x86_64'
	fake_bin "$BATS_TEST_TMPDIR/bin/curl" 'echo "curl called" >&2; exit 7'
	fake_bin "$SANDBOX_VALIDATE_CACHE/bin/flux" 'echo "flux: v2.10.0"'
	fake_bin "$SANDBOX_VALIDATE_CACHE/bin/kubeconform" 'echo v0.8.0'
	run "$SANDBOX_ROOT/scripts/install-validate-tools.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "install-validate-tools: flux 2.10.0 already installed
install-validate-tools: kubeconform 0.8.0 already installed" ]
}

@test "a platform other than Linux x86_64 is refused" {
	fake_bin "$BATS_TEST_TMPDIR/bin/uname" 'echo Darwin arm64'
	run "$SANDBOX_ROOT/scripts/install-validate-tools.sh"
	[ "$status" -eq 1 ]
	[ "$output" = "install-validate-tools: error: only Linux x86_64 is supported (found Darwin arm64)" ]
	[ ! -e "$SANDBOX_VALIDATE_CACHE" ]
}

@test "an argument is a usage error" {
	run "$SANDBOX_ROOT/scripts/install-validate-tools.sh" flux
	[ "$status" -eq 2 ]
	[ "$output" = "usage: scripts/install-validate-tools.sh" ]
}
