#!/usr/bin/env bash
# Disposable Azure DevOps Services simulator standing in for the `az` CLI.
#
# It is NOT the real Azure CLI and reaches no network. It keeps one
# organization with one project and repository on disk, backed by a real bare
# git repository, and answers the az commands firstmate and a worker use in the
# shapes docs/azure-devops-integration.md records from a real organization:
#   az extension show --name azure-devops
#   az repos pr create | show | update | policy list
#   az rest --method patch  (the repository-scoped pull request route)
# A completion PATCH is refused with TF401192 when the named
# lastMergeSourceCommit is not the source branch tip, and an accepted one makes
# a real commit on the target branch of the bare repository.
# Every invocation is appended to $SIM/az.log. A request this simulator treats
# as a safety violation (policy bypass, source-branch deletion, completing past
# an unmet blocking policy) is appended to $SIM/violations.
set -u
SIM=$(cd "$(dirname "$0")/../sim" && pwd)
JQ=/usr/bin/jq
GIT=/usr/bin/git
printf '%s\n' "$*" >> "$SIM/az.log"

ORG=$(cat "$SIM/org")
PROJECT_NAME=$(cat "$SIM/project.name")
PROJECT_ID=$(cat "$SIM/project.id")
REPO_NAME=$(cat "$SIM/repo.name")
REPO_ID=$(cat "$SIM/repo.id")
ORIGIN=$(cat "$SIM/origin")
RESOURCE_ID=499b84ac-1321-427f-aa17-267ca6975798

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
unsupported() { printf 'UNSUPPORTED %s\n' "$*" >> "$SIM/violations"; printf 'ERROR: az simulator: unsupported invocation: %s\n' "$*" >&2; exit 2; }

org_url_known() {
  case "$1" in
    "https://dev.azure.com/$ORG"|"https://$ORG.visualstudio.com") return 0 ;;
  esac
  return 1
}

# Parse the --flag value pairs every az command here takes.
opt() {  # <flag> ; prints its value from ARGS, or fails
  local flag=$1 i
  for ((i = 0; i < ${#ARGS[@]}; i++)); do
    if [ "${ARGS[$i]}" = "$flag" ]; then
      printf '%s' "${ARGS[$((i + 1))]:-}"
      return 0
    fi
  done
  return 1
}

branch_tip() { "$GIT" -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null; }

pr_file() { printf '%s/prs/%s.json' "$SIM" "$1"; }

# An accepted completion that Azure DevOps has not finished yet stays active
# for a number of reads; each read counts one down, and the last one applies it.
settle_pending() {  # <id>
  local id=$1 left
  [ -f "$SIM/prs/$id.pending" ] || return 0
  left=$(cat "$SIM/prs/$id.pending-reads" 2>/dev/null || echo 0)
  if [ "$left" -gt 0 ]; then
    printf '%s\n' "$((left - 1))" > "$SIM/prs/$id.pending-reads"
    return 0
  fi
  mv "$SIM/prs/$id.pending" "$(pr_file "$id")"
  rm -f "$SIM/prs/$id.pending-reads"
}

show_pr() {  # <id> <org-url>
  local id=$1 org_url=$2 file
  org_url_known "$org_url" || die "TF400813: The organization '$org_url' is not reachable from this simulator."
  file=$(pr_file "$id")
  [ -f "$file" ] || die "TF401180: The requested pull request was not found."
  if [ -s "$SIM/hooks/show-failures" ]; then
    local left
    left=$(cat "$SIM/hooks/show-failures")
    if [ "$left" -gt 0 ]; then
      printf '%s\n' "$((left - 1))" > "$SIM/hooks/show-failures"
      die "simulated transient read failure"
    fi
  fi
  settle_pending "$id"
  cat "$file"
}

# Make the commit a completion puts on the target branch, in a scratch clone of
# the bare repository. Prints the new target commit.
complete_in_git() {  # <source-branch> <target-branch> <strategy> <title> <id>
  local source=$1 target=$2 strategy=$3 title=$4 id=$5 scratch commit
  scratch=$(mktemp -d "$SIM/scratch.XXXXXX") || return 1
  "$GIT" clone -q "$ORIGIN" "$scratch/c" >/dev/null 2>&1 || return 1
  (
    cd "$scratch/c" || exit 1
    export GIT_AUTHOR_NAME='Azure DevOps Simulator' GIT_AUTHOR_EMAIL=sim@example.invalid
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    "$GIT" checkout -q "$target" || exit 1
    case "$strategy" in
      squash)
        "$GIT" merge -q --squash "origin/$source" >/dev/null 2>&1 || exit 1
        "$GIT" commit -q -m "Merged PR $id: $title" || exit 1
        ;;
      rebase)
        "$GIT" checkout -q -b sim-rebase "origin/$source" || exit 1
        "$GIT" rebase -q "$target" >/dev/null 2>&1 || exit 1
        "$GIT" checkout -q "$target" && "$GIT" merge -q --ff-only sim-rebase || exit 1
        ;;
      *)
        "$GIT" merge -q --no-ff -m "Merged PR $id: $title" "origin/$source" >/dev/null 2>&1 || exit 1
        ;;
    esac
    "$GIT" push -q origin "$target" >/dev/null 2>&1 || exit 1
    "$GIT" rev-parse HEAD
  ) > "$scratch/out" || { rm -rf "$scratch"; return 1; }
  commit=$(cat "$scratch/out")
  rm -rf "$scratch"
  printf '%s\n' "$commit"
}

