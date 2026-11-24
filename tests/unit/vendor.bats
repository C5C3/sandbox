#!/usr/bin/env bats
# scripts/lib/vendor.sh and scripts/vendor.sh: the checkout of upstream, with
# real git on repositories in the test's directory.

setup() {
	load helpers
	upstream_repo
	SANDBOX_VENDOR_DIR=$BATS_TEST_TMPDIR/vendor/cobaltcore
}

# files: prints the files of the checkout outside .git, sorted.
files() {
	(cd "$SANDBOX_VENDOR_DIR" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)
}

# orphan_commit: commits docs/only.md alone on the branch other of upstream
# and prints the commit.
orphan_commit() {
	local repo=$BATS_TEST_TMPDIR/upstream
	test_git -C "$repo" checkout --quiet --orphan other
	test_git -C "$repo" rm --quiet -rf .
	mkdir -p -- "$repo/docs"
	echo only >"$repo/docs/only.md"
	test_git -C "$repo" add -A
	test_git -C "$repo" commit --quiet -m other
	git -C "$repo" rev-parse HEAD
}

# vendor_script <commit>: copies scripts/ into the test's directory and pins
# the commit in a copy of config.yaml, so scripts/vendor.sh checks out
# vendor/cobaltcore there.
vendor_script() {
	cp -R -- "$SANDBOX_ROOT/scripts" "$BATS_TEST_TMPDIR/"
	config_with ".upstream.cobaltcore = \"$1\""
}

@test "vendor_fetch checks out deploy/ and the CRDs of the operators only, and moves to another commit" {
	vendor_fetch "$UPSTREAM_FIRST"
	[ "$(files)" = "./deploy/README.md
./deploy/bases/demo/kustomization.yaml
./operators/x/config/crd/bases/x.yaml" ]
	[ "$(vendor_commit)" = "$UPSTREAM_FIRST" ]
	[ "$(cat "$SANDBOX_VENDOR_DIR/deploy/README.md")" = first ]

	vendor_fetch "$UPSTREAM_SECOND"
	[ "$(vendor_commit)" = "$UPSTREAM_SECOND" ]
	[ "$(cat "$SANDBOX_VENDOR_DIR/deploy/README.md")" = second ]
	[ ! -e "$SANDBOX_VENDOR_DIR/docs" ]
	! vendor_modified
}

@test "vendor_fetch moves to another commit without the history before it" {
	vendor_fetch "$UPSTREAM_FIRST"
	vendor_fetch "$UPSTREAM_SECOND"
	[ "$(vendor_git rev-list --count HEAD)" -eq 1 ]
}

@test "vendor_fetch of a commit without the two paths leaves an empty checkout" {
	local commit
	commit=$(orphan_commit)
	vendor_fetch "$commit"
	[ "$(vendor_commit)" = "$commit" ]
	[ -z "$(files)" ]
}

@test "scripts/vendor.sh ends with the commit and the number of files" {
	local commit
	vendor_script "$UPSTREAM_FIRST"
	run "$BATS_TEST_TMPDIR/scripts/vendor.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "vendor: vendor/cobaltcore is at $UPSTREAM_FIRST, 3 files" ]

	commit=$(orphan_commit)
	vendor_script "$commit"
	run "$BATS_TEST_TMPDIR/scripts/vendor.sh"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "vendor: vendor/cobaltcore is at $commit, 0 files" ]
}

@test "scripts/vendor.sh fails without git" {
	mkdir -- "$BATS_TEST_TMPDIR/bin"
	ln -s -- "$(command -v dirname)" "$BATS_TEST_TMPDIR/bin/dirname"
	run env -i PATH="$BATS_TEST_TMPDIR/bin" "$BASH" "$SANDBOX_ROOT/scripts/vendor.sh"
	[ "$status" -eq 1 ]
	[ "$output" = 'error: git not found in PATH, see "Host requirements" in the README' ]
}

