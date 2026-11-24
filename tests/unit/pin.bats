#!/usr/bin/env bats
# scripts/pin.sh: move against a local upstream, and propose against a bare
# repository as origin and a gh in PATH that records its arguments.

setup() {
	load helpers
	OLD=15a0323e243c7f53b91200f193a58b5b41d41f6a
	NEW=bbb35e61e8df6b0e215c6a04732f2ad78759fe76
	USAGE="usage: scripts/pin.sh move [<commit>] | propose <old> <new> <passed|failed> <log file>"
	LIST_CALL='api repos/{owner}/{repo}/pulls?state=open&base=main&head={owner}:upstream-pin'
}

# fake_gh: puts a gh into PATH that appends its arguments to $GH_DIR/calls,
# copies the file of --body-file to $GH_DIR/body and prints $GH_DIR/pulls
# for api, [] by default. With $GH_DIR/<command>-<subcommand>.fail, or
# $GH_DIR/api.fail for api, it prints that file on stderr and exits 1.
fake_gh() {
	export GH_DIR=$BATS_TEST_TMPDIR/gh
	mkdir -p -- "$BATS_TEST_TMPDIR/bin" "$GH_DIR"
	cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_DIR/calls"
key=$1-$2
if [ "$1" = api ]; then key=api; fi
if [ -f "$GH_DIR/$key.fail" ]; then
	cat "$GH_DIR/$key.fail" >&2
	exit 1
fi
while [ "$#" -gt 0 ]; do
	if [ "$1" = --body-file ]; then cp -- "$2" "$GH_DIR/body"; fi
	shift
done
if [ "$key" = api ]; then
	cat "$GH_DIR/pulls" 2>/dev/null || echo '[]'
fi
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/gh"
	export PATH=$BATS_TEST_TMPDIR/bin:$PATH
}

# pin_origin: creates the bare repository origin.git whose main holds two
# commits with config.yaml, pinned to OLD, and scripts/ of the repository.
pin_origin() {
	local seed=$BATS_TEST_TMPDIR/seed
	test_git init --quiet -- "$seed"
	cp -R -- "$SANDBOX_ROOT/scripts" "$SANDBOX_ROOT/config.yaml" "$seed/"
	SHA=$OLD yq -i '.upstream.cobaltcore = strenv(SHA)' "$seed/config.yaml"
	test_git -C "$seed" add -A
	test_git -C "$seed" commit --quiet -m first
	echo second >"$seed/README.md"
	test_git -C "$seed" add -A
	test_git -C "$seed" commit --quiet -m second
	git clone --quiet --bare -- "$seed" "$BATS_TEST_TMPDIR/origin.git"
	ORIGIN=$BATS_TEST_TMPDIR/origin.git
}

# work_tree <directory>: clones main of origin at depth 1, as the checkout
# of the workflow does, and moves the pin in its config.yaml to NEW.
work_tree() {
	git clone --quiet --depth 1 -- "file://$ORIGIN" "$1"
	SHA=$NEW yq -i '.upstream.cobaltcore = strenv(SHA)' "$1/config.yaml"
}

# propose <directory> <result> <log file>: runs propose in the work tree.
propose() {
	run "$1/scripts/pin.sh" propose "$OLD" "$NEW" "$2" "$3"
}

# origin_git <argument>...: runs git on origin.
origin_git() {
	git --git-dir="$ORIGIN" "$@"
}

# person_clone: clones origin into person, a work tree of someone else.
person_clone() {
	git clone --quiet -- "file://$ORIGIN" "$BATS_TEST_TMPDIR/person"
}

# push_fix: pushes a commit of someone else onto upstream-pin of origin.
push_fix() {
	person_clone
	test_git -C "$BATS_TEST_TMPDIR/person" checkout --quiet -b upstream-pin
	echo fix >"$BATS_TEST_TMPDIR/person/fix.txt"
	test_git -C "$BATS_TEST_TMPDIR/person" add fix.txt
	test_git -C "$BATS_TEST_TMPDIR/person" commit --quiet -m fix
	git -C "$BATS_TEST_TMPDIR/person" push --quiet origin upstream-pin
}

