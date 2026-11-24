# shellcheck shell=bash
# The checkout of C5C3/cobaltcore in vendor/cobaltcore. Source
# scripts/lib/common.sh first.
#
# The checkout holds the paths of SANDBOX_VENDOR_PATHS at one commit, the pin
# of the configuration. Every git call on it goes through vendor_git: a plain
# git -C vendor/cobaltcore walks up into the repository of the sandbox when
# the checkout has no .git.

SANDBOX_UPSTREAM_URL=${SANDBOX_UPSTREAM_URL:-https://github.com/C5C3/cobaltcore}
SANDBOX_VENDOR_DIR=$SANDBOX_ROOT/vendor/cobaltcore
# The sparse-checkout patterns of the checkout. A module that reads another
# path of upstream adds its pattern here.
SANDBOX_VENDOR_PATHS=('/deploy/' '/operators/*/config/crd/bases/')

# vendor_git <argument>...: runs git on the checkout, from inside it. git
# looks for the files the sparse checkout leaves out relative to the current
# directory, so from the root of the sandbox it would take its README.md for
# the one of upstream.
vendor_git() {
	git -C "$SANDBOX_VENDOR_DIR" --git-dir="$SANDBOX_VENDOR_DIR/.git" --work-tree="$SANDBOX_VENDOR_DIR" "$@"
}

# vendor_commit: prints the commit of the checkout. It returns 1 without
# output when the checkout has no .git or no commit.
vendor_commit() {
	[ -e "$SANDBOX_VENDOR_DIR/.git" ] || return 1
	vendor_git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null
}

# _vendor_changes: prints each path of the checkout that is staged, changed,
# deleted or untracked, one per line, sorted. It reads no .gitignore, unlike
# git status: the artifact carries an ignored file too, and the .gitignore of
# upstream lies outside the sparse paths, so its content would have to be
# fetched. The diff detects no renames, which would need the content of the
# files.
_vendor_changes() {
	{
		vendor_git diff --cached --name-only --no-renames -- &&
			vendor_git ls-files --modified --others
	} | LC_ALL=C sort -u || die "vendor: cannot read the status of $SANDBOX_VENDOR_DIR"
}

# vendor_modified: succeeds when the checkout has a staged, a changed, a
# deleted or an untracked file, or when HEAD is not the commit vendor_fetch
# checked out, as after a commit in the checkout. A checkout that
# vendor_fetch did not make has no such record, and only its files count.
vendor_modified() {
	local out checkout
	out=$(_vendor_changes) || exit 1
	[ -z "$out" ] || return 0
	checkout=$(vendor_git rev-parse --verify --quiet refs/sandbox/checkout) || return 1
	[ "$(vendor_git rev-parse --verify --quiet HEAD)" != "$checkout" ]
}

# vendor_record: prints the commit of the checkout, followed by -modified
# when it has local changes. It returns 1 when vendor_commit does.
vendor_record() {
	local commit
	commit=$(vendor_commit) || return 1
	if vendor_modified; then
		printf '%s-modified\n' "$commit"
	else
		printf '%s\n' "$commit"
	fi
}

# vendor_fetch <commit>: makes the checkout the commit, from
# SANDBOX_UPSTREAM_URL, with the paths of SANDBOX_VENDOR_PATHS, discards
# every local change and records the commit in refs/sandbox/checkout. A
# checkout that already holds the commit and its paths needs no network. A
# failed run leaves a directory that the next run completes.
vendor_fetch() {
	local commit=$1 out line
	if [ -e "$SANDBOX_VENDOR_DIR" ] && [ ! -e "$SANDBOX_VENDOR_DIR/.git" ]; then
		die "vendor: $SANDBOX_VENDOR_DIR exists and is not a checkout of make vendor; remove it"
	fi
	if [ ! -e "$SANDBOX_VENDOR_DIR/.git" ]; then
		out=$(git -c init.defaultBranch=main init --quiet -- "$SANDBOX_VENDOR_DIR" 2>&1) ||
			die "vendor: cannot create $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
	fi
	vendor_git config remote.origin.url "$SANDBOX_UPSTREAM_URL"
	out=$(vendor_git sparse-checkout set --no-cone "${SANDBOX_VENDOR_PATHS[@]}" 2>&1) ||
		die "vendor: cannot check out $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"

	out=$(_vendor_changes) || exit 1
	while IFS= read -r line; do
		if [ -n "$line" ]; then
			log "discarding $line"
		fi
	done <<<"$out"

	# In a checkout fetched with a filter, cat-file would fetch a missing
	# commit with its whole history; GIT_NO_LAZY_FETCH turns that off.
	if ! GIT_NO_LAZY_FETCH=1 vendor_git cat-file -e "$commit^{commit}" 2>/dev/null; then
		out=$(vendor_git fetch --quiet --depth 1 --filter=blob:none origin "$commit" 2>&1) ||
			die "vendor: cannot fetch $commit from $SANDBOX_UPSTREAM_URL: $(_last_line "$out")"
	fi
	# A run that stops before the record leaves none, so vendor_modified
	# counts only the files and the next run does not take the new HEAD for
	# a local commit.
	out=$(vendor_git update-ref -d refs/sandbox/checkout 2>&1) ||
		die "vendor: cannot check out $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
	out=$(vendor_git checkout --quiet --force --detach "$commit" 2>&1) ||
		die "vendor: cannot check out $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
	out=$(vendor_git clean -ffdxq 2>&1) ||
		die "vendor: cannot check out $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
	out=$(vendor_git update-ref refs/sandbox/checkout "$commit" 2>&1) ||
		die "vendor: cannot check out $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
}

# ensure_vendor: makes the checkout SANDBOX_UPSTREAM_COMMIT with the paths of
# SANDBOX_VENDOR_PATHS unless it is that already. It never discards a local
# change: a checkout with local changes at another commit or with other
# paths stops the run.
ensure_vendor() {
	local pin=$SANDBOX_UPSTREAM_COMMIT commit out
	if ! commit=$(vendor_commit); then
		log "checking out C5C3/cobaltcore at $pin into vendor/cobaltcore"
		vendor_fetch "$pin"
		return
	fi
	# A checkout that is not sparse lists no paths.
	if [ "$commit" = "$pin" ] &&
		[ "$(vendor_git sparse-checkout list 2>/dev/null)" != "$(printf '%s\n' "${SANDBOX_VENDOR_PATHS[@]}")" ]; then
		if vendor_modified; then
			die "vendor: vendor/cobaltcore has local changes and other paths than SANDBOX_VENDOR_PATHS; run make vendor to discard them"
		fi
		log "checking out the paths of SANDBOX_VENDOR_PATHS in vendor/cobaltcore"
		vendor_fetch "$pin"
		return
	fi
	if [ "$commit" = "$pin" ]; then
		if vendor_modified; then
			log "vendor/cobaltcore is at $commit with local changes, left as it is"
		else
			# A vendor_fetch that stopped after the checkout left no record.
			# HEAD is the pin and no file changed, so the checkout is the pin,
			# and the record lets vendor_modified see a later commit in it.
			if ! vendor_git rev-parse --verify --quiet refs/sandbox/checkout >/dev/null; then
				out=$(vendor_git update-ref refs/sandbox/checkout "$commit" "" 2>&1) ||
					die "vendor: cannot record $commit in $SANDBOX_VENDOR_DIR: $(_last_line "$out")"
			fi
			log "vendor/cobaltcore is at $commit"
		fi
		return
	fi
	if vendor_modified; then
		die "vendor: vendor/cobaltcore is at $commit with local changes, the configuration pins $pin; run make vendor to discard them"
	fi
	log "moving vendor/cobaltcore from $commit to $pin"
	vendor_fetch "$pin"
}
