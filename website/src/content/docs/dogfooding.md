---
title: Dogfooding
description: How Syrus uses its own issue-to-PR loop to build Syrus, with the landed-original-PR methodology and limits of the claim.
---

# Dogfooding

97.6% of Syrus's landed original pull requests were written by Syrus itself,
as of the October 24, 2026 audit. Using the corrected method, the same figure
through September 27 is 97.3%, superseding the previously published 95.1%.

That figure comes from an analysis run on October 24, 2026 across all 5,208
pull requests in the `tkadauke/syrus` repository. Integration pull requests
such as Land Epic trains and Land job bundles are landing vehicles, not
separate units of work, so the audit excludes those vehicles and counts each
original member once, in its landing month. Of 4,451 landed originals, 4,346
were written by Syrus. Of all resolved originals, 98.1% landed and 1.9% were
discarded as failed experiments, cancelled work, or superseded attempts.

## Monthly Share

| Month | Syrus-written landed originals |
| --- | ---: |
| 2026-05 | 96.6% (315/326) |
| 2026-06 | 99.8% (537/538) |
| 2026-07 | 92.5% (520/562) |
| 2026-08 | 97.1% (769/792) |
| 2026-09 | 98.7% (1,165/1,180) |
| 2026-10 | 98.8% (1,040/1,053) |

July dipped because of a 41-PR desktop-app sprint by a human contributor.

## Human Landed PRs

The remaining 105 landed originals were:

- `skadauke`: 41 desktop-app PRs.
- `dependabot[bot]`: 45 dependency PRs.
- `tkadauke`: 13 PRs.
- `tkadauke-winston[bot]`: 5 PRs.
- `martinkadauke`: 1 PR.

## Receipts

Naive git-author counting undercounts Syrus. Syrus supports both GitHub App
and personal-access-token authorship modes, so some Jobs open pull requests as
the user and commit as the user. The code paths behind that are
`Job::CREDENTIAL_MODES` in `app/models/job.rb`,
`GithubClient.for_authorship(...)` in `app/services/steps/pr_open.rb`, and
`app/services/bot_identity.rb`.

Syrus's pull requests are therefore identified by body markers its own code
stamps in `app/services/job_metadata_refresh_applier.rb`,
`app/services/steps/pr_open.rb`, `app/services/pr_cost_footer.rb`, and the
merge-train step definitions in `app/models/step/kind.rb`:

- the `syrus-cost-footer` HTML comment;
- `Authored by <provider> (trigger=...). Review carefully.`;
- `Triggered by @...`;
- machine-generated `Land Epic #N` merge-train titles.

All 2,169 `tkadauke`-authored original pull requests were classified: 2,154
were Syrus work identified by markers or a machine-generated `Land Epic #N`
title, and 15 were human work. Of those human originals, 13 landed and 2 did
not. This distinction is load-bearing: Syrus used GitHub App credentials from
June through August 2026, then switched to personal-access-token credentials
during September, so author identity alone cannot separate Syrus from the
operator.

## Qualifier

This is a landed-original-PR claim, not an unqualified repository-wide
line-churn claim. The layers answer different questions: of distinct lines
landed through pull requests, 95.3% were Syrus work. Across all main-line
churn, 70.9% arrived through pull requests and 29.1% through direct pushes.
That direct-push churn was mostly the operator's interactive restructuring,
moves, and deletions, substantially assisted by a CLI agent; it is not evidence
that feature work routinely bypassed Syrus.

These percentages are point-in-time audit claims, not live counters. Rerun the
audit before changing this page or the homepage badge again.
