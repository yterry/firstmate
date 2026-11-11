# Azure DevOps lifecycle lab

These transcripts come from the real firstmate scripts of this change (`bin/fm-forge-detect.sh`, `fm-project-mode.sh`, `fm-brief.sh`, `fm-pr-check.sh`, the armed `fm-pr-poll.sh`, `fm-review-diff.sh`, `fm-pr-merge.sh`, `fm-crew-state.sh`, `fm-teardown.sh`) run against a disposable lab home made with `bin/fm-lab-home.sh create`.
`git`, `jq`, and `tasks-axi` are the real tools.

## What is simulated

No real Azure DevOps organization was reached: `az` is not installed on this host and no Azure login exists.
`harness/az-simulator.sh` stands in for the `az` CLI.
It keeps one organization, project, and repository on disk, backed by a real bare git repository, and answers `az extension show`, `az repos pr create|show|update|policy list`, and `az rest --method patch` in the shapes `docs/azure-devops-integration.md` records.
A completion PATCH whose `lastMergeSourceCommit` is not the source branch tip is refused with `TF401192`, and an accepted one makes a real squash or merge commit on the target branch.
The simulator records a violation if a completion ever asks for policy bypass, source-branch deletion, or auto-complete, or reaches it past an unmet blocking policy or a draft; every scenario ended with zero violations.

`tmux` is not installed on this host, so it is an inert stub, as are `treehouse`, `gh`, `gh-axi`, and `no-mistakes`.
Scenario 7 gives `fm-crew-state.sh` a canned `no-mistakes axi status` passed-run answer, because no pipeline run against Azure DevOps can exist here.

## Scenarios

| Transcript | What it drives |
| --- | --- |
| `s1-lifecycle` | Intake, brief, worker opens the pull request, scan records the reported link, watch, review diff, completion, merged wake, teardown, backlog note |
| `s2-arming` | Draft refusal and later arming, all URL forms, another repository's id, missing tooling, malformed URLs |
| `s3-watch` | The armed poll stays silent for every state except this pull request's real completion |
| `s4-merge-guards` | Each failing policy or state refuses with no completion request; waiver and strategy rules |
| `s5-head-binding` | Push races, `--expected-head`, lost response, asynchronous and unconfirmed completion |
| `s6-teardown` | Cleanup refuses unless the completed record contains the local work |
| `s7-crew-state` | Passed-run detail for active, abandoned, unreadable, and completed pull requests |
| `s8-degraded-watch-home` | The same flow in a home that enabled `config/pr-degraded-watch` |

Each `CHECK ok` line is an assertion the scenario script made on the observable result just above it.
Machine paths are replaced with `<scratch>` and `<worktree>`.