@test "vendor_fetch discards a changed, a deleted and an untracked file, also one upstream ignores" {
	vendor_fetch "$UPSTREAM_FIRST"
	echo changed >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	rm -- "$SANDBOX_VENDOR_DIR/deploy/bases/demo/kustomization.yaml"
	touch "$SANDBOX_VENDOR_DIR/deploy/new.out"
	vendor_modified
	run vendor_fetch "$UPSTREAM_FIRST"
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 3 ]
	[[ ${lines[0]} == *": discarding deploy/README.md" ]]
	[[ ${lines[1]} == *": discarding deploy/bases/demo/kustomization.yaml" ]]
	[[ ${lines[2]} == *": discarding deploy/new.out" ]]
	! vendor_modified
	[ "$(cat "$SANDBOX_VENDOR_DIR/deploy/README.md")" = first ]
	[ ! -e "$SANDBOX_VENDOR_DIR/deploy/new.out" ]
}

@test "vendor_record marks a staged change, a staged new file and a staged removal, which vendor_fetch discards" {
	vendor_fetch "$UPSTREAM_FIRST"
	echo staged >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	vendor_git add deploy/README.md
	[ "$(vendor_record)" = "$UPSTREAM_FIRST-modified" ]
	run vendor_fetch "$UPSTREAM_FIRST"
	[ "$status" -eq 0 ]
	[[ $output == *": discarding deploy/README.md" ]]
	[ "$(cat "$SANDBOX_VENDOR_DIR/deploy/README.md")" = first ]

	echo new >"$SANDBOX_VENDOR_DIR/deploy/new.txt"
	vendor_git add deploy/new.txt
	[ "$(vendor_record)" = "$UPSTREAM_FIRST-modified" ]
	vendor_fetch "$UPSTREAM_FIRST" >/dev/null
	[ ! -e "$SANDBOX_VENDOR_DIR/deploy/new.txt" ]

	vendor_git rm --quiet deploy/README.md
	[ "$(vendor_record)" = "$UPSTREAM_FIRST-modified" ]
	vendor_fetch "$UPSTREAM_FIRST" >/dev/null
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
}

@test "vendor_record marks a commit made in the checkout, which vendor_fetch discards" {
	local local_commit
	vendor_fetch "$UPSTREAM_FIRST"
	echo local >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	test_git -C "$SANDBOX_VENDOR_DIR" commit --quiet -am local
	local_commit=$(vendor_commit)
	[ "$(vendor_record)" = "$local_commit-modified" ]
	vendor_fetch "$UPSTREAM_FIRST"
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
}

@test "vendor_fetch adds a path appended to SANDBOX_VENDOR_PATHS to a checkout at the commit" {
	vendor_fetch "$UPSTREAM_FIRST"
	[ ! -e "$SANDBOX_VENDOR_DIR/docs/index.md" ]
	SANDBOX_VENDOR_PATHS+=('/docs/')
	vendor_fetch "$UPSTREAM_FIRST"
	[ "$(cat "$SANDBOX_VENDOR_DIR/docs/index.md")" = docs ]
	! vendor_modified
}

@test "vendor_record prints the commit and marks local changes" {
	run vendor_record
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	vendor_fetch "$UPSTREAM_FIRST"
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
	mkdir -- "$SANDBOX_VENDOR_DIR/docs"
	touch "$SANDBOX_VENDOR_DIR/docs/new.out"
	[ "$(vendor_record)" = "$UPSTREAM_FIRST-modified" ]
}

@test "vendor_commit fails without output for a missing directory and one without .git inside a repository" {
	run vendor_commit
	[ "$status" -eq 1 ]
	[ -z "$output" ]

	test_git init --quiet -- "$BATS_TEST_TMPDIR/outer"
	test_git -C "$BATS_TEST_TMPDIR/outer" commit --quiet --allow-empty -m outer
	SANDBOX_VENDOR_DIR=$BATS_TEST_TMPDIR/outer/vendor/cobaltcore
	mkdir -p -- "$SANDBOX_VENDOR_DIR"
	run vendor_commit
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "vendor_fetch refuses a directory that is no checkout and leaves it as it was" {
	mkdir -p -- "$SANDBOX_VENDOR_DIR/deploy"
	echo mine >"$SANDBOX_VENDOR_DIR/deploy/README.md"
	cp -R -- "$SANDBOX_VENDOR_DIR" "$BATS_TEST_TMPDIR/before"
	run vendor_fetch "$UPSTREAM_FIRST"
	[ "$status" -eq 1 ]
	[ "$output" = "error: vendor: $SANDBOX_VENDOR_DIR exists and is not a checkout of make vendor; remove it" ]
	diff -r -- "$BATS_TEST_TMPDIR/before" "$SANDBOX_VENDOR_DIR"
}

@test "vendor_fetch fails for an unreachable repository, and a second run completes the directory" {
	local url=$SANDBOX_UPSTREAM_URL
	SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/missing
	run vendor_fetch "$UPSTREAM_FIRST"
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "error: vendor: cannot fetch $UPSTREAM_FIRST from file://$BATS_TEST_TMPDIR/missing: "?* ]]
	[ -z "$(files)" ]

	SANDBOX_UPSTREAM_URL=$url
	vendor_fetch "$UPSTREAM_FIRST"
	[ "$(vendor_commit)" = "$UPSTREAM_FIRST" ]
}

