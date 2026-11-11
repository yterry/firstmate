#!/usr/bin/env bash
# Scenario 7: the terminal passed-run detail reads the pull request's state.
# The no-mistakes run reading is a canned `axi status` answer (no pipeline can
# reach a real Azure DevOps organization here) and tmux is a stub that lists
# the task's window; bin/fm-crew-state.sh and the az read are the real path.
. "$(dirname "$0")/lab-lib.sh"
new_lab s7-crew-state
open_ready_pr crew1
# A no-mistakes-mode task, as the registry's default posture gives.
sed -i '' 's/^mode=direct-PR$/mode=no-mistakes/' "$HOME_DIR/state/crew1.meta"
printf 'pr=%s\n' "$PR_URL" >> "$HOME_DIR/state/crew1.meta"
printf 'fm-crew1\n' > "$LAB/tmux-windows"
cat > "$LAB/nm-status" <<NM
run:
  id: "01LABRUN"
  branch: fm/crew1
  status: completed
  head: "$HEAD1"
  pr: "$PR_URL"
  findings: none
outcome: passed
NM
F="$SIM/prs/$PR_ID.json"; cp "$F" "$LAB/pr.active.json"
state() {  # <label> <jq filter> <expected detail>
  jq "$2" "$LAB/pr.active.json" > "$F"
  : > "$SIM/az.log"
  printf '$ fm-crew-state.sh crew1   (pull request %s)\n' "$1"
  OUT=$(fm fm-crew-state.sh crew1 2>&1); printf '%s\n' "$OUT"
  check "$1: reports '$3'" bash -c "printf '%s' \"\$1\" | grep -qF -- \"\$2\"" _ "$OUT" "$3"
  check "$1: read through az by id in the URL's organization" grep -qF -- "repos pr show --id $PR_ID --organization $ORG_URL_VS --detect false" "$SIM/az.log"
  [ "$1" = completed ] || check "$1: is not reported merged" bash -c "! printf '%s' \"\$1\" | grep -q 'PR merged'" _ "$OUT"
}
state active '.' 'run passed: PR open'
state abandoned '.status = "abandoned"' 'run passed: PR closed'
state "completed without a completion commit" '.status = "completed"' 'run passed: PR state unknown (unreadable)'
state "completed as another repository's" '.status = "completed" | .lastMergeCommit = {commitId: "7777777777777777777777777777777777777777"} | .repository.name = "other"' 'run passed: PR state unknown (unreadable)'
state completed '.status = "completed" | .lastMergeCommit = {commitId: "7777777777777777777777777777777777777777"}' 'run passed: PR merged'
finish
