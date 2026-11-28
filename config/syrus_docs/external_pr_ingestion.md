# External PR Ingestion

External PR ingestion discovers pull requests filed outside Syrus against an
opted-in repository and presents them as reviewable Jobs. Enable **External PR
ingestion** in repository settings. Syrus polls open pull requests every five
minutes, skips Syrus-authored branches, and ingests each pull request once.

## Linked issue PRs

When a labeled issue has a linked external pull request, Syrus keeps one
issue-backed Job and marks it implemented without starting a redundant agent
workflow. If an existing issue Job later gains such a pull request, active work
is cancelled and the Job moves to implemented for review.

Maintainers recovering older preempted records should follow the
[external PR ingestion runbook](../../docs/engineering/operations/external-pr-ingestion.md).

## Grader workflow on ingestion

New external PR Jobs immediately run configured graders against the pull
request. Same-repository branches can enter a bounded repair-and-push loop.
Fork branches are read-only: failures produce a request-changes review for the
contributor, while the Job remains implemented and is re-evaluated after new
commits. With no configured graders, ingestion succeeds as a no-op.

If same-repository repair exhausts its retries, the Job fails and automatic
rebase/repair does not obscure that result. **Retry PR Ingestion** starts a
fresh attempt against the current branch.

## Job lifecycle

External PR Jobs start implemented and use the normal review, approval, and
landing pipeline. A GitHub merge or close closes the Syrus Job with the matching
external-PR outcome.

## Feedback comments

Syrus records new issue and review comments, ignores its own bot comments, and
shows actionable feedback in the Job's pending-feedback panel. Comments from
the Job owner always qualify. Repository-member comments qualify when
`feedback_policy` is `auto`; unrelated external comments notify the owner but
do not start work automatically.

For a fork PR, qualifying feedback places the Job in an upstream-changes-
requested waiting state. For a same-repository PR, it launches the normal
response, adversarial-review, grader, summary, and push chain. Only one such
feedback workflow runs at a time, and its response sees the full outstanding
thread. Qualifying feedback clears an existing approval before either path can
continue.

## Bot-authored pull requests

A review that requests changes normally holds an external PR Job until its
author pushes a fix. Dependency bots (Dependabot, Renovate, any author GitHub
reports as a Bot or whose login ends in `[bot]`) never do, so when such a PR's
branch lives in the tracked repository Syrus does not wait for them:

- **Superseded** — if the same bot opened a newer PR for the same dependency
  (or one already merged), the Job closes as `external_pr_superseded`.
- **Stale** — a PR older than `max_age_days`, more than `max_commits_behind`
  commits behind its base, or whose Syrus repair failed applies
  `stale_action`. `refresh` (the default) posts `@dependabot recreate` once per
  Job and waits up to a day for the new head; an unanswered request, a
  recreated PR that goes stale again, or a non-Dependabot bot closes the Job as
  `external_pr_stale`. `close` closes it directly; `wait` keeps the hold.
- **Otherwise** — Syrus addresses the requested changes itself with the
  same-repository feedback chain (respond, review, graders, push), once per
  review, clearing any approval first. Syrus's own grader review is dismissed
  once the new head's checks pass; a person's review still needs that person.

Closing such a Job closes the GitHub PR with a comment. Comments addressed to a
dependency bot (`@dependabot …`, `@renovate …`) are never treated as feedback.
Human-authored PRs and fork PRs keep waiting for their author.

```yaml
external_prs:
  bot_prs:
    review_feedback: repair   # repair (default) | wait
    stale_action: refresh     # refresh (default) | close | wait
    max_age_days: 30          # default 30; 0 disables
    max_commits_behind: 500   # default off; 0 disables
```

Syrus reads this from the default branch's `.syrus.yml`; when that file cannot
be read it keeps waiting.

## Dashboard display

Dashboard lists mark externally authored pull requests with an **External**
badge, including issue Jobs whose Syrus implementation was superseded by an
external pull request.