@test "vendor_fetch fails for a commit upstream does not have, and a second run completes the directory" {
	local absent=0123456789abcdef0123456789abcdef01234567
	run vendor_fetch "$absent"
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "error: vendor: cannot fetch $absent from $SANDBOX_UPSTREAM_URL: "*"not our ref $absent" ]]

	vendor_fetch "$UPSTREAM_SECOND"
	[ "$(vendor_commit)" = "$UPSTREAM_SECOND" ]
}

@test "vendor_fetch of the commit of the checkout needs no network" {
	vendor_fetch "$UPSTREAM_FIRST"
	echo changed >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/missing
	run vendor_fetch "$UPSTREAM_FIRST"
	[ "$status" -eq 0 ]
	[[ $output == *": discarding deploy/README.md" ]]
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
}

@test "ensure_vendor checks out a missing checkout" {
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_FIRST
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "checking out C5C3/cobaltcore at $UPSTREAM_FIRST into vendor/cobaltcore" ]
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
}

@test "ensure_vendor leaves a checkout at the pin as it is, with or without local changes, without network" {
	vendor_fetch "$UPSTREAM_FIRST"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_FIRST SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/missing
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "vendor/cobaltcore is at $UPSTREAM_FIRST" ]

	echo changed >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "vendor/cobaltcore is at $UPSTREAM_FIRST with local changes, left as it is" ]
	[ "$(vendor_record)" = "$UPSTREAM_FIRST-modified" ]
}

@test "ensure_vendor moves a checkout without local changes to the pin" {
	vendor_fetch "$UPSTREAM_FIRST"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_SECOND
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "moving vendor/cobaltcore from $UPSTREAM_FIRST to $UPSTREAM_SECOND" ]
	[ "$(vendor_record)" = "$UPSTREAM_SECOND" ]
}

@test "ensure_vendor completes a move that could not write its record on the next run" {
	vendor_fetch "$UPSTREAM_FIRST"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_SECOND
	# A lock that a killed git left behind blocks the record.
	touch "$SANDBOX_VENDOR_DIR/.git/refs/sandbox/checkout.lock"
	run ensure_vendor
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "error: vendor: cannot check out $UPSTREAM_SECOND in $SANDBOX_VENDOR_DIR: "?* ]]

	rm -- "$SANDBOX_VENDOR_DIR/.git/refs/sandbox/checkout.lock"
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "moving vendor/cobaltcore from $UPSTREAM_FIRST to $UPSTREAM_SECOND" ]
	[ "$(vendor_record)" = "$UPSTREAM_SECOND" ]
}

@test "ensure_vendor records a move that stopped after the checkout, so a later commit in the checkout is a local change" {
	local local_commit
	vendor_fetch "$UPSTREAM_FIRST"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_SECOND
	# The move stops after the checkout, before it records the commit.
	git() {
		if [ "${*: -3}" = "update-ref refs/sandbox/checkout $UPSTREAM_SECOND" ]; then
			echo 'fatal: interrupted' >&2
			return 1
		fi
		command git "$@"
	}
	run ensure_vendor
	unset -f git
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: vendor: cannot check out $UPSTREAM_SECOND in $SANDBOX_VENDOR_DIR: fatal: interrupted" ]
	[ "$(vendor_commit)" = "$UPSTREAM_SECOND" ]

	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "vendor/cobaltcore is at $UPSTREAM_SECOND" ]
	[ "$(vendor_record)" = "$UPSTREAM_SECOND" ]

	echo local >>"$SANDBOX_VENDOR_DIR/deploy/README.md"
	test_git -C "$SANDBOX_VENDOR_DIR" commit --quiet -am local
	local_commit=$(vendor_commit)
	[ "$(vendor_record)" = "$local_commit-modified" ]
}

