#!/usr/bin/env bash
# Scenario 4: completion is refused unless every live condition holds, and no
# refusal ever sends a completion request.
. "$(dirname "$0")/lab-lib.sh"
new_lab s4-merge-guards
open_ready_pr guard1
F="$SIM/prs/$PR_ID.json"; cp "$F" "$LAB/pr.good.json"
MAIN0=$(origin_main)
# Assigned first: bash 3.2 brace-expands a quoted {a,b} inside "$(...)" arguments.
CTX_HEAD=$(jq -nc --arg h "$HEAD1" '{lastMergeSourceCommitId: $h}')
CTX_EXPIRED=$(jq -nc --arg h "$HEAD1" '{lastMergeSourceCommitId: $h, isExpired: true}')
refused() {  # <label> <expected message> [expected rc]
  local label=$1 msg=$2 want=${3:-1}
  check "$label: exit $want" test "$MERGE_RC" -eq "$want"
  check "$label: names the reason ($msg)" grep -qF -- "$msg" "$LAB/$label.err"
  check "$label: no completion request was sent" test "$(patch_count)" = 0
  check "$label: the target branch did not move" test "$(origin_main)" = "$MAIN0"
  check "$label: the pull request is still active" test "$(pr_field "$PR_ID" .status)" = active
}
reset() { cp "$LAB/pr.good.json" "$F"; green_policies "$PR_ID" "$HEAD1"; }

say "required build is red"
write_policies "$PR_ID" "$(policy build rejected true 'CI build')" "$(policy reviewers approved true 'Minimum number of reviewers')"
run_merge red guard1 "$PR_URL" -- --squash
refused red 'required check "CI build" is rejected, not approved'
check "red: the refusal still records pr= and leaves the poll armed" bash -c "grep -qxF 'pr=$PR_URL' '$HOME_DIR/state/guard1.meta' && [ -f '$HOME_DIR/state/guard1.check.sh' ]"

say "required build still running, and reviewers not yet approved (both reported)"
write_policies "$PR_ID" "$(policy build running true 'CI build')" "$(policy reviewers running true 'Minimum number of reviewers')"
run_merge pending guard1 "$PR_URL" -- --squash
refused pending 'required check "CI build" is running, not approved'
check "pending: the unapproved reviewer policy is reported too" grep -qF 'required policy "Minimum number of reviewers" is running, not approved' "$LAB/pending.err"

say "build approved, but for an older source commit"
write_policies "$PR_ID" "$(policy build approved true 'CI build' '{"lastMergeSourceCommitId":"3434343434343434343434343434343434343434"}')"
run_merge stalebuild guard1 "$PR_URL" -- --squash
refused stalebuild 'passed at 3434343434343434343434343434343434343434, not at the current head'

say "build approved at the head, but expired"
write_policies "$PR_ID" "$(policy build approved true 'CI build' "$CTX_EXPIRED")"
run_merge expired guard1 "$PR_URL" -- --squash
refused expired 'its result has expired or is not current'

say "required external status check pending"
write_policies "$PR_ID" "$(policy build approved true 'CI build' "$CTX_HEAD")" "$(policy status queued true 'security/scan')"
run_merge status guard1 "$PR_URL" -- --squash
refused status 'required check "security/scan" is queued, not approved'

say "optional check red: refused, a waiver naming another check does not help, and --allow-red on a required check is refused"
write_policies "$PR_ID" "$(policy build approved true 'CI build' "$CTX_HEAD")" "$(policy build rejected false lint)"
run_merge optred guard1 "$PR_URL" -- --squash
refused optred 'optional check "lint" is rejected, not approved'
run_merge optother guard1 "$PR_URL" --allow-red typo -- --squash
refused optother 'optional check "lint" is rejected, not approved'
write_policies "$PR_ID" "$(policy build rejected true 'CI build')"
run_merge reqwaive guard1 "$PR_URL" --allow-red 'CI build' -- --squash
refused reqwaive '--allow-red cannot waive it because Azure DevOps enforces a required policy at completion'

say "--allow-missing does not apply and makes no forge call"
reset; : > "$SIM/az.log"
run_merge missing guard1 "$PR_URL" --allow-missing 'CI build' -- --squash
refused missing '--allow-missing does not apply to Azure DevOps' 2
check "missing: az was never called" test ! -s "$SIM/az.log"

