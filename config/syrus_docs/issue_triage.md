# Issue triage

Every Job created from a labeled GitHub issue starts in `triaging`.
`ClassifyIssueJob` runs `IngestionClassifier`, which asks the agent to place the
request: attach it to an Epic, mark it a duplicate or already implemented, or
leave it as ordinary valid work. The Job leaves `triaging` as soon as that
question is answered.

Each classifier invocation creates a `JobClassificationAttempt` row. The
attempt records when classification started and finished, whether it classified
the Job, returned an uncertain result, or errored, the decision or error text,
the raw agent output, and the related `SpawnedProcess` when an agent subprocess
was launched. The Job page shows this attempt history while preserving the
existing triage state, so operators can distinguish a Job with an in-flight
classifier from one with no active classifier evidence. The process row also
carries the Job attribution, which makes classification agent processes visible
from the admin processes surface.

`Job#triaging_reason` says what it is waiting for:

| Reason | Waiting on | Exit |
|---|---|---|
| `classifier_pending` | the classifier | automatic |
| `pending_epic_ref` | the Epic named in the issue body to exist | automatic |
| `classifier_uncertain` | **a person** | Accept or Reject |
| `proposed_job` | **a person** reviewing investigation-proposed work | Accept or Reject |

## Issue body markers

Externally filed issues can attach themselves to an Epic with `Epic: #123`,
`Epic: 123`, or `Epic: owner/repo#123`. Bare numbers always mean an issue in
the same repository as the filed issue; use the owner/repo form for a different
repository.

Job and Epic dependency lines use the same reference syntax:
`Depends-on: #123`, `Depends-on: 123`, `Blocked-by: #123`, or
`Depends-on: owner/repo#123`. Multiple references can be comma-separated. Syrus
records unresolved references as pending dependencies so out-of-order GitHub
issue ingestion cannot accidentally start dependent Epic children independently.

## When the classifier cannot decide

Any classifier failure — a malformed response, a provider timeout, an unknown
Epic id, an exception — marks the Job `classifier_uncertain`. That is a real
outcome, not an error: an issue like *"jobs fail silently, syrus needs to do
this better"* genuinely cannot be placed without a person.

Three things happen:

1. **The reason is recorded** on `Job#triaging_uncertainty_reason` and shown on
   the Job page. Without it there is no way to tell a transient provider error
   (retry it) from an unclear request (read it).
2. **One automatic retry.** `WorkEngine::Reconciler` picks the Job up ten
   minutes after creation and plans a `reclassify_stalled_intake` repair, which
   puts it back to `classifier_pending` and re-runs the classifier.
   `Job::MAX_CLASSIFIER_ATTEMPTS` (2) bounds this: a classifier that is
   uncertain twice is telling you about the issue, not about the provider.
3. **The Job remains in a human-reviewable triage state** with the uncertainty
   reason recorded on the Job itself.

## Accept and Reject

The Job page shows two buttons while `triaging_reason` is
`classifier_uncertain` or `proposed_job`, and only then:

- **Accept** (`POST /api/v1/app/jobs/:job_id/accept_triage`) — "yes, work on
  this". Clears the uncertainty and advances the Job the same way a successful
  classification would: to `queued` (creating the initial Workflow) or to
  `blocked_by_epic` if it has unresolved dependencies. For `proposed_job`,
  accept does not re-run classification; the investigation-authored proposal
  already declared the work and execution capabilities, and triage is the
  acceptance gate.
- **Reject** (`POST /api/v1/app/jobs/:job_id/reject_triage`) — "no". Closes the
  Job with `closure_reason: cancelled`. Not one of
  `Job::SUCCESSFUL_CLOSURE_REASONS`: rejecting an unclear request delivers
  nothing, and filing it as a success would corrupt the attribution closure
  reasons exist to keep honest.

**Move to backlog is not offered while a Job is in triage.** An unclassified Job
in the backlog has simply moved from one place nothing acts on to another;
Accept or Reject is the decision that actually needs making.