@test "ensure_vendor refuses a checkout with local changes at another commit and keeps them" {
	vendor_fetch "$UPSTREAM_FIRST"
	touch "$SANDBOX_VENDOR_DIR/deploy/local.tmp"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_SECOND
	run ensure_vendor
	[ "$status" -eq 1 ]
	[ "$output" = "error: vendor: vendor/cobaltcore is at $UPSTREAM_FIRST with local changes, the configuration pins $UPSTREAM_SECOND; run make vendor to discard them" ]
	[ -f "$SANDBOX_VENDOR_DIR/deploy/local.tmp" ]
	[ "$(vendor_commit)" = "$UPSTREAM_FIRST" ]
}

@test "ensure_vendor refuses a checkout with a staged file or a commit of its own at another commit and keeps them" {
	local local_commit
	vendor_fetch "$UPSTREAM_FIRST"
	echo new >"$SANDBOX_VENDOR_DIR/deploy/new.txt"
	vendor_git add deploy/new.txt
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_SECOND
	run ensure_vendor
	[ "$status" -eq 1 ]
	[ "$output" = "error: vendor: vendor/cobaltcore is at $UPSTREAM_FIRST with local changes, the configuration pins $UPSTREAM_SECOND; run make vendor to discard them" ]
	[ "$(vendor_git diff --cached --name-only)" = deploy/new.txt ]

	test_git -C "$SANDBOX_VENDOR_DIR" commit --quiet -m local
	local_commit=$(vendor_commit)
	run ensure_vendor
	[ "$status" -eq 1 ]
	[ "$output" = "error: vendor: vendor/cobaltcore is at $local_commit with local changes, the configuration pins $UPSTREAM_SECOND; run make vendor to discard them" ]
	[ "$(vendor_commit)" = "$local_commit" ]
	[ -f "$SANDBOX_VENDOR_DIR/deploy/new.txt" ]
}

@test "ensure_vendor checks out a path appended to SANDBOX_VENDOR_PATHS at the pin, and refuses it with local changes" {
	vendor_fetch "$UPSTREAM_FIRST"
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_FIRST
	SANDBOX_VENDOR_PATHS+=('/docs/')
	touch "$SANDBOX_VENDOR_DIR/deploy/local.tmp"
	run ensure_vendor
	[ "$status" -eq 1 ]
	[ "$output" = "error: vendor: vendor/cobaltcore has local changes and other paths than SANDBOX_VENDOR_PATHS; run make vendor to discard them" ]
	[ -f "$SANDBOX_VENDOR_DIR/deploy/local.tmp" ]
	[ ! -e "$SANDBOX_VENDOR_DIR/docs" ]

	rm -- "$SANDBOX_VENDOR_DIR/deploy/local.tmp"
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "checking out the paths of SANDBOX_VENDOR_PATHS in vendor/cobaltcore" ]
	[ "$(cat "$SANDBOX_VENDOR_DIR/docs/index.md")" = docs ]
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]

	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "vendor/cobaltcore is at $UPSTREAM_FIRST" ]
}

@test "ensure_vendor makes a checkout at the pin that is not sparse hold the paths of SANDBOX_VENDOR_PATHS again" {
	vendor_fetch "$UPSTREAM_FIRST"
	vendor_git sparse-checkout disable
	[ -f "$SANDBOX_VENDOR_DIR/docs/index.md" ]
	export SANDBOX_UPSTREAM_COMMIT=$UPSTREAM_FIRST
	run ensure_vendor
	[ "$status" -eq 0 ]
	[ "${output#*: }" = "checking out the paths of SANDBOX_VENDOR_PATHS in vendor/cobaltcore" ]
	[ ! -e "$SANDBOX_VENDOR_DIR/docs" ]
	[ "$(vendor_record)" = "$UPSTREAM_FIRST" ]
}
