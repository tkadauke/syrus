# Issue triage

Every Job created from a labeled GitHub issue starts in `triaging`.
`ClassifyIssueJob` runs `IngestionClassifier`, which asks the agent to place the
request: attach it to an Epic, mark it a duplicate or already implemented, or
leave it as ordinary valid work. The Job leaves `triaging` as soon as that
question is answered.

`Job#triaging_reason` says what it is waiting for:

| Reason | Waiting on | Exit |
|---|---|---|
| `classifier_pending` | the classifier | automatic |
| `pending_epic_ref` | the Epic named in the issue body to exist | automatic |
| `classifier_uncertain` | **a person** | Accept or Reject |

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
3. **A triage decision is opened** (`Decisions::Triage`, queue `triage`,
   urgency `low`) carrying the reason and offering a "Not actionable" action.

## Accept and Reject

The Job page shows two buttons while `triaging_reason` is `classifier_uncertain`,
and only then:

- **Accept** (`POST /api/v1/app/jobs/:job_id/accept_triage`) — "yes, work on
  this". Clears the uncertainty and advances the Job the same way a successful
  classification would: to `queued` (creating the initial Workflow) or to
  `blocked_by_epic` if it has unresolved dependencies.
- **Reject** (`POST /api/v1/app/jobs/:job_id/reject_triage`) — "no". Closes the
  Job with `closure_reason: cancelled`. Not one of
  `Job::SUCCESSFUL_CLOSURE_REASONS`: rejecting an unclear request delivers
  nothing, and filing it as a success would corrupt the attribution closure
  reasons exist to keep honest.

**Move to backlog is not offered while a Job is in triage.** An unclassified Job
in the backlog has simply moved from one place nothing acts on to another;
Accept or Reject is the decision that actually needs making.
