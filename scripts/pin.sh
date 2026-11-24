#!/usr/bin/env bash
# Usage: pin.sh move [<commit>]
#        pin.sh propose <old> <new> <passed|failed> <log file>
#
# The steps of .github/workflows/upstream-pin.yaml, which moves the pin of
# C5C3/cobaltcore to upstream main once a day.
#
# move sets upstream.cobaltcore of the configuration to the commit, by
# default the tip of main of SANDBOX_UPSTREAM_URL, and changes nothing when
# it is the pin already.
#
# propose publishes the move from a work tree whose config.yaml holds the new
# pin, uncommitted. It commits config.yaml alone as github-actions[bot] on the
# branch upstream-pin, pushes it to origin, opens or updates its pull request
# with the result and the end of the log of make validate, and starts the
# workflow validate on the branch, because a pull request opened with the
# token of a workflow starts no workflow. A branch that carries a commit of
# someone else is left as it is while its pull request is open, and a branch
# that already proposes the new pin is not pushed again. It needs gh with a
# token.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/vendor.sh
. "$SANDBOX_ROOT/scripts/lib/vendor.sh"

readonly BRANCH=upstream-pin
readonly BOT_NAME='github-actions[bot]'
readonly BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
# The lines of the log of make validate in the body of the pull request.
readonly LOG_TAIL_LINES=40

usage() {
	echo "usage: scripts/pin.sh move [<commit>] | propose <old> <new> <passed|failed> <log file>" >&2
	exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
errfile=$tmp/err

# error_line: prints the last line of the error output of the last call.
error_line() {
	_last_line "$(<"$errfile")"
}

# open_pull_request: prints the number of the open pull request of the
# branch into main, or nothing. The head <owner>:<branch> makes GitHub leave
# out the pull requests from forks with a branch of that name, however many
# there are; gh fills in {owner} and {repo}.
open_pull_request() {
	local out
	out=$(gh api "repos/{owner}/{repo}/pulls?state=open&base=main&head={owner}:$BRANCH" 2>"$errfile") ||
		die "pin: cannot list the pull requests of $BRANCH: $(error_line)"
	jq -r '.[0].number // empty' <<<"$out"
}

# pin_move [<commit>]: sets upstream.cobaltcore to the commit.
pin_move() {
	local config=${SANDBOX_CONFIG:-$SANDBOX_ROOT/config.yaml} commit out old
	if [ "$#" -eq 0 ]; then
		out=$(git ls-remote "$SANDBOX_UPSTREAM_URL" refs/heads/main 2>"$errfile") ||
			die "pin: cannot read refs/heads/main of $SANDBOX_UPSTREAM_URL: $(error_line)"
		commit=${out%%[[:space:]]*}
		[ -n "$commit" ] || die "pin: $SANDBOX_UPSTREAM_URL has no branch main"
	else
		commit=$1
		[[ $commit =~ $SANDBOX_SHA_RE ]] || die "pin: '$commit' is not a commit SHA of 40 hex characters"
	fi
	old=$(yq '.upstream.cobaltcore' "$config")
	if [ "$commit" = "$old" ]; then
		log "upstream.cobaltcore is already $commit"
		return
	fi
	SHA=$commit yq -i '.upstream.cobaltcore = strenv(SHA)' "$config"
	log "upstream.cobaltcore $old -> $commit"
}

# pin_propose <old> <new> <passed|failed> <log file>: publishes the move.
pin_propose() {
	local old=$1 new=$2 result=$3 tail subject compare rc=0 lease='' shallow=() refspecs number pushed=false created=false
	local authors body=$tmp/body
	tail=$(tail -n "$LOG_TAIL_LINES" -- "$4")
	subject="Move the upstream pin to ${new:0:8}"
	compare=$SANDBOX_UPSTREAM_URL/compare/$old...$new
	cd -- "$SANDBOX_ROOT"

	git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>"$errfile" || rc=$?
	case $rc in
	0) refspecs=("+refs/heads/main:refs/remotes/origin/main" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH") ;;
	2) refspecs=("+refs/heads/main:refs/remotes/origin/main") ;;
	*) die "pin: cannot read the branches of origin: $(error_line)" ;;
	esac
	# The range below and merge-base need the history a shallow checkout lacks.
	if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
		shallow=(--unshallow)
	fi
	git fetch --quiet "${shallow[@]}" origin "${refspecs[@]}" 2>"$errfile" ||
		die "pin: cannot fetch from origin: $(error_line)"

	if [ "$rc" -eq 0 ]; then
		lease=$(git rev-parse "refs/remotes/origin/$BRANCH")
		# A fix that a person pushed is never overwritten. Such a branch
		# without an open pull request, left by a squash merge or a close,
		# would hold back every later proposal, so the run fails.
		authors=$(git log --format=%ae "refs/remotes/origin/main..refs/remotes/origin/$BRANCH")
		if [ -n "$authors" ] && grep -qvxF -- "$BOT_EMAIL" <<<"$authors"; then
			number=$(open_pull_request) || exit 1
			[ -n "$number" ] ||
				die "pin: branch $BRANCH carries commits of others and has no open pull request; open one or delete the branch"
			log "branch $BRANCH carries commits of others, left as it is"
			return
		fi
	fi

	if [ "$rc" -eq 0 ] &&
		[ "$(git show "refs/remotes/origin/$BRANCH:config.yaml" | yq '.upstream.cobaltcore')" = "$new" ] &&
		git merge-base --is-ancestor refs/remotes/origin/main "refs/remotes/origin/$BRANCH"; then
		log "branch $BRANCH already proposes $new"
	else
		git checkout --quiet -B "$BRANCH"
		GIT_AUTHOR_NAME=$BOT_NAME GIT_AUTHOR_EMAIL=$BOT_EMAIL GIT_COMMITTER_NAME=$BOT_NAME GIT_COMMITTER_EMAIL=$BOT_EMAIL \
			git commit --quiet -F - -- config.yaml <<EOF
