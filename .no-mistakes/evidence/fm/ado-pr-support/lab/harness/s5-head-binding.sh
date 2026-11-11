#!/usr/bin/env bash
# Scenario 5: a completion lands only the head that was verified, and only a
# read-back counts as landed.
. "$(dirname "$0")/lab-lib.sh"
new_lab s5-head-binding
push_extra() {  # <id> <n>: the worker pushes one more commit to the source branch
  worker_commit "$1" "late-$2.txt" late "late commit $2 pushed after review"
  worker_push "$1"
}

say "A. A push lands between verification and the completion request"
open_ready_pr race1; A_ID=$PR_ID A_URL=$PR_URL A_HEAD=$HEAD1
run_check arm-a race1 "$A_URL"
MAIN0=$(origin_main)
cat > "$SIM/hooks/before-patch" <<HOOK
#!/usr/bin/env bash
# The worker's late push, landing after firstmate verified $A_HEAD.
cd '$LAB/wt-race1' && printf 'late\n' > late-race.txt && git add late-race.txt \
  && git -c user.name='Lab Worker' -c user.email=worker@example.invalid commit -q -m 'late commit pushed during the merge' \
  && git push -q origin fm/race1
HOOK
chmod +x "$SIM/hooks/before-patch"
run_merge race race1 "$A_URL" -- --squash
A_TIP=$(git -C "$ORIGIN" rev-parse refs/heads/fm/race1)
printf 'source branch tip on the forge is now %s (verified head was %s)\n' "$A_TIP" "$A_HEAD"
show cat "$SIM/patch.log"
check "race: the late push really landed on the source branch" test "$A_TIP" != "$A_HEAD"
check "race: fm-pr-merge exits non-zero" test "$MERGE_RC" -ne 0
check "race: Azure DevOps' TF401192 refusal is shown" grep -q 'TF401192: The source branch has been modified since the last merge attempt' "$LAB/race.err"
check "race: the failure says nothing read back as completed from the verified head" grep -qF "has not read back as completed from head $A_HEAD" "$LAB/race.err"
check "race: exactly one completion request, naming the verified head, never the new tip" bash -c \
  "[ \"\$(wc -l < '$SIM/patch.log' | tr -d ' ')\" = 1 ] && grep -qF '\"commitId\":\"$A_HEAD\"' '$SIM/patch.log' && ! grep -qF '$A_TIP' '$SIM/patch.log'"
check "race: the target branch did not move" test "$(origin_main)" = "$MAIN0"
check "race: the pull request is still active" test "$(pr_field "$A_ID" .status)" = active
check "race: no landed-merge authority was persisted" test ! -e "$HOME_DIR/state/race1.merge-authority"
run_poll race1
check "race: the poll stays armed and silent" bash -c "[ -f '$HOME_DIR/state/race1.check.sh' ] && [ -z \"\$1\" ]" _ "$POLL_OUT"

say "B. Azure DevOps has not recomputed the merge after a push (its reported source commit lags the branch)"
: > "$SIM/patch.log"
run_merge lag race1 "$A_URL" -- --squash
check "lag: refused by Azure DevOps with TF401192, not landed" bash -c "[ $MERGE_RC -ne 0 ] && grep -q TF401192 '$LAB/lag.err'"
check "lag: the target branch did not move" test "$(origin_main)" = "$MAIN0"

say "C. The head moves while the branch policies are being read"
open_ready_pr move1; C_ID=$PR_ID C_URL=$PR_URL C_HEAD=$HEAD1
: > "$SIM/patch.log"
cat > "$SIM/hooks/after-policy-list" <<HOOK
#!/usr/bin/env bash
cd '$LAB/wt-move1' && printf 'late\n' > late-move.txt && git add late-move.txt \
  && git -c user.name='Lab Worker' -c user.email=worker@example.invalid commit -q -m 'late commit pushed during the policy read' \
  && git push -q origin fm/move1
# Azure DevOps recomputes the merge at once this time.
tip=\$(git -C '$ORIGIN' rev-parse refs/heads/fm/move1)
jq --arg tip "\$tip" '.lastMergeSourceCommit = {commitId: \$tip}' '$SIM/prs/$C_ID.json' > '$SIM/prs/$C_ID.json.tmp' && mv '$SIM/prs/$C_ID.json.tmp' '$SIM/prs/$C_ID.json'
HOOK
chmod +x "$SIM/hooks/after-policy-list"
run_merge moved move1 "$C_URL" -- --squash
check "moved: refused" test "$MERGE_RC" -eq 1
check "moved: names the head that moved" grep -qF "the pull request changed while its policies were read (head $C_HEAD became" "$LAB/moved.err"
check "moved: no completion request was sent" test "$(patch_count)" = 0
check "moved: the target branch did not move" test "$(origin_main)" = "$MAIN0"

