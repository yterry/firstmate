#!/usr/bin/env bash
# Shared setup for the Azure DevOps lifecycle lab. Sourced by each scenario.
#
# One lab = one marked disposable firstmate home (bin/fm-lab-home.sh create),
# one bare git repository standing in for the Azure DevOps repository, a
# project clone whose origin URL is the Azure DevOps URL (redirected to the
# bare repository by a clone-local url.insteadOf), a task worktree, and a
# fakebin holding the az simulator plus inert stubs for the tools teardown
# shells out to that this change does not touch (tmux, treehouse, no-mistakes,
# gh, gh-axi). The firstmate scripts under test are the real ones from the run
# worktree; git, jq, and tasks-axi are the real tools.
set -u

TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCR=$(cd "$TOOLS/.." && pwd -P)
WORKTREE=<worktree>
BIN="$WORKTREE/bin"

ORG=fm-lab-org
PROJECT_NAME='Lab Project'
PROJECT_ENC='Lab%20Project'
REPO_NAME=lab-repo
PROJECT_ID=0a1b2c3d-1111-4222-8333-444455556666
REPO_ID=9f8e7d6c-aaaa-4bbb-8ccc-ddddeeeeffff
AZ_REMOTE_URL="https://dev.azure.com/$ORG/$PROJECT_ENC/_git/$REPO_NAME"
ORG_URL_VS="https://$ORG.visualstudio.com"
ORG_URL_DEV="https://dev.azure.com/$ORG"

say() { printf '\n### %s\n' "$*"; }
show() {  # print a command, run it, and report its exit status
  local rc=0
  printf '$ %s\n' "$*"
  "$@" || rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}
check() {  # <description> <command...>: assert, and count failures
  local desc=$1 rc=0
  shift
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'CHECK ok   - %s\n' "$desc"
  else
    printf 'CHECK FAIL - %s\n' "$desc"
    LAB_FAILURES=$((LAB_FAILURES + 1))
  fi
}
LAB_FAILURES=0

g() { git -c user.name='Lab Worker' -c user.email=worker@example.invalid "$@"; }

# new_lab <name>: build a lab and set LAB, HOME_DIR, ORIGIN, PROJ, SIM, FAKEBIN.
new_lab() {
  local name=$1 fakebin
  LAB="$SCR/labs/$name"
  rm -rf "$LAB"
  mkdir -p "$LAB"
  LAB=$(cd "$LAB" && pwd -P)
  HOME_DIR="$LAB/home"
  "$BIN/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || { echo "lab home creation failed" >&2; exit 1; }
  ORIGIN="$LAB/origin.git"
  PROJ="$HOME_DIR/projects/$REPO_NAME"
  SIM="$LAB/sim"
  FAKEBIN="$LAB/fakebin"
  mkdir -p "$SIM/prs" "$SIM/policies" "$SIM/hooks" "$FAKEBIN" "$LAB/user-home"

  # The "Azure DevOps repository".
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN" "$LAB/_seed" 2>/dev/null
  printf '%s\n' base > "$LAB/_seed/shared.txt"
  g -C "$LAB/_seed" add shared.txt
  g -C "$LAB/_seed" commit -q -m "repository baseline"
  g -C "$LAB/_seed" push -q origin HEAD:main
  rm -rf "$LAB/_seed"

  # The project clone: origin is spelled as the Azure DevOps remote, and only
  # this clone's own config redirects it to the bare repository.
  git clone -q "$ORIGIN" "$PROJ"
  git -C "$PROJ" remote set-url origin "$AZ_REMOTE_URL"
  git -C "$PROJ" config "url.file://$ORIGIN.insteadOf" "$AZ_REMOTE_URL"
  git -C "$PROJ" remote set-head origin main 2>/dev/null || true
  git -C "$PROJ" fetch -q origin

  printf '%s\n' "$ORG" > "$SIM/org"
  printf '%s\n' "$PROJECT_NAME" > "$SIM/project.name"
  printf '%s\n' "$PROJECT_ID" > "$SIM/project.id"
  printf '%s\n' "$REPO_NAME" > "$SIM/repo.name"
  printf '%s\n' "$REPO_ID" > "$SIM/repo.id"
  printf '%s\n' "$ORIGIN" > "$SIM/origin"
  printf '%s\n' 4217 > "$SIM/next-id"
  : > "$SIM/az.log"
  : > "$SIM/violations"
  : > "$SIM/patch.log"

  cp "$TOOLS/az" "$FAKEBIN/az"
  for stub in treehouse gh gh-axi; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s %s\\n' '$stub' \"\$*\" >> '$LAB/stub.log'" \
      'case "${1:-} ${2:-}" in' \
      '  "pr list") printf "%s\n" "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;' \
      '  "pr view") echo "error: pull request not found" >&2; exit 1 ;;' \
      'esac' \
      'exit 0' > "$FAKEBIN/$stub"
  done
  # tmux is not installed on this host. The stub lists the windows named in
  # $LAB/tmux-windows (none by default) and reports an idle pane.
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> '$LAB/stub.log'
case "\${1:-}" in
  list-windows) cat '$LAB/tmux-windows' 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  # No no-mistakes run exists for a lab task: every read answers "no run",
  # unless a scenario writes a canned \`axi status\` answer to $LAB/nm-status.
  cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