@test "move sets the pin to the tip of main of upstream and changes one line" {
	upstream_repo
	config_with ".upstream.cobaltcore = \"$OLD\""
	cp -- "$SANDBOX_CONFIG" "$BATS_TEST_TMPDIR/before.yaml"
	run "$SANDBOX_ROOT/scripts/pin.sh" move
	[ "$status" -eq 0 ]
	[ "$output" = "pin: upstream.cobaltcore $OLD -> $UPSTREAM_SECOND" ]
	[ "$(diff "$BATS_TEST_TMPDIR/before.yaml" "$SANDBOX_CONFIG" | grep -c '^>')" -eq 1 ]
	[ "$(diff "$BATS_TEST_TMPDIR/before.yaml" "$SANDBOX_CONFIG" | grep '^>')" = ">   cobaltcore: $UPSTREAM_SECOND" ]

	cp -- "$SANDBOX_CONFIG" "$BATS_TEST_TMPDIR/moved.yaml"
	run "$SANDBOX_ROOT/scripts/pin.sh" move
	[ "$status" -eq 0 ]
	[ "$output" = "pin: upstream.cobaltcore is already $UPSTREAM_SECOND" ]
	cmp -- "$BATS_TEST_TMPDIR/moved.yaml" "$SANDBOX_CONFIG"
}

@test "move takes a commit as its argument and refuses one that is not a full SHA" {
	config_with ".upstream.cobaltcore = \"$OLD\""
	run "$SANDBOX_ROOT/scripts/pin.sh" move "$NEW"
	[ "$status" -eq 0 ]
	[ "$(yq '.upstream.cobaltcore' "$SANDBOX_CONFIG")" = "$NEW" ]

	run "$SANDBOX_ROOT/scripts/pin.sh" move abc
	[ "$status" -eq 1 ]
	[ "$output" = "error: pin: 'abc' is not a commit SHA of 40 hex characters" ]
}

@test "move fails for an unreachable upstream and for one without main" {
	config_with ".upstream.cobaltcore = \"$OLD\""
	export SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/missing
	run "$SANDBOX_ROOT/scripts/pin.sh" move
	[ "$status" -eq 1 ]
	[[ $output == "error: pin: cannot read refs/heads/main of file://$BATS_TEST_TMPDIR/missing: "?* ]]

	test_git init --quiet -- "$BATS_TEST_TMPDIR/nomain"
	test_git -C "$BATS_TEST_TMPDIR/nomain" commit --quiet --allow-empty -m other
	test_git -C "$BATS_TEST_TMPDIR/nomain" branch --quiet -m other
	export SANDBOX_UPSTREAM_URL=file://$BATS_TEST_TMPDIR/nomain
	run "$SANDBOX_ROOT/scripts/pin.sh" move
	[ "$status" -eq 1 ]
	[ "$output" = "error: pin: file://$BATS_TEST_TMPDIR/nomain has no branch main" ]
	[ "$(yq '.upstream.cobaltcore' "$SANDBOX_CONFIG")" = "$OLD" ]
}

@test "a missing subcommand, a result other than passed or failed and a missing log file are usage errors" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	run "$BATS_TEST_TMPDIR/work/scripts/pin.sh"
	[ "$status" -eq 2 ]
	[ "$output" = "$USAGE" ]

	propose "$BATS_TEST_TMPDIR/work" maybe "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 2 ]
	[ "$output" = "$USAGE" ]
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/missing.log"
	[ "$status" -eq 2 ]
	[ "$output" = "$USAGE" ]
	run "$BATS_TEST_TMPDIR/work/scripts/pin.sh" propose abc "$NEW" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 2 ]
	[ ! -e "$GH_DIR/calls" ]
	! origin_git rev-parse --verify --quiet refs/heads/upstream-pin
}

