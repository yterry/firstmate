#!/usr/bin/env bash
# Disposable Azure DevOps Services simulator for the lab. Keeps one org
# (fm-lab), project "Lab Project", repo lab-repo, backed by a local bare git
# repo. PR state lives in $AZSIM/pr-<id>.json; the source head is read live
# from the bare repo's source branch; a PATCH completion is refused with
# TF401192 when lastMergeSourceCommit is not the live head, and otherwise
# squash-merges into the target branch of the bare repo.
set -u
AZSIM=${AZSIM:?}
printf '%s\n' "$*" >> "$AZSIM/az.log"
arg() { local want=$1; shift; local prev=''; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev=$a; done; }
case "${1:-} ${2:-} ${3:-}" in
  "extension show "*) exit 0 ;;
  "repos pr show")
    id=$(arg --id "$@"); org=$(arg --organization "$@")
    [ "$org" = "https://dev.azure.com/fm-lab" ] || { echo "ERROR: TF400813: not authorized for $org" >&2; exit 1; }
    f="$AZSIM/pr-$id.json"; [ -f "$f" ] || { echo "ERROR: TF401180: The requested pull request was not found." >&2; exit 1; }
    src=$(jq -r .sourceRefName "$f"); head=$(git -C "$AZSIM/origin.git" rev-parse "${src#refs/heads/}" 2>/dev/null || true)
    if [ "$(jq -r .status "$f")" = active ]; then jq --arg h "$head" '.lastMergeSourceCommit={commitId:$h}' "$f"; else cat "$f"; fi
    ;;
  "repos pr policy")
    id=$(arg --id "$@")
    f="$AZSIM/pr-$id.json"; src=$(jq -r .sourceRefName "$f"); head=$(git -C "$AZSIM/origin.git" rev-parse "${src#refs/heads/}")
    jq -n --arg h "$head" '[{status:"approved",context:{lastMergeSourceCommitId:$h},configuration:{isEnabled:true,isBlocking:true,isDeleted:false,type:{id:"0609b952-1397-4640-95ec-e00a01b2c241",displayName:"Build"},settings:{displayName:"ci"}}},
      {status:"approved",context:null,configuration:{isEnabled:true,isBlocking:true,isDeleted:false,type:{id:"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd",displayName:"Minimum number of reviewers"},settings:{displayName:"Minimum number of reviewers"}}}]'
    ;;
  "rest --method patch")
    url=$(arg --url "$@"); body=$(arg --body "$@"); body=${body#@}
    cp "$body" "$AZSIM/last-patch-body.json"
    id=${url##*/pullrequests/}; id=${id%%\?*}
    f="$AZSIM/pr-$id.json"
    case "$url" in "https://dev.azure.com/fm-lab/$(jq -r .repository.project.id "$f")/_apis/git/repositories/$(jq -r .repository.id "$f")/pullrequests/$id?api-version=7.1") ;; *) echo "ERROR: wrong route $url" >&2; exit 1 ;; esac
    src=$(jq -r .sourceRefName "$f"); tgt=$(jq -r .targetRefName "$f")
    head=$(git -C "$AZSIM/origin.git" rev-parse "${src#refs/heads/}")
    want=$(jq -r .lastMergeSourceCommit.commitId "$body")
    if [ "$want" != "$head" ]; then
      echo 'ERROR: Conflict({"$id":"1","innerException":null,"message":"TF401192: The source branch has been modified since the last merge attempt.","typeName":"Microsoft.TeamFoundation.Git.Server.GitPullRequestStaleException"})' >&2
      exit 1
    fi
    [ "$(jq -r .completionOptions.bypassPolicy "$body")" = false ] || { echo "ERROR: bypass not permitted" >&2; exit 1; }
    tree=$(git -C "$AZSIM/origin.git" rev-parse "$head^{tree}")
    parent=$(git -C "$AZSIM/origin.git" rev-parse "${tgt#refs/heads/}")
    merge=$(GIT_AUTHOR_NAME=ado GIT_AUTHOR_EMAIL=ado@example.invalid GIT_COMMITTER_NAME=ado GIT_COMMITTER_EMAIL=ado@example.invalid \
      git -C "$AZSIM/origin.git" commit-tree "$tree" -p "$parent" -m "Merged PR $id (squash)")
    git -C "$AZSIM/origin.git" update-ref "$tgt" "$merge"
    jq --arg h "$head" --arg m "$merge" --arg s "$(jq -r '.completionOptions.mergeStrategy // "squash"' "$body")" \
      '.status="completed" | .lastMergeSourceCommit={commitId:$h} | .lastMergeCommit={commitId:$m} | .completionOptions={mergeStrategy:$s}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    jq -c '{status, pullRequestId}' "$f"
    ;;
  *) echo "ERROR: az simulator: unsupported: $*" >&2; exit 2 ;;
esac
