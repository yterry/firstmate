#!/usr/bin/env bash
# Scenario 3: the armed poll wakes only for this pull request's real completion.
. "$(dirname "$0")/lab-lib.sh"
new_lab s3-watch
open_ready_pr watch1
run_check arm watch1 "$PR_URL"
check "armed" test "$CHECK_RC" -eq 0
F="$SIM/prs/$PR_ID.json"; cp "$F" "$LAB/pr.active.json"
setpr() { jq "$@" "$LAB/pr.active.json" > "$F"; }
MERGE=7777777777777777777777777777777777777777

say "active"
run_poll watch1; check "active: silent" test -z "$POLL_OUT"
say "abandoned"
setpr '.status = "abandoned"'
run_poll watch1; check "abandoned: silent" test -z "$POLL_OUT"
say "completed, but the record names no completion commit"
setpr '.status = "completed"'
run_poll watch1; check "completed without lastMergeCommit: silent" test -z "$POLL_OUT"
say "completed, with a malformed completion commit"
setpr '.status = "completed" | .lastMergeCommit = {commitId: "not-a-sha"}'
run_poll watch1; check "completed with a malformed lastMergeCommit: silent" test -z "$POLL_OUT"
say "completed with a completion commit, but the id reads back as another repository's pull request"
setpr --arg m "$MERGE" '.status = "completed" | .lastMergeCommit = {commitId: $m} | .repository.name = "some-other-repo"'
run_poll watch1; check "another repository's completed pull request: silent" test -z "$POLL_OUT"
say "completed with a completion commit, in another project"
setpr --arg m "$MERGE" '.status = "completed" | .lastMergeCommit = {commitId: $m} | .repository.project.name = "Another Project"'
run_poll watch1; check "another project's completed pull request: silent" test -z "$POLL_OUT"
say "the forge read fails"
setpr --arg m "$MERGE" '.status = "completed" | .lastMergeCommit = {commitId: $m}'
printf '1\n' > "$SIM/hooks/show-failures"
run_poll watch1; check "unreadable answer: silent" test -z "$POLL_OUT"
say "a doctored sidecar that points the same poll at another repository"
cp "$HOME_DIR/state/watch1.pr-poll" "$LAB/pr-poll.orig"
sed "4s|.*|DefaultCollection/$PROJECT_ENC/_git/some-other-repo|" "$LAB/pr-poll.orig" > "$HOME_DIR/state/watch1.pr-poll"
: > "$SIM/az.log"
run_poll watch1; check "doctored sidecar: silent" test -z "$POLL_OUT"
check "doctored sidecar: the forge is never asked" test ! -s "$SIM/az.log"
cp "$LAB/pr-poll.orig" "$HOME_DIR/state/watch1.pr-poll"
say "this pull request, completed, with its completion commit"
run_poll watch1; check "real completion: prints merged" test "$POLL_OUT" = merged
check "the poll reads with --detect false through the URL's organization" grep -qF -- "repos pr show --id $PR_ID --organization $ORG_URL_VS --detect false --only-show-errors --output json" "$SIM/az.log"
finish
