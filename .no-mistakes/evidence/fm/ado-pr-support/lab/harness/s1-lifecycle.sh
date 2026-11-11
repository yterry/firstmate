#!/usr/bin/env bash
# Scenario 1: one Azure DevOps pull request through the whole lifecycle.
. "$(dirname "$0")/lab-lib.sh"
new_lab s1-lifecycle
ID=ado-life

say "1. Intake: the clone's origin proposes the forge, and the registry binding is read"
show git -C "$PROJ" config --get remote.origin.url
show fm fm-forge-detect.sh "$PROJ"
show sed -n 3p "$HOME_DIR/data/projects.md"
show fm fm-project-mode.sh --forge "$REPO_NAME"
check "forge-detect proposes azure-devops from the origin host" \
  bash -c "PATH='$FAKEBIN:$PATH' '$BIN/fm-forge-detect.sh' '$PROJ' | grep -qx 'forge=azure-devops evidence=origin remote host dev.azure.com is an Azure DevOps Services host'"
check "the registry binding resolves to azure-devops" \
  bash -c "[ \"\$(FM_HOME='$HOME_DIR' '$BIN/fm-project-mode.sh' --forge '$REPO_NAME')\" = azure-devops ]"

say "2. Brief: the ship brief tells the worker to use az repos pr"
show fm fm-brief.sh "$ID" "$REPO_NAME" --mode direct-PR --forge azure-devops
BRIEF="$HOME_DIR/data/$ID/brief.md"
show grep -n -E 'Delivery contract:|az repos pr|repository\.webUrl|Use the Azure CLI' "$BRIEF"
check "brief carries the azure-devops delivery contract" grep -qx 'Delivery contract: mode=direct-PR forge=azure-devops' "$BRIEF"
check "brief names az repos pr create" grep -q 'open a PR with `az repos pr create`' "$BRIEF"
check "brief tells the worker to report repository.webUrl + /pullrequest/<id>" grep -q 'repository.webUrl' "$BRIEF"
check "brief does not tell the worker to use gh-axi for the pull request" bash -c "! grep -q 'open a PR with \`gh-axi\`' '$BRIEF'"

show fm fm-brief.sh "$ID-nm" "$REPO_NAME" --mode no-mistakes --forge azure-devops
show grep -n -E 'Delivery contract:|az repos pr' "$HOME_DIR/data/$ID-nm/brief.md"
check "a no-mistakes brief carries the azure-devops delivery contract" grep -qx 'Delivery contract: mode=no-mistakes forge=azure-devops' "$HOME_DIR/data/$ID-nm/brief.md"
check "a no-mistakes brief has the worker read the pull request back with az repos pr" grep -q 'az repos pr show' "$HOME_DIR/data/$ID-nm/brief.md"
printf '$ fm-brief.sh %s %s --mode local-only --forge azure-devops\n' "$ID-local" "$REPO_NAME"
LOCAL_RC=0; fm fm-brief.sh "$ID-local" "$REPO_NAME" --mode local-only --forge azure-devops > "$LAB/brief-local.out" 2>&1 || LOCAL_RC=$?
cat "$LAB/brief-local.out"; printf '[exit %s]\n' "$LOCAL_RC"
check "a local-only brief refuses the azure-devops forge" test "$LOCAL_RC" -ne 0

say "3. Worker: commits, pushes, opens the pull request the way the brief says, reports done"
add_task "$ID"
worker_commit "$ID" feature.txt hello "add feature"
worker_commit "$ID" shared.txt "$(printf '%s\n' base feature-edit)" "edit shared from feature"
worker_push "$ID"
worker_open_pr "$ID"
HEAD1=$(git -C "$WT" rev-parse HEAD)
green_policies "$PR_ID" "$HEAD1"
printf 'pull request %s opened: %s\n' "$PR_ID" "$PR_URL"
worker_az repos pr show --id "$PR_ID" --organization "$ORG_URL_VS" --query isDraft
worker_report_done "$ID" "$PR_URL"
show cat "$HOME_DIR/state/$ID.status"

say "4. Firstmate recognizes the reported link (the watcher's scan) and arms the watch"
show fm fm-pr-check.sh scan
show grep -n '^pr' "$HOME_DIR/state/$ID.meta"
show cat "$HOME_DIR/state/$ID.pr-poll"
check "scan recorded the reported URL as pr=" grep -qxF "pr=$PR_URL" "$HOME_DIR/state/$ID.meta"
check "no pr_head is recorded for Azure DevOps" bash -c "! grep -q '^pr_head=' '$HOME_DIR/state/$ID.meta'"
check "the poll is armed" test -f "$HOME_DIR/state/$ID.check.sh"
check "the armed poll is byte-identical to bin/fm-pr-poll.sh" cmp -s "$HOME_DIR/state/$ID.check.sh" "$BIN/fm-pr-poll.sh"
check "the sidecar records the azure-devops identity" bash -c "[ \"\$(sed -n 1p '$HOME_DIR/state/$ID.pr-poll')\" = azure-devops ]"

say "5. Watch: silent while the pull request is active"
printf '$ bash state/%s.check.sh\n' "$ID"; OUT=$(poll "$ID"); printf '%s\n[exit %s, %s bytes of output]\n' "$OUT" "$?" "${#OUT}"
check "active pull request prints nothing" test -z "$OUT"