@test "propose pushes one commit of the bot with config.yaml alone, opens the pull request and starts the validation" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	echo 'validate: all checks passed' >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[ "$(origin_git log --format='%an <%ae> %cn <%ce>' main..upstream-pin)" = \
		"github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ]
	[ "$(origin_git show --format= --name-only upstream-pin)" = config.yaml ]
	[ "$(origin_git show upstream-pin:config.yaml | yq '.upstream.cobaltcore')" = "$NEW" ]
	[ "$(origin_git log -1 --format=%B upstream-pin)" = "Move the upstream pin to bbb35e61

C5C3/cobaltcore $OLD -> $NEW
https://github.com/C5C3/cobaltcore/compare/$OLD...$NEW" ]
	[ -z "$(origin_git log -1 --format='%(trailers)' upstream-pin)" ]
	[ "$(sed -n 1p "$GH_DIR/calls")" = "$LIST_CALL" ]
	[[ $(sed -n 2p "$GH_DIR/calls") == "pr create --base main --head upstream-pin --title Move the upstream pin to bbb35e61 --body-file "?* ]]
	[ "$(sed -n 3p "$GH_DIR/calls")" = "workflow run validate.yaml --ref upstream-pin" ]
	[ "$(wc -l <"$GH_DIR/calls")" -eq 3 ]
}

@test "the body holds both commits, the compare URL, the result and the last 40 lines of the log" {
	local i
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	for ((i = 1; i <= 60; i++)); do echo "line $i"; done >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" failed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	grep -qxF "C5C3/cobaltcore $OLD -> $NEW" "$GH_DIR/body"
	grep -qxF "https://github.com/C5C3/cobaltcore/compare/$OLD...$NEW" "$GH_DIR/body"
	grep -qxF '`make validate` against the new checkout: failed' "$GH_DIR/body"
	grep -qxF 'line 21' "$GH_DIR/body"
	grep -qxF 'line 60' "$GH_DIR/body"
	! grep -qxF 'line 20' "$GH_DIR/body"
	grep -qxF 'A failed validation is fixed with commits on this branch; the workflow replaces the branch only while every commit on it is its own.' "$GH_DIR/body"
}

@test "an empty log gives an empty block" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	grep -qxF '`make validate` against the new checkout: passed' "$GH_DIR/body"
	[ "$(grep -A1 -xF '```text' "$GH_DIR/body")" = '```text
```' ]
}

@test "propose edits an open pull request instead of creating one" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	echo '[{"number": 7}]' >"$GH_DIR/pulls"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[[ $(sed -n 2p "$GH_DIR/calls") == "pr edit 7 --title Move the upstream pin to bbb35e61 --body-file "?* ]]
	! grep -q '^pr create' "$GH_DIR/calls"
	# The branch was pushed, so the validation starts.
	[ "$(sed -n 3p "$GH_DIR/calls")" = "workflow run validate.yaml --ref upstream-pin" ]
}

@test "propose leaves a branch with a commit of someone else and an open pull request as it is" {
	local before
	fake_gh
	pin_origin
	push_fix
	before=$(origin_git rev-parse upstream-pin)
	echo '[{"number": 7}]' >"$GH_DIR/pulls"

	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[ "$output" = "pin: branch upstream-pin carries commits of others, left as it is" ]
	[ "$(origin_git rev-parse upstream-pin)" = "$before" ]
	[ "$(cat "$GH_DIR/calls")" = "$LIST_CALL" ]
}

@test "propose fails for a branch with a commit of someone else and no open pull request, and leaves it as it is" {
	local before
	fake_gh
	pin_origin
	push_fix
	before=$(origin_git rev-parse upstream-pin)

	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 1 ]
	[ "$output" = "error: pin: branch upstream-pin carries commits of others and has no open pull request; open one or delete the branch" ]
	[ "$(origin_git rev-parse upstream-pin)" = "$before" ]
	[ "$(wc -l <"$GH_DIR/calls")" -eq 1 ]
}

@test "propose leaves out the pull requests from forks whose branch is named upstream-pin" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	# GitHub matches head <owner>:<branch> on the server, so no number of
	# forks pushes the pull request of the bot off the page; gh fills in
	# {owner} with the owner of this repository.
	[[ $(sed -n 1p "$GH_DIR/calls") == "api repos/{owner}/{repo}/pulls?"*"&head={owner}:upstream-pin" ]]
}

@test "propose replaces a branch of the bot that proposes an older pin" {
	local older=0123456789abcdef0123456789abcdef01234567 before
	fake_gh
	pin_origin
	: >"$BATS_TEST_TMPDIR/validate.log"
	work_tree "$BATS_TEST_TMPDIR/first"
	SHA=$older yq -i '.upstream.cobaltcore = strenv(SHA)' "$BATS_TEST_TMPDIR/first/config.yaml"
	run "$BATS_TEST_TMPDIR/first/scripts/pin.sh" propose "$OLD" "$older" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	before=$(origin_git rev-parse upstream-pin)
	rm -- "$GH_DIR/calls"

	echo '[{"number": 7}]' >"$GH_DIR/pulls"
	work_tree "$BATS_TEST_TMPDIR/second"
	propose "$BATS_TEST_TMPDIR/second" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[ "$(origin_git rev-parse upstream-pin)" != "$before" ]
	[ "$(origin_git rev-list --count main..upstream-pin)" -eq 1 ]
	[ "$(origin_git show upstream-pin:config.yaml | yq '.upstream.cobaltcore')" = "$NEW" ]
	[[ $(sed -n 2p "$GH_DIR/calls") == "pr edit 7 "* ]]
	[ "$(sed -n 3p "$GH_DIR/calls")" = "workflow run validate.yaml --ref upstream-pin" ]
}

@test "propose pushes a branch of the bot that proposes the pin on an older main again" {
	local before
	fake_gh
	pin_origin
	: >"$BATS_TEST_TMPDIR/validate.log"
	work_tree "$BATS_TEST_TMPDIR/first"
	propose "$BATS_TEST_TMPDIR/first" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	before=$(origin_git rev-parse upstream-pin)
	rm -- "$GH_DIR/calls"

	person_clone
	echo third >"$BATS_TEST_TMPDIR/person/README.md"
	test_git -C "$BATS_TEST_TMPDIR/person" commit --quiet -am third
	git -C "$BATS_TEST_TMPDIR/person" push --quiet origin main
	echo '[{"number": 7}]' >"$GH_DIR/pulls"
	work_tree "$BATS_TEST_TMPDIR/second"
	propose "$BATS_TEST_TMPDIR/second" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[ "$(origin_git rev-parse upstream-pin)" != "$before" ]
	origin_git merge-base --is-ancestor main upstream-pin
	[ "$(origin_git rev-list --count main..upstream-pin)" -eq 1 ]
	[ "$(sed -n 3p "$GH_DIR/calls")" = "workflow run validate.yaml --ref upstream-pin" ]
}

@test "propose does not push a branch that already proposes the pin and starts the validation only for a new pull request" {
	local before
	fake_gh
	pin_origin
	: >"$BATS_TEST_TMPDIR/validate.log"
	work_tree "$BATS_TEST_TMPDIR/first"
	propose "$BATS_TEST_TMPDIR/first" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	before=$(origin_git rev-parse upstream-pin)
	rm -- "$GH_DIR/calls"

	# The pull request of the first run is open.
	echo '[{"number": 7}]' >"$GH_DIR/pulls"
	work_tree "$BATS_TEST_TMPDIR/second"
	propose "$BATS_TEST_TMPDIR/second" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[[ $output == *"pin: branch upstream-pin already proposes $NEW"* ]]
	[ "$(origin_git rev-parse upstream-pin)" = "$before" ]
	[[ $(sed -n 2p "$GH_DIR/calls") == "pr edit 7 "* ]]
	! grep -q '^workflow run' "$GH_DIR/calls"
	rm -- "$GH_DIR/calls"

	# The first run could not open it.
	echo '[]' >"$GH_DIR/pulls"
	work_tree "$BATS_TEST_TMPDIR/third"
	propose "$BATS_TEST_TMPDIR/third" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 0 ]
	[ "$(origin_git rev-parse upstream-pin)" = "$before" ]
	[[ $(sed -n 2p "$GH_DIR/calls") == "pr create "* ]]
	[ "$(sed -n 3p "$GH_DIR/calls")" = "workflow run validate.yaml --ref upstream-pin" ]
}

@test "propose fails with the last line of gh when it cannot open the pull request, with the branch pushed" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	printf 'first line\nGitHub Actions is not permitted to create or approve pull requests.\n' >"$GH_DIR/pr-create.fail"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: pin: cannot open the pull request: GitHub Actions is not permitted to create or approve pull requests." ]
	[ "$(origin_git show upstream-pin:config.yaml | yq '.upstream.cobaltcore')" = "$NEW" ]
	! grep -q '^workflow run' "$GH_DIR/calls"
}

@test "propose fails with the last line of gh when it cannot list or update the pull request" {
	fake_gh
	pin_origin
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	echo 'HTTP 502: Bad Gateway' >"$GH_DIR/api.fail"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: pin: cannot list the pull requests of upstream-pin: HTTP 502: Bad Gateway" ]
	! grep -q '^pr \(create\|edit\)' "$GH_DIR/calls"

	rm -- "$GH_DIR/api.fail"
	echo '[{"number": 7}]' >"$GH_DIR/pulls"
	echo 'HTTP 403: Resource not accessible by integration' >"$GH_DIR/pr-edit.fail"
	work_tree "$BATS_TEST_TMPDIR/again"
	propose "$BATS_TEST_TMPDIR/again" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: pin: cannot update the pull request #7: HTTP 403: Resource not accessible by integration" ]
}

@test "propose fails with the last line of git when origin rejects the push" {
	fake_gh
	pin_origin
	printf '#!/bin/sh\necho "push rejected by policy" >&2\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
	chmod +x "$ORIGIN/hooks/pre-receive"
	work_tree "$BATS_TEST_TMPDIR/work"
	: >"$BATS_TEST_TMPDIR/validate.log"
	propose "$BATS_TEST_TMPDIR/work" passed "$BATS_TEST_TMPDIR/validate.log"
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = "error: pin: cannot push the branch upstream-pin: error: failed to push some refs to 'file://$ORIGIN'" ]
	[ ! -e "$GH_DIR/calls" ]
}