printf 'no-mistakes %s\n' "\$*" >> '$LAB/stub.log'
# Bare \`axi\` (the overview) and \`axi status\` both carry the run block.
if [ "\${1:-}" = axi ] && [ "\${3:-}" != --run ] && { [ "\$#" = 1 ] || [ "\${2:-}" = status ]; } \\
  && [ -f '$LAB/nm-status' ]; then cat '$LAB/nm-status'; fi
exit 0
SH
  chmod +x "$FAKEBIN"/*
  : > "$LAB/stub.log"

  # Home records: the registry binding, the backlog, and a fresh watcher beat.
  printf '%s\n' '# Projects' '' \
    "- $REPO_NAME [direct-PR forge=azure-devops] - Azure DevOps lab repository (added 2026-11-11)" \
    > "$HOME_DIR/data/projects.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 10' > "$HOME_DIR/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

# fm <script> [args...]: run one real firstmate script against the lab home.
# Every inherited fleet-path override is dropped so all paths resolve inside
# the lab, and HOME is a lab directory so no user-level config is read.
fm() {
  local script=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u TMUX -u GH_HOST \
    FM_HOME="$HOME_DIR" HOME="$LAB/user-home" \
    FM_PR_AZURE_DEVOPS_CONFIRM_DELAY="${FM_PR_AZURE_DEVOPS_CONFIRM_DELAY:-1}" \
    PATH="$FAKEBIN:$PATH" \
    "$BIN/$script" "$@"
}

# add_task <id>: a backlog row In flight, a worktree on fm/<id>, and the task
# record bin/fm-spawn.sh writes for a tmux-backed direct-PR ship task.
add_task() {
  local id=$1
  WT="$LAB/wt-$id"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$WT" origin/main
  PATH="$FAKEBIN:$PATH" tasks-axi add "$id" "Azure DevOps lab task $id" --kind ship \
    --file "$HOME_DIR/data/backlog.md" >/dev/null
  PATH="$FAKEBIN:$PATH" tasks-axi start "$id" --file "$HOME_DIR/data/backlog.md" >/dev/null
  printf '%s\n' \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT" \
    "project=$PROJ" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "branch=fm/$id" \
    "model=default" \
    "effort=default" \
    "spawn_gen=lab-$id-1" > "$HOME_DIR/state/$id.meta"
  chmod 600 "$HOME_DIR/state/$id.meta"
}

# worker_commit <id> <file> <content> <message>: commit in the task worktree.
worker_commit() {
  local id=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$LAB/wt-$id/$file"
  g -C "$LAB/wt-$id" add -- "$file"
  g -C "$LAB/wt-$id" commit -q -m "$msg"
}
worker_push() { g -C "$LAB/wt-$1" push -q origin "fm/$1" 2>&1; }

# worker_open_pr <id> [--draft true]: what the brief's Definition of done tells
# a direct-PR worker to do: open the pull request with az repos pr create and
# report repository.webUrl + /pullrequest/<id>. Sets PR_ID and PR_URL.
worker_open_pr() {
  local id=$1 json
  shift
  json=$(AZ_SIM_WORKER=1 PATH="$FAKEBIN:$PATH" az repos pr create --organization "$ORG_URL_VS" --project "$PROJECT_NAME" \
    --repository "$REPO_NAME" --source-branch "fm/$id" --target-branch main \
    --title "Lab change for $id" "$@" --detect false --output json)
  PR_ID=$(printf '%s' "$json" | jq -r .pullRequestId)
  PR_URL="$(printf '%s' "$json" | jq -r .repository.webUrl)/pullrequest/$PR_ID"
}
worker_report_done() {  # <id> <url>
  printf 'done [at=%s]: PR %s\n' "$(date +%s)" "$2" >> "$HOME_DIR/state/$1.status"
}

# set_policies <pr-id> <head>: an approved required build at <head> and an
# approved minimum-reviewers policy, in the shape az repos pr policy list prints.
policy() {  # <kind> <status> <blocking> <name> [<context-json>] [<settings-json>]
  local type context=${5:-null} settings=${6:-}
  [ -n "$settings" ] || settings='{}'
  case "$1" in
    build) type=0609b952-1397-4640-95ec-e00a01b2c241 ;;
    status) type=cbdc66da-9728-4af8-aada-9a5a32e4a226 ;;
    reviewers) type=fa4e907d-c16b-4a4c-9dfa-4906e5d171dd ;;
    strategy) type=fa4e907d-c16b-4a4c-9dfa-4916e5d171ab ;;
  esac
  jq -nc --arg type "$type" --arg status "$2" --argjson blocking "$3" --arg name "$4" \
    --argjson context "$context" --argjson settings "$settings" '
    {status: $status, context: $context,
     configuration: {isEnabled: true, isBlocking: $blocking, isDeleted: false,
       type: {id: $type, displayName: $name},
       settings: ({displayName: $name} + $settings)}}'
}
write_policies() {  # <pr-id> [<policy-json> ...]
  local id=$1
  shift
  if [ "$#" -eq 0 ]; then printf '[]\n' > "$SIM/policies/$id.json"
  else printf '%s\n' "$@" | jq -s . > "$SIM/policies/$id.json"; fi
}
green_policies() {  # <pr-id> <head>
  write_policies "$1" \
    "$(policy build approved true 'CI build' "{\"lastMergeSourceCommitId\":\"$2\"}")" \
    "$(policy reviewers approved true 'Minimum number of reviewers')"
}

# service_recompute <pr-id>: Azure DevOps recomputing the pull request's merge
# after a push, which is when lastMergeSourceCommit catches up with the branch.
service_recompute() {
  local id=$1 file="$SIM/prs/$1.json" source tip
  source=$(jq -r .sourceRefName "$file"); source=${source#refs/heads/}
  tip=$(git -C "$ORIGIN" rev-parse "refs/heads/$source")
  jq --arg tip "$tip" '.lastMergeSourceCommit = {commitId: $tip}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}
pr_field() { jq -r "$2" "$SIM/prs/$1.json"; }
origin_main() { git -C "$ORIGIN" rev-parse refs/heads/main; }
poll() { fm_state_script "$1"; }
# The armed poll is the per-task check script the watcher runs.
fm_state_script() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$HOME_DIR" HOME="$LAB/user-home" \
    PATH="$FAKEBIN:$PATH" bash "$HOME_DIR/state/$1.check.sh"
}
# run_merge <label> <args...>: run bin/fm-pr-merge.sh, print its transcript,
# and leave MERGE_RC, $LAB/<label>.out and $LAB/<label>.err behind.
run_merge() {
  local label=$1
  shift
  printf '$ fm-pr-merge.sh %s\n' "$*"
  MERGE_RC=0
  fm fm-pr-merge.sh "$@" > "$LAB/$label.out" 2> "$LAB/$label.err" || MERGE_RC=$?
  sed 's/^/stdout: /' "$LAB/$label.out"; sed 's/^/stderr: /' "$LAB/$label.err"
  printf '[exit %s]\n' "$MERGE_RC"
}
# run_check <label> <args...>: the same for bin/fm-pr-check.sh, into CHECK_RC.
run_check() {
  local label=$1
  shift
  printf '$ fm-pr-check.sh %s\n' "$*"
  CHECK_RC=0
  fm fm-pr-check.sh "$@" > "$LAB/$label.out" 2> "$LAB/$label.err" || CHECK_RC=$?
  sed 's/^/stdout: /' "$LAB/$label.out"; sed 's/^/stderr: /' "$LAB/$label.err"
  printf '[exit %s]\n' "$CHECK_RC"
}
run_teardown() {
  local label=$1
  shift
  printf '$ fm-teardown.sh %s\n' "$*"
  TD_RC=0
  fm fm-teardown.sh "$@" > "$LAB/$label.out" 2> "$LAB/$label.err" || TD_RC=$?
  sed 's/^/stdout: /' "$LAB/$label.out"; sed 's/^/stderr: /' "$LAB/$label.err"
  printf '[exit %s]\n' "$TD_RC"
}
run_poll() {  # <id>: run the armed poll, into POLL_OUT
  printf '$ bash state/%s.check.sh\n' "$1"
  POLL_OUT=$(poll "$1" 2>&1)
  printf '%s\n[exit %s, %s bytes of output]\n' "$POLL_OUT" "$?" "${#POLL_OUT}"
}
patch_count() { wc -l < "$SIM/patch.log" | tr -d ' '; }
# open_ready_pr <id>: a task whose worker pushed two commits and opened a
# ready pull request with green policies. Sets WT, PR_ID, PR_URL, HEAD1.
open_ready_pr() {
  local id=$1
  add_task "$id"
  worker_commit "$id" "feature-$id.txt" hello "add feature for $id"
  worker_commit "$id" "notes-$id.txt" notes "add notes for $id"
  worker_push "$id"
  worker_open_pr "$id"
  HEAD1=$(git -C "$WT" rev-parse HEAD)
  green_policies "$PR_ID" "$HEAD1"
}
# The worker's own az calls and the backlog read, printed without the PATH.
worker_az() {
  local rc=0
  printf '$ az %s\n' "$*"
  AZ_SIM_WORKER=1 PATH="$FAKEBIN:$PATH" az "$@" || rc=$?
  printf '[exit %s]\n' "$rc"
}
backlog_show() {
  local rc=0
  printf '$ tasks-axi show %s --file data/backlog.md --full\n' "$1"
  PATH="$FAKEBIN:$PATH" tasks-axi show "$1" --file "$HOME_DIR/data/backlog.md" --full || rc=$?
  printf '[exit %s]\n' "$rc"
}
finish() {
  printf '\n### result: %s check failure(s); simulator violations: %s\n' "$LAB_FAILURES" \
    "$(wc -l < "$SIM/violations" | tr -d ' ')"
  [ ! -s "$SIM/violations" ] || cat "$SIM/violations"
  [ "$LAB_FAILURES" -eq 0 ] && [ ! -s "$SIM/violations" ]
}