ARGS=("$@")
case "${1:-} ${2:-} ${3:-}" in
  "extension show "*)
    [ "$(opt --name)" = azure-devops ] || die "The extension $(opt --name) is not installed."
    [ ! -e "$SIM/hooks/no-extension" ] || die "The extension azure-devops is not installed."
    [ "$(opt --output || true)" = none ] || printf '{"name":"azure-devops","version":"1.0.2"}\n'
    exit 0
    ;;
  "repos pr create")
    org_url=$(opt --organization) || die "--organization is required"
    org_url_known "$org_url" || die "TF400813: The organization '$org_url' is not reachable from this simulator."
    project=$(opt --project) || die "--project is required"
    repo=$(opt --repository) || die "--repository is required"
    source=$(opt --source-branch) || die "--source-branch is required"
    target=$(opt --target-branch) || target=main
    title=$(opt --title) || title="pull request from $source"
    draft=$(opt --draft || echo false)
    [ "$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')" ] \
      || die "TF200016: The following project does not exist: $project."
    [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')" ] \
      || die "TF401019: The Git repository with name or identifier $repo does not exist."
    head=$(branch_tip "$source") || die "TF401398: The pull request cannot be activated because the source branch refs/heads/$source no longer exists."
    branch_tip "$target" >/dev/null || die "TF401398: the target branch refs/heads/$target does not exist."
    id=$(($(cat "$SIM/next-id") + 0))
    printf '%s\n' "$((id + 1))" > "$SIM/next-id"
    case "$draft" in true|True) draft=true ;; *) draft=false ;; esac
    encoded_project=$(printf '%s' "$PROJECT_NAME" | sed 's/ /%20/g')
    "$JQ" -n --argjson id "$id" --argjson draft "$draft" --arg title "$title" \
      --arg source "refs/heads/$source" --arg target "refs/heads/$target" --arg head "$head" \
      --arg repo "$REPO_NAME" --arg repo_id "$REPO_ID" --arg project "$PROJECT_NAME" --arg project_id "$PROJECT_ID" \
      --arg web "https://$ORG.visualstudio.com/DefaultCollection/$encoded_project/_git/$REPO_NAME" \
      --arg api "https://$ORG.visualstudio.com/$PROJECT_ID/_apis/git/repositories/$REPO_ID/pullRequests/$id" '
      {pullRequestId: $id, codeReviewId: $id, status: "active", isDraft: $draft, title: $title,
       sourceRefName: $source, targetRefName: $target, mergeStatus: "succeeded",
       lastMergeSourceCommit: {commitId: $head}, lastMergeCommit: null, completionOptions: null,
       reviewers: [], url: $api,
       repository: {id: $repo_id, name: $repo, webUrl: $web, project: {id: $project_id, name: $project}}}' \
      > "$(pr_file "$id")"
    printf '[]\n' > "$SIM/policies/$id.json"
    cat "$(pr_file "$id")"
    exit 0
    ;;
  "repos pr show")
    id=$(opt --id) || die "--id is required"
    org_url=$(opt --organization) || die "--organization is required"
    [ "$(opt --detect || true)" = false ] || [ "${AZ_SIM_WORKER:-}" = 1 ] || printf 'NO_DETECT_FALSE %s\n' "$*" >> "$SIM/violations"
    out=$(show_pr "$id" "$org_url") || exit 1
    if query=$(opt --query); then
      printf '%s' "$out" | "$JQ" ".$query"
    else
      printf '%s\n' "$out"
    fi
    exit 0
    ;;
  "repos pr update")
    id=$(opt --id) || die "--id is required"
    org_url=$(opt --organization) || die "--organization is required"
    org_url_known "$org_url" || die "TF400813: The organization '$org_url' is not reachable from this simulator."
    file=$(pr_file "$id")
    [ -f "$file" ] || die "TF401180: The requested pull request was not found."
    if draft=$(opt --draft); then
      case "$draft" in true|True) draft=true ;; *) draft=false ;; esac
      "$JQ" --argjson draft "$draft" '.isDraft = $draft' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      cat "$file"
      exit 0
    fi
    # firstmate must never complete through the unbound az repos pr update.
    unsupported "$*"
    ;;
  "repos pr policy")
    [ "${4:-}" = list ] || unsupported "$*"
    id=$(opt --id) || die "--id is required"
    org_url=$(opt --organization) || die "--organization is required"
    org_url_known "$org_url" || die "TF400813: The organization '$org_url' is not reachable from this simulator."
    [ -f "$SIM/policies/$id.json" ] || die "TF401180: The requested pull request was not found."
    [ ! -e "$SIM/hooks/policies-fail" ] || die "simulated policy read failure"
    cat "$SIM/policies/$id.json"
    # A push that lands on the source branch right after the policies are read.
    if [ -x "$SIM/hooks/after-policy-list" ]; then
      hook="$SIM/hooks/after-policy-list"
      mv "$hook" "$hook.ran"
      "$hook.ran" >> "$SIM/hook.log" 2>&1 || true
    fi
    exit 0
    ;;
  "rest --method patch")
    url=$(opt --url) || die "--url is required"
    [ "$(opt --resource || true)" = "$RESOURCE_ID" ] \
      || die "AADSTS500011: The resource principal named $(opt --resource || true) was not found."
    [ "$(opt --headers || true)" = 'Content-Type=application/json' ] || die "Unsupported Media Type"
    body=$(opt --body) || die "--body is required"
    body=${body#@}
    [ -f "$body" ] || die "body file not found"
    cp "$body" "$SIM/last-patch-body.json"
    printf 'PATCH %s %s\n' "$url" "$("$JQ" -c . "$body")" >> "$SIM/patch.log"
    case "$url" in
      "https://dev.azure.com/$ORG/$PROJECT_ID/_apis/git/repositories/$REPO_ID/pullrequests/"*'?api-version=7.1') ;;
      "https://$ORG.visualstudio.com/$PROJECT_ID/_apis/git/repositories/$REPO_ID/pullrequests/"*'?api-version=7.1') ;;
      *) die "Not Found({\"message\":\"The requested resource does not support http method 'PATCH' or was not found: $url\"})" ;;
    esac
    id=${url##*/pullrequests/}
    id=${id%%\?*}
    file=$(pr_file "$id")
    [ -f "$file" ] || die "TF401180: The requested pull request was not found."
    # A push that lands on the source branch between the caller's verification
    # and this request.
    if [ -x "$SIM/hooks/before-patch" ]; then
      hook="$SIM/hooks/before-patch"
      mv "$hook" "$hook.ran"
      "$hook.ran" >> "$SIM/hook.log" 2>&1 || true
    fi
    [ "$("$JQ" -r '.status' "$body")" = completed ] || unsupported "PATCH that is not a completion: $(cat "$body")"
    [ "$("$JQ" -r '.status' "$file")" = active ] \
      || die "Conflict({\"message\":\"TF401181: The pull request cannot be edited due to its state.\"})"
    if [ "$("$JQ" -r '.completionOptions.bypassPolicy // false' "$body")" != false ]; then
      printf 'BYPASS_POLICY_REQUESTED %s\n' "$(cat "$body")" >> "$SIM/violations"
      die "policy bypass requested"
    fi
    if [ "$("$JQ" -r '.completionOptions.deleteSourceBranch // false' "$body")" != false ]; then
      printf 'DELETE_SOURCE_BRANCH_REQUESTED %s\n' "$(cat "$body")" >> "$SIM/violations"
      die "source branch deletion requested"
    fi
    if [ "$("$JQ" -r 'has("autoCompleteSetBy")' "$body")" != false ]; then
      printf 'AUTO_COMPLETE_REQUESTED %s\n' "$(cat "$body")" >> "$SIM/violations"
      die "auto-complete requested"
    fi
    if [ "$("$JQ" -r '.isDraft' "$file")" = true ]; then
      printf 'COMPLETION_OF_DRAFT %s\n' "$id" >> "$SIM/violations"
      die "TF401027: a draft pull request cannot be completed."
    fi
    unmet=$("$JQ" -r '[.[] | select(.configuration.isBlocking == true and .configuration.isEnabled != false
        and (.configuration.type.id | ascii_downcase) != "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"
        and .status != "approved" and .status != "notApplicable")] | length' "$SIM/policies/$id.json")
    if [ "$unmet" != 0 ]; then
      printf 'COMPLETION_PAST_UNMET_BLOCKING_POLICY %s\n' "$id" >> "$SIM/violations"
      die "Conflict({\"message\":\"TF401027: You need the Git 'PullRequestBypassPolicy' permission to perform this action.\"})"
    fi
    source=$("$JQ" -r '.sourceRefName' "$file"); source=${source#refs/heads/}
    target=$("$JQ" -r '.targetRefName' "$file"); target=${target#refs/heads/}
    named=$("$JQ" -r '.lastMergeSourceCommit.commitId // ""' "$body")
    tip=$(branch_tip "$source") || die "TF401398: the source branch no longer exists."
    if [ "$named" != "$tip" ]; then
      printf 'ERROR: Conflict({"$id":"1","innerException":null,"message":"TF401192: The source branch has been modified since the last merge attempt.","typeName":"Microsoft.TeamFoundation.Git.Server.GitPullRequestStaleException, Microsoft.TeamFoundation.Git.Server","typeKey":"GitPullRequestStaleException","errorCode":0,"eventId":3000})\n' >&2
      exit 1
    fi
    strategy=$("$JQ" -r '.completionOptions.mergeStrategy // "noFastForward"' "$body")
    title=$("$JQ" -r '.title' "$file")
    merge=$(complete_in_git "$source" "$target" "$strategy" "$title" "$id") \
      || die "Conflict({\"message\":\"TF401398: the pull request could not be merged.\"})"
    "$JQ" --arg head "$tip" --arg merge "$merge" --slurpfile body "$body" '
      .status = "completed" | .mergeStatus = "succeeded"
      | .lastMergeSourceCommit = {commitId: $head} | .lastMergeCommit = {commitId: $merge}
      | .completionOptions = $body[0].completionOptions' "$file" > "$file.completed"
    if [ -s "$SIM/hooks/async-reads" ]; then
      # Accepted, and finished only after this many later reads.
      mv "$file.completed" "$SIM/prs/$id.pending"
      mv "$SIM/hooks/async-reads" "$SIM/prs/$id.pending-reads"
      "$JQ" '.mergeStatus = "queued"' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      cat "$file"
      exit 0
    fi
    mv "$file.completed" "$file"
    if [ -e "$SIM/hooks/lose-patch-response" ]; then
      rm -f "$SIM/hooks/lose-patch-response"
      die "('Connection aborted.', RemoteDisconnected('Remote end closed connection without response'))"
    fi
    cat "$file"
    exit 0
    ;;
esac
unsupported "$*"