say "the pull request turned into a draft"
reset; jq '.isDraft = true' "$LAB/pr.good.json" > "$F"
run_merge draft guard1 "$PR_URL" -- --squash
refused draft 'the pull request is a draft'

say "the merge has conflicts"
reset; jq '.mergeStatus = "conflicts"' "$LAB/pr.good.json" > "$F"
run_merge conflicts guard1 "$PR_URL" -- --squash
refused conflicts 'mergeStatus is "conflicts", not succeeded'

say "Azure DevOps has not computed a source commit yet"
reset; jq '.lastMergeSourceCommit = null | .mergeStatus = "queued"' "$LAB/pr.good.json" > "$F"
run_merge nosource guard1 "$PR_URL" -- --squash
refused nosource 'could not read the Azure DevOps pull request source commit before merging'

say "the branch policies cannot be read"
reset; touch "$SIM/hooks/policies-fail"
run_merge nopolicies guard1 "$PR_URL" -- --squash
refused nopolicies 'could not read the Azure DevOps branch policies before merging'
rm -f "$SIM/hooks/policies-fail"

say "merge strategy policy"
reset
write_policies "$PR_ID" "$(policy build approved true 'CI build' "$CTX_HEAD")" \
  "$(policy strategy rejected true 'Require a merge strategy' null '{"allowSquash":true,"allowRebase":true}')"
run_merge several guard1 "$PR_URL"
refused several 'the repository allows several merge strategies (squash, rebase) and neither the caller nor the pull request names one'
run_merge notallowed guard1 "$PR_URL" -- --merge
refused notallowed "merge strategy noFastForward is not one the repository's merge strategy policy allows (squash, rebase)"
run_merge unknown guard1 "$PR_URL" -- --method fancy
refused unknown "unknown Azure DevOps merge strategy 'fancy'"

say "forge flags that would bypass policy, auto-complete, or delete the branch"
reset
for flag in --admin --auto --delete-branch -d; do
  label="flag$(printf '%s' "$flag" | tr -d -)"
  run_merge "$label" guard1 "$PR_URL" -- --squash "$flag"
  refused "$label" 'must not request auto-merge, a protection bypass, or branch deletion'
done
run_merge flagoverride guard1 "$PR_URL" --attended-override -- --squash --admin
refused flagoverride 'extra merge arguments are not yet supported for Azure DevOps merges'

say "a URL in the same organization whose id belongs to another repository"
OTHER="https://dev.azure.com/$ORG/$PROJECT_ENC/_git/some-other-repo/pullrequest/$PR_ID"
add_task guard2
run_merge otherrepo guard2 "$OTHER" -- --squash
check "otherrepo: refused" test "$MERGE_RC" -ne 0
check "otherrepo: names the mismatch" grep -q "back as another repository's" "$LAB/otherrepo.err"
check "otherrepo: nothing recorded or armed" bash -c "! grep -q '^pr=' '$HOME_DIR/state/guard2.meta' && [ ! -e '$HOME_DIR/state/guard2.check.sh' ]"
check "otherrepo: no completion request was sent" test "$(patch_count)" = 0

say "a Gerrit-style or unknown URL for the same task is not silently treated as Azure DevOps"
run_merge badurl guard2 "https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequests/$PR_ID"
check "badurl: exit 2" test "$MERGE_RC" -eq 2

say "after every refusal, the same pull request still completes once it is green"
reset
write_policies "$PR_ID" "$(policy build approved true 'CI build' "$CTX_HEAD")" \
  "$(policy build rejected false lint)" \
  "$(policy build notApplicable true 'path-filtered build')" \
  "$(policy reviewers rejected false 'Comment requirements')" \
  "$(policy strategy rejected true 'Require a merge strategy' null '{"allowSquash":true}')"
run_merge waived guard1 "$PR_URL" --allow-red lint
check "waived: exit 0" test "$MERGE_RC" -eq 0
check "waived: the waiver is reported" grep -qF 'except optional check lint, waived by --allow-red' "$LAB/waived.err"
check "waived: the only allowed strategy (squash) was named without the caller choosing" test "$(jq -r .completionOptions.mergeStrategy "$SIM/last-patch-body.json")" = squash
check "waived: exactly one completion request in the whole scenario" test "$(patch_count)" = 1
check "waived: landing confirmed" grep -qxF "verified: $PR_URL is completed from head $HEAD1" "$LAB/waived.out"
check "waived: the target branch moved" test "$(origin_main)" != "$MAIN0"
finish