$subject

C5C3/cobaltcore $old -> $new
$compare
EOF
		git push --quiet "--force-with-lease=$BRANCH:$lease" origin "HEAD:refs/heads/$BRANCH" 2>"$errfile" ||
			die "pin: cannot push the branch $BRANCH: $(error_line)"
		log "pushed the branch $BRANCH"
		pushed=true
	fi

	cat >"$body" <<EOF
C5C3/cobaltcore $old -> $new
$compare

\`make validate\` against the new checkout: $result

\`\`\`text
${tail:+$tail
}\`\`\`

A failed validation is fixed with commits on this branch; the workflow replaces the branch only while every commit on it is its own.
EOF
	number=$(open_pull_request) || exit 1
	if [ -n "$number" ]; then
		gh pr edit "$number" --title "$subject" --body-file "$body" 2>"$errfile" ||
			die "pin: cannot update the pull request #$number: $(error_line)"
	else
		gh pr create --base main --head "$BRANCH" --title "$subject" --body-file "$body" 2>"$errfile" ||
			die "pin: cannot open the pull request: $(error_line)"
		created=true
	fi

	if $pushed || $created; then
		gh workflow run validate.yaml --ref "$BRANCH" 2>"$errfile" ||
			die "pin: cannot start the workflow validate on $BRANCH: $(error_line)"
		log "started the workflow validate on $BRANCH"
	fi
}

case ${1:-} in
move)
	shift
	[ "$#" -le 1 ] || usage
	pin_move "$@"
	;;
propose)
	shift
	if [ "$#" -ne 4 ] || ! [[ $1 =~ $SANDBOX_SHA_RE && $2 =~ $SANDBOX_SHA_RE ]] ||
		! [[ $3 == passed || $3 == failed ]] || [ ! -f "$4" ]; then
		usage
	fi
	pin_propose "$@"
	;;
*) usage ;;
esac
