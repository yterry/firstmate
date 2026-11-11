#!/usr/bin/env bash
# Scenario 2: what arming a watch accepts and refuses.
. "$(dirname "$0")/lab-lib.sh"
new_lab s2-arming
meta_has_pr() { grep -q '^pr=' "$HOME_DIR/state/$1.meta"; }
armed() { [ -e "$HOME_DIR/state/$1.check.sh" ]; }

say "A. A draft pull request is refused by name; nothing is recorded or armed; it arms once published"
add_task draft1
worker_commit draft1 a.txt a "draft work"; worker_push draft1
worker_open_pr draft1 --draft true
DRAFT_URL=$PR_URL DRAFT_ID=$PR_ID
run_check draft-direct draft1 "$DRAFT_URL"
check "arming a draft exits non-zero" test "$CHECK_RC" -ne 0
check "the refusal names the draft state" grep -q 'is a draft pull request; a draft cannot be merged' "$LAB/draft-direct.err"
check "no pr= was recorded for the draft" bash -c "! grep -q '^pr=' '$HOME_DIR/state/draft1.meta'"
check "no poll was armed for the draft" test ! -e "$HOME_DIR/state/draft1.check.sh"
worker_report_done draft1 "$DRAFT_URL"
printf '$ fm-pr-check.sh scan   (first sweep)\n'; SCAN1=$(fm fm-pr-check.sh scan 2>&1); printf '%s\n' "$SCAN1"
check "the scan reports the refusal once, naming the task, the URL, and the reason" bash -c \
  "printf '%s' \"\$1\" | grep -qF 'draft1 reported $DRAFT_URL in a done line, but it was not recorded: $DRAFT_URL is a draft pull request'" _ "$SCAN1"
printf '$ fm-pr-check.sh scan   (second sweep, still a draft)\n'; SCAN2=$(fm fm-pr-check.sh scan 2>&1); printf '%s\n[%s bytes]\n' "$SCAN2" "${#SCAN2}"
check "a later sweep stays silent while it is still a draft" test -z "$SCAN2"
printf '$ az repos pr update --id %s --organization %s --draft false   (the worker publishes it)\n' "$DRAFT_ID" "$ORG_URL_VS"
AZ_SIM_WORKER=1 PATH="$FAKEBIN:$PATH" az repos pr update --id "$DRAFT_ID" --organization "$ORG_URL_VS" --draft false | jq -c '{pullRequestId,isDraft}'
printf '$ fm-pr-check.sh scan   (third sweep, now ready)\n'; SCAN3=$(fm fm-pr-check.sh scan 2>&1); printf '%s\n[%s bytes]\n' "$SCAN3" "${#SCAN3}"
check "the published pull request is recorded without help" grep -qxF "pr=$DRAFT_URL" "$HOME_DIR/state/draft1.meta"
check "its poll is armed" armed draft1

say "B. Both Azure DevOps Services URL forms arm, with and without DefaultCollection"
n=0
for form in "https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME" \
            "https://$ORG.visualstudio.com/$PROJECT_ENC/_git/$REPO_NAME" \
            "https://$ORG.visualstudio.com/DefaultCollection/$PROJECT_ENC/_git/$REPO_NAME" \
            "https://dev.azure.com/$ORG/lab%20project/_git/LAB-REPO"; do
  n=$((n + 1)); id="form$n"
  add_task "$id"; worker_commit "$id" "f$n.txt" x "work $n"; worker_push "$id"; worker_open_pr "$id"
  url="$form/pullrequest/$PR_ID"
  : > "$SIM/az.log"
  run_check "form$n" "$id" "$url"
  check "form $n arms: $url" test "$CHECK_RC" -eq 0
  check "form $n records exactly the URL as written" grep -qxF "pr=$url" "$HOME_DIR/state/$id.meta"
  case "$form" in
    https://dev.azure.com/*) want="--organization https://dev.azure.com/$ORG --detect false" ;;
    *) want="--organization https://$ORG.visualstudio.com --detect false" ;;
  esac
  check "form $n reads through its own organization URL only" grep -qF -- "repos pr show --id $PR_ID $want" "$SIM/az.log"
  run_poll "$id"
  check "form $n: the armed poll is silent while active" test -z "$POLL_OUT"