say "D. --expected-head pins the commit that was reviewed"
open_ready_pr pin1; D_ID=$PR_ID D_URL=$PR_URL D_REVIEWED=$HEAD1
push_extra pin1 1; service_recompute "$D_ID"
D_LIVE=$(git -C "$ORIGIN" rev-parse refs/heads/fm/pin1)
green_policies "$D_ID" "$D_LIVE"
: > "$SIM/patch.log"
printf 'reviewed head %s, live head after a later push %s; every policy is green at the live head\n' "$D_REVIEWED" "$D_LIVE"
run_merge pin-stale pin1 "$D_URL" --expected-head "$D_REVIEWED" -- --squash
check "expected-head mismatch: refused" test "$MERGE_RC" -ne 0
check "expected-head mismatch: names both heads" bash -c "grep -qF '$D_REVIEWED' '$LAB/pin-stale.err' && grep -qF '$D_LIVE' '$LAB/pin-stale.err'"
check "expected-head mismatch: no completion request was sent" test "$(patch_count)" = 0
check "expected-head mismatch: the pull request is still active" test "$(pr_field "$D_ID" .status)" = active
check "expected-head mismatch: the target branch did not move" test "$(origin_main)" = "$MAIN0"
for bad in abc123 "${D_LIVE:0:39}" "$(printf '%s' "$D_LIVE" | tr 'a-f' 'A-F')"; do
  run_merge pin-bad pin1 "$D_URL" --expected-head "$bad" -- --squash
  check "expected-head '$bad' is rejected as malformed (exit 2), nothing sent" bash -c "[ $MERGE_RC -eq 2 ] && [ \"\$(wc -l < '$SIM/patch.log' | tr -d ' ')\" = 0 ]"
done
run_merge pin-ok pin1 "$D_URL" --expected-head "$D_LIVE" -- --squash
check "expected-head match: completes" test "$MERGE_RC" -eq 0
check "expected-head match: the completion names exactly that head" test "$(jq -r .lastMergeSourceCommit.commitId "$SIM/last-patch-body.json")" = "$D_LIVE"
check "expected-head match: landing confirmed from that head" grep -qxF "verified: $D_URL is completed from head $D_LIVE" "$LAB/pin-ok.out"
check "expected-head match: the forge record completed from that head" test "$(pr_field "$D_ID" .lastMergeSourceCommit.commitId)" = "$D_LIVE"
MAIN1=$(origin_main)

say "E. The response is lost after Azure DevOps applied the completion"
open_ready_pr lost1; E_ID=$PR_ID E_URL=$PR_URL E_HEAD=$HEAD1
: > "$SIM/patch.log"; touch "$SIM/hooks/lose-patch-response"
run_merge lost lost1 "$E_URL" -- --squash
check "lost response: one request, and the read-back shows it landed, so the run succeeds" bash -c "[ $MERGE_RC -eq 0 ] && [ \"\$(wc -l < '$SIM/patch.log' | tr -d ' ')\" = 1 ]"
check "lost response: landing confirmed from the verified head" grep -qxF "verified: $E_URL is completed from head $E_HEAD" "$LAB/lost.out"
check "lost response: the merge authority is persisted" test -f "$HOME_DIR/state/lost1.merge-authority"

say "F. Azure DevOps accepts the completion and finishes it a few reads later"
open_ready_pr async1; F_ID=$PR_ID F_URL=$PR_URL F_HEAD=$HEAD1
printf '3\n' > "$SIM/hooks/async-reads"
run_merge async async1 "$F_URL" -- --squash
check "async: confirmed after re-reading" bash -c "[ $MERGE_RC -eq 0 ] && grep -qxF 'verified: $F_URL is completed from head $F_HEAD' '$LAB/async.out'"

say "G. Azure DevOps accepts the completion but has not finished within the bounded wait"
open_ready_pr slow1; G_ID=$PR_ID G_URL=$PR_URL G_HEAD=$HEAD1
printf '40\n' > "$SIM/hooks/async-reads"
FM_PR_AZURE_DEVOPS_CONFIRM_DELAY=0 run_merge slow slow1 "$G_URL" -- --squash
check "slow: exits 0 without claiming it landed" bash -c "[ $MERGE_RC -eq 0 ] && ! grep -q 'is completed from head' '$LAB/slow.out'"
check "slow: says the completion is accepted but unconfirmed, and the poll remains armed" grep -qF "has not confirmed it landed yet; the merge poll remains armed and reports the merge" "$LAB/slow.err"
run_poll slow1
check "slow: the poll is silent while Azure DevOps is still completing" test -z "$POLL_OUT"
printf '0\n' > "$SIM/prs/$G_ID.pending-reads"
run_poll slow1
check "slow: the poll reports merged once Azure DevOps finishes" test "$POLL_OUT" = merged

say "H. The pull request is abandoned by someone else right after the request fails"
open_ready_pr gone1; H_ID=$PR_ID H_URL=$PR_URL H_HEAD=$HEAD1
: > "$SIM/patch.log"
cat > "$SIM/hooks/before-patch" <<HOOK
#!/usr/bin/env bash
jq '.status = "abandoned"' '$SIM/prs/$H_ID.json' > '$SIM/prs/$H_ID.json.tmp' && mv '$SIM/prs/$H_ID.json.tmp' '$SIM/prs/$H_ID.json'
HOOK
chmod +x "$SIM/hooks/before-patch"
MAIN2=$(origin_main)
run_merge gone gone1 "$H_URL" -- --squash
check "abandoned: fails and names the read-back" bash -c "[ $MERGE_RC -ne 0 ] && grep -q 'it reads back abandoned' '$LAB/gone.err'"
check "abandoned: the target branch did not move" test "$(origin_main)" = "$MAIN2"
finish
