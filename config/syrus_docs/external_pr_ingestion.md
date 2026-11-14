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

## Dashboard display

Dashboard lists mark externally authored pull requests with an **External**
badge, including issue Jobs whose Syrus implementation was superseded by an
external pull request.