done
check "every task's armed poll is the same bytes as bin/fm-pr-poll.sh" bash -c \
  "n=0; for d in '$HOME_DIR'/state/*.pr-poll; do cmp -s \"\${d%.pr-poll}.check.sh\" '$BIN/fm-pr-poll.sh' || exit 1; n=\$((n+1)); done; [ \$n -eq 5 ]"

say "C. A URL whose id reads back as another repository's or project's pull request is refused"
add_task other1; worker_commit other1 o.txt o "other work"; worker_push other1; worker_open_pr other1
for bad in "https://dev.azure.com/$ORG/$PROJECT_ENC/_git/some-other-repo/pullrequest/$PR_ID" \
           "https://dev.azure.com/$ORG/Another%20Project/_git/$REPO_NAME/pullrequest/$PR_ID"; do
  run_check other other1 "$bad"
  check "refused: $bad" test "$CHECK_RC" -ne 0
  check "the refusal says it reads back as another repository's" grep -q "Azure DevOps reads pull request $PR_ID back as another repository's" "$LAB/other.err"
  check "nothing was recorded" bash -c "! grep -q '^pr=' '$HOME_DIR/state/other1.meta'"
  check "nothing was armed" test ! -e "$HOME_DIR/state/other1.check.sh"
done

say "D. Missing tooling refuses before anything is recorded"
touch "$SIM/hooks/no-extension"
run_check noext other1 "$PR_URL"
check "no azure-devops extension refuses" test "$CHECK_RC" -ne 0
check "the refusal names the extension" grep -q 'requires the az azure-devops extension' "$LAB/noext.err"
rm -f "$SIM/hooks/no-extension"
mv "$FAKEBIN/az" "$FAKEBIN/az.hidden"
run_check noaz other1 "$PR_URL"
check "no az on PATH refuses" test "$CHECK_RC" -ne 0
check "the refusal names az and jq" grep -q 'requires az and jq on PATH' "$LAB/noaz.err"
mv "$FAKEBIN/az.hidden" "$FAKEBIN/az"
check "still nothing recorded or armed" bash -c "! grep -q '^pr=' '$HOME_DIR/state/other1.meta' && [ ! -e '$HOME_DIR/state/other1.check.sh' ]"

say "E. Malformed or look-alike URLs are refused as invalid before any forge read"
: > "$SIM/az.log"
while IFS= read -r bad; do
  [ -n "$bad" ] || continue
  rc=0; err=$(fm fm-pr-check.sh other1 "$bad" 2>&1 >/dev/null) || rc=$?
  printf '%-112s -> exit %s: %s\n' "$bad" "$rc" "$err"
  check "invalid: $bad" test "$rc" -eq 2
done <<URLS
http://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequests/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/0
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/2147483648
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID/
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID?_a=files
https://dev.azure.com/$ORG/DefaultCollection/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME%2F..%2Fother/pullrequest/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/%2E%2E/pullrequest/$PR_ID
https://dev.azure.com/$ORG/Lab%20project%2f/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com/$ORG/Lab Project/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/_git/lab%2Drepo/pullrequest/$PR_ID
https://dev.azure.com/-$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com/$ORG/$PROJECT_ENC/$REPO_NAME/pullrequest/$PR_ID
https://$ORG.visualstudio.com/OtherCollection/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://FM-LAB-ORG.visualstudio.com/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://$ORG.visualstudio.com.evil.example/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://dev.azure.com.evil.example/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
https://user@dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME/pullrequest/$PR_ID
URLS
check "no malformed URL reached az" test ! -s "$SIM/az.log"
check "no malformed URL was recorded" bash -c "! grep -q '^pr=' '$HOME_DIR/state/other1.meta'"
finish
