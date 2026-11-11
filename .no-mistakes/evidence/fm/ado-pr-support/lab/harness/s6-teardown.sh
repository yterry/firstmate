#!/usr/bin/env bash
# Scenario 6: cleanup proceeds only when this pull request's completed record
# proves the local work landed.
. "$(dirname "$0")/lab-lib.sh"
new_lab s6-teardown
# after_merge_forge_state <id>: the source branch is deleted on the forge, main
# moves on over the same lines, and fleet sync prunes the clone.
after_merge_forge_state() {
  g -C "$ORIGIN" update-ref -d "refs/heads/fm/$1" 2>/dev/null || true
  git clone -q "$ORIGIN" "$LAB/_later"
  printf '%s\n' "reworded after $1" >> "$LAB/_later/shared.txt"
  printf '%s\n' "main rewrote this after $1" > "$LAB/_later/shared-$1.txt"
  g -C "$LAB/_later" add -A; g -C "$LAB/_later" commit -q -m "main moves on after $1"
  g -C "$LAB/_later" push -q origin main; rm -rf "$LAB/_later"
  git -C "$PROJ" fetch -q --prune origin
}
task_with_pr() {  # <id>: a pushed two-commit task with an armed, green pull request
  add_task "$1"
  worker_commit "$1" "feature-$1.txt" hello "add feature for $1"
  worker_commit "$1" "shared-$1.txt" "feature edit for $1" "edit shared file for $1"
  worker_push "$1"; worker_open_pr "$1"
  HEAD1=$(git -C "$WT" rev-parse HEAD); green_policies "$PR_ID" "$HEAD1"
}
still_there() {  # <label> <id>
  check "$1: the worktree is untouched" test -d "$LAB/wt-$2"
  check "$1: the task record is kept" test -f "$HOME_DIR/state/$2.meta"
  check "$1: the backlog item is not closed" bash -c "PATH='$FAKEBIN:$PATH' tasks-axi show '$2' --file '$HOME_DIR/data/backlog.md' | grep -q 'state: in-flight\|state: in_flight\|state: started\|state: in flight'"
  check "$1: the worktree was never handed back" bash -c "! grep -q 'treehouse return' '$LAB/stub.log'"
}
show_state() { PATH="$FAKEBIN:$PATH" tasks-axi show "$1" --file "$HOME_DIR/data/backlog.md" | sed -n 's/^  state: /backlog state: /p'; }

say "A. Completed, but the worker kept committing after the pull request's head"
task_with_pr later1; A_URL=$PR_URL
run_merge merge-a later1 "$A_URL" -- --squash
after_merge_forge_state later1
worker_commit later1 unlanded.txt "never in the pull request" "later local commit not in the pull request"
run_teardown td-later later1
show_state later1
check "later commit: teardown refuses" test "$TD_RC" -ne 0
check "later commit: says the work is not landed" grep -q 'REFUSED: worktree .* has work not on any remote and not landed' "$LAB/td-later.err"
check "later commit: lists the unlanded commit" grep -q 'later local commit not in the pull request' "$LAB/td-later.err"
still_there "later commit" later1

say "B. The pull request is still active (nothing completed), and its branch is gone from the forge"
task_with_pr active1
run_check arm-b active1 "$PR_URL"
after_merge_forge_state active1
: > "$SIM/az.log"
run_teardown td-active active1
check "active: teardown refuses" test "$TD_RC" -ne 0
check "active: the pull request was read through az" grep -qF "repos pr show --id $PR_ID --organization $ORG_URL_VS --detect false" "$SIM/az.log"
still_there "active" active1

say "C. The pull request was abandoned"
jq '.status = "abandoned"' "$SIM/prs/$PR_ID.json" > "$SIM/prs/$PR_ID.json.tmp" && mv "$SIM/prs/$PR_ID.json.tmp" "$SIM/prs/$PR_ID.json"
run_teardown td-abandoned active1
check "abandoned: teardown refuses" test "$TD_RC" -ne 0
still_there "abandoned" active1

say "D. The record says completed, but names no completion commit"
jq '.status = "completed" | .lastMergeCommit = null' "$SIM/prs/$PR_ID.json" > "$SIM/prs/$PR_ID.json.tmp" && mv "$SIM/prs/$PR_ID.json.tmp" "$SIM/prs/$PR_ID.json"
run_teardown td-nomerge active1
check "completed without a completion commit: teardown refuses" test "$TD_RC" -ne 0
still_there "completed without a completion commit" active1

say "E. The id reads back completed, but as another repository's pull request"
jq '.status = "completed" | .lastMergeCommit = {commitId: "7777777777777777777777777777777777777777"} | .repository.name = "some-other-repo"' \
  "$SIM/prs/$PR_ID.json" > "$SIM/prs/$PR_ID.json.tmp" && mv "$SIM/prs/$PR_ID.json.tmp" "$SIM/prs/$PR_ID.json"
run_teardown td-otherrepo active1
check "another repository's completed pull request: teardown refuses" test "$TD_RC" -ne 0
still_there "another repository's completed pull request" active1

say "F. The record completed from an older source commit than the local work"
task_with_pr older1; F_URL=$PR_URL F_ID=$PR_ID
run_merge merge-f older1 "$F_URL" -- --squash
after_merge_forge_state older1
OLD=$(git -C "$LAB/wt-older1" rev-parse HEAD~1)
jq --arg old "$OLD" '.lastMergeSourceCommit = {commitId: $old}' "$SIM/prs/$F_ID.json" > "$SIM/prs/$F_ID.json.tmp" && mv "$SIM/prs/$F_ID.json.tmp" "$SIM/prs/$F_ID.json"
printf 'the forge record now says it completed from %s, one commit behind the local head %s\n' "$OLD" "$(git -C "$LAB/wt-older1" rev-parse HEAD)"
run_teardown td-older older1
check "older source commit: teardown refuses" test "$TD_RC" -ne 0
still_there "older source commit" older1

say "G. Control: the same kind of task, completed from its real head, is cleaned up"
task_with_pr clean1; G_URL=$PR_URL G_ID=$PR_ID
run_merge merge-g clean1 "$G_URL" -- --squash
after_merge_forge_state clean1
: > "$SIM/az.log"; : > "$LAB/stub.log"
run_teardown td-clean clean1
show_state clean1
check "control: teardown succeeds" test "$TD_RC" -eq 0
check "control: the landed proof came from the pull request record" grep -qF "repos pr show --id $G_ID --organization $ORG_URL_VS --detect false" "$SIM/az.log"
check "control: the backlog item is closed with the pull request URL as a note" bash -c \
  "PATH='$FAKEBIN:$PATH' tasks-axi show clean1 --file '$HOME_DIR/data/backlog.md' --full | grep -qF 'Azure DevOps pull request $G_URL'"
finish