say "6. Review: the local branch is diffed under the PR-head-unavailable warning"
printf '$ fm-review-diff.sh %s --stat\n' "$ID"
fm fm-review-diff.sh "$ID" --stat > "$LAB/review.out" 2> "$LAB/review.err"; printf '[exit %s]\n' "$?"
sed 's/^/stdout: /' "$LAB/review.out"; sed 's/^/stderr: /' "$LAB/review.err"
check "review warns the PR head is unavailable" grep -qi 'PR head unavailable' "$LAB/review.err"
check "review shows the worker's files" grep -q 'feature.txt' "$LAB/review.out"
check "review never fetched the merge preview" bash -c "! git -C '$WT' for-each-ref | grep -q 'refs/pull/'"

say "7. Completion: verified live, bound to the head, read back"
MAIN_BEFORE=$(origin_main)
printf '$ fm-pr-merge.sh %s %s -- --squash\n' "$ID" "$PR_URL"
fm fm-pr-merge.sh "$ID" "$PR_URL" -- --squash > "$LAB/merge.out" 2> "$LAB/merge.err"; MERGE_RC=$?
sed 's/^/stdout: /' "$LAB/merge.out"; sed 's/^/stderr: /' "$LAB/merge.err"; printf '[exit %s]\n' "$MERGE_RC"
show cat "$SIM/patch.log"
check "merge exits 0" test "$MERGE_RC" -eq 0
check "merge reports the verified head" grep -qF "every branch policy passing at head $HEAD1" "$LAB/merge.err"
check "merge confirms the landing by read-back" grep -qxF "verified: $PR_URL is completed from head $HEAD1" "$LAB/merge.out"
check "exactly one completion request was sent" bash -c "[ \"\$(wc -l < '$SIM/patch.log' | tr -d ' ')\" = 1 ]"
check "the completion names the verified head, squash, no bypass, no branch deletion" bash -c \
  "[ \"\$(jq -cS . '$SIM/last-patch-body.json')\" = '{\"completionOptions\":{\"bypassPolicy\":false,\"deleteSourceBranch\":false,\"mergeStrategy\":\"squash\"},\"lastMergeSourceCommit\":{\"commitId\":\"$HEAD1\"},\"status\":\"completed\"}' ]"
check "the completion went to the repository-scoped route of the URL's host" grep -qF "PATCH $ORG_URL_VS/$PROJECT_ID/_apis/git/repositories/$REPO_ID/pullrequests/$PR_ID?api-version=7.1 " "$SIM/patch.log"
check "az repos pr update was never used to complete" bash -c "! grep -q '^repos pr update' '$SIM/az.log'"
check "the target branch moved on the Azure DevOps repository" bash -c "[ '$(origin_main)' != '$MAIN_BEFORE' ]"
check "the squash commit is one commit on top of the old target" bash -c "[ \"\$(git -C '$ORIGIN' rev-parse refs/heads/main^)\" = '$MAIN_BEFORE' ]"
show git -C "$ORIGIN" log --oneline -3 refs/heads/main
show sed -n 1,8p "$HOME_DIR/state/$ID.merge-authority"

say "8. Watch: the same armed poll now reports the merge"
printf '$ bash state/%s.check.sh\n' "$ID"; OUT=$(poll "$ID"); printf '%s\n[exit %s]\n' "$OUT" "$?"
check "completed pull request prints merged" test "$OUT" = merged

say "9. Cleanup: the source branch is deleted on the forge and main moves on, so only the completed record can prove the work landed"
g -C "$ORIGIN" update-ref -d "refs/heads/fm/$ID"
git clone -q "$ORIGIN" "$LAB/_later"
printf '%s\n' base feature-edit-reworded > "$LAB/_later/shared.txt"
g -C "$LAB/_later" commit -q -am "main rewords shared after the squash"
g -C "$LAB/_later" push -q origin main
rm -rf "$LAB/_later"
show git -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname:short)'
# Fleet sync prunes the deleted branch's remote-tracking ref from the clone.
show git -C "$PROJ" fetch -q --prune origin
show git -C "$PROJ" for-each-ref --format='%(refname) %(objectname:short)' refs/remotes
: > "$SIM/az.log"
printf '$ fm-teardown.sh %s\n' "$ID"
fm fm-teardown.sh "$ID" > "$LAB/teardown.out" 2> "$LAB/teardown.err"; TD_RC=$?
sed 's/^/stdout: /' "$LAB/teardown.out"; sed 's/^/stderr: /' "$LAB/teardown.err"; printf '[exit %s]\n' "$TD_RC"
show cat "$SIM/az.log"
check "teardown exits 0" test "$TD_RC" -eq 0
check "teardown read the pull request through az" grep -qF "repos pr show --id $PR_ID --organization $ORG_URL_VS --detect false" "$SIM/az.log"
check "the task record is removed" test ! -e "$HOME_DIR/state/$ID.meta"
backlog_show "$ID"
check "the backlog item is done" bash -c "PATH='$FAKEBIN:$PATH' tasks-axi show '$ID' --file '$HOME_DIR/data/backlog.md' | grep -q 'state: done'"
check "the backlog item records the pull request URL as a note" bash -c \
  "PATH='$FAKEBIN:$PATH' tasks-axi show '$ID' --file '$HOME_DIR/data/backlog.md' --full | grep -qF 'Azure DevOps pull request $PR_URL'"

say "Other tools reached during the run (inert stubs)"
show cat "$LAB/stub.log"
finish
