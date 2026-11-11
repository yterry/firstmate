#!/usr/bin/env bash
# Scenario 8: a home that opted in to main's degraded watch (config/pr-degraded-watch)
# still arms, watches, completes, and re-arms an Azure DevOps pull request.
. "$(dirname "$0")/lab-lib.sh"
new_lab s8-degraded-watch-home
touch "$HOME_DIR/config/pr-degraded-watch"
show ls "$HOME_DIR/config"
open_ready_pr deg1
: > "$SIM/az.log"
worker_report_done deg1 "$PR_URL"
printf '$ fm-pr-check.sh scan\n'; SCAN=$(fm fm-pr-check.sh scan 2>&1); printf '%s\n[%s bytes]\n' "$SCAN" "${#SCAN}"
check "the reported pull request is recorded with the degraded watch enabled" grep -qxF "pr=$PR_URL" "$HOME_DIR/state/deg1.meta"
check "its poll is armed and byte-identical to bin/fm-pr-poll.sh" cmp -s "$HOME_DIR/state/deg1.check.sh" "$BIN/fm-pr-poll.sh"
check "no degraded or merge-train marker is left for Azure DevOps" bash -c "[ ! -e '$HOME_DIR/state/deg1.pr-poll-degraded' ] && [ ! -e '$HOME_DIR/state/deg1.pr-poll-train' ]"
check "no registration backup directory is left behind" bash -c "! ls -d '$HOME_DIR'/state/.fm-pr-baseline.* >/dev/null 2>&1"
run_poll deg1
check "active: silent (no degraded line for Azure DevOps)" test -z "$POLL_OUT"

say "re-arming the same pull request while the forge read is failing keeps the registration"
printf '5\n' > "$SIM/hooks/show-failures"
run_check rearm deg1 "$PR_URL"
rm -f "$SIM/hooks/show-failures"
check "an unreadable forge does not drop the recorded pull request" grep -qxF "pr=$PR_URL" "$HOME_DIR/state/deg1.meta"
check "the poll is still armed" test -f "$HOME_DIR/state/deg1.check.sh"

say "a draft is still refused with the degraded watch enabled, and nothing is recorded"
add_task deg2; worker_commit deg2 d.txt d "draft work"; worker_push deg2; worker_open_pr deg2 --draft true
run_check draft deg2 "$PR_URL"
check "draft refused" bash -c "[ $CHECK_RC -ne 0 ] && grep -q 'is a draft pull request' '$LAB/draft.err'"
check "nothing recorded or armed for the draft" bash -c "! grep -q '^pr=' '$HOME_DIR/state/deg2.meta' && [ ! -e '$HOME_DIR/state/deg2.check.sh' ]"

say "completion and the merged wake"
PR_ID=$(sed -n 5p "$HOME_DIR/state/deg1.pr-poll"); PR_URL=$(sed -n 2p "$HOME_DIR/state/deg1.pr-poll")
run_merge merge deg1 "$PR_URL" -- --squash
check "completes" bash -c "[ $MERGE_RC -eq 0 ] && grep -q 'is completed from head' '$LAB/merge.out'"
run_poll deg1
check "merged" test "$POLL_OUT" = merged
finish
