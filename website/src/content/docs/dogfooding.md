---
title: Dogfooding
description: How Syrus uses its own issue-to-PR loop to build Syrus, with the merged-PR methodology and limits of the claim.
---

# Dogfooding

95.1% of Syrus's merged pull requests were written by Syrus itself.

That figure comes from an analysis run on September 27, 2026 across all
3,867 pull requests in the `tkadauke/syrus` repository. Of the 1,865 merged
pull requests, 1,773 were written by Syrus: 1,599 were opened by the
`tkadauke-syrus[bot]` GitHub App, and another 174 were opened as `tkadauke`
while carrying Syrus PR-body markers.

## Monthly Share

| Month | Share of merged PRs written by Syrus |
| --- | ---: |
| 2026-05 | 96.6% |
| 2026-06 | 99.8% |
| 2026-07 | 89.1% |
| 2026-08 | 94.6% |
| 2026-09 | 95.1% |

July dipped because of a 41-PR desktop-app sprint by a human contributor.

## Human Merged PRs

The remaining 92 merged pull requests were:

- `skadauke`: 41 desktop-app PRs.
- `dependabot[bot]`: 37 dependency PRs.
- `tkadauke`: 9 May 2026 bootstrap-fix PRs.
- `tkadauke-winston[bot]`: 4 PRs.
- `martinkadauke`: 1 PR.

## Receipts

Naive git-author counting undercounts Syrus. The operator's Syrus instance
runs with his GitHub personal access token connected, so some Jobs open pull
requests as the user and commit as the user. The code paths behind that are
`app/models/job.rb#bot_authored_pull_request?` and
`app/services/bot_identity.rb`.

Syrus's pull requests are therefore identified by body markers its own code
stamps in `app/services/job_metadata_refresh_applier.rb` and
`app/services/steps/pr_open.rb`:

- the `syrus-cost-footer` HTML comment;
- `Authored by <provider> (trigger=...). Review carefully.`;
- `Triggered by @...`;
- machine-generated `Land Epic #N` merge-train titles.

All 1,015 `tkadauke`-authored pull requests were classified: 999 carried
Syrus markers, 7 were `Land Epic #N` merge-train pull requests, and 9 were
human bootstrap fixes.

## Qualifier

This is a merged-pull-request claim, not an unqualified repository-wide
line-churn claim. Line-churn analysis shows roughly 45% Syrus changes and
roughly 50% direct operator pushes to `main`, mostly through the operator's
CLI-agent repair channel, which bypasses pull requests by design.
