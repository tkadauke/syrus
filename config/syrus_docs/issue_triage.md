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
| `placement_confirmation` | **a person** confirming a non-Linux recommendation | Accept with suggested placement, Accept using Linux, or Cancel |
| `proposed_job` | **a person** reviewing investigation-proposed work | Accept or Reject |

## Issue body markers

Externally filed issues can attach themselves to an Epic only with the explicit
Syrus marker comment: `<!-- syrus-epic: #123 -->`,
`<!-- syrus-epic: 123 -->`, or `<!-- syrus-epic: owner/repo#123 -->`. Bare
numbers always mean an issue in the same repository as the filed issue; use the
owner/repo form for a different repository. Visible prose such as `Epic: #123`
does not route the issue. To migrate an existing template, wrap the old line in
a marker block:

```markdown
<!-- syrus-epic
Epic: #123
-->
```

Job and Epic dependency lines use the same reference syntax:
`Depends-on: #123`, `Depends-on: 123`, `Blocked-by: #123`, or
`Depends-on: owner/repo#123`. Multiple references can be comma-separated. Syrus
records unresolved references as pending dependencies so out-of-order GitHub
issue ingestion cannot accidentally start dependent Epic children independently.

## When the classifier cannot decide

Classifier uncertainty means the classifier could not make a reliable decision
about the issue itself: a malformed response, an unknown Epic id, or an issue
like *"jobs fail silently, syrus needs to do this better"* genuinely cannot be
placed without a person. Exceptions that match Syrus's shared transient or
infrastructure failure vocabulary are treated differently: the attempt is
recorded as errored, but the Job stays `classifier_pending` while retry budget
remains so the queue can try classification again instead of asking a person to
judge an issue the classifier never read.

When a classifier result or exhausted retry budget reaches
`classifier_uncertain`, three things happen:

1. **The reason is recorded** on `Job#triaging_uncertainty_reason` and shown on
   the Job page. Without it there is no way to tell a transient provider error
   (retry it) from an unclear request (read it).
2. **One automatic retry.** `ClassifyIssueJob` retries transient or
   infrastructure exceptions immediately through the job queue. For uncertain
   classifier results, `WorkEngine::Reconciler` picks the Job up ten minutes
   after creation and plans a `reclassify_stalled_intake` repair, which puts it
   back to `classifier_pending` and re-runs the classifier.
   `Job::MAX_CLASSIFIER_ATTEMPTS` (2) bounds both paths: once the budget is
   spent, the Job moves to `classifier_uncertain` with the last reason recorded.
3. **The Job remains in a human-reviewable triage state** with the uncertainty
   reason recorded on the Job itself.

## Accept and Reject

The Job page shows two buttons while `triaging_reason` is
`classifier_uncertain`, `placement_confirmation`, or `proposed_job`, and only then:

- **Accept** (`POST /api/v1/app/jobs/:job_id/accept_triage`) — "yes, work on
  this". Clears the uncertainty and advances the Job the same way a successful
  classification would: to `queued` (creating the initial Workflow) or to
  `blocked_by_epic` if it has unresolved dependencies. For `proposed_job`,
  accept does not re-run classification; the investigation-authored proposal
  already declared the work and execution capabilities, and triage is the
  acceptance gate.
  For `placement_confirmation`, Accept opens a modal with the named profile,
  exact capabilities, classifier explanation, and compatible-worker
  availability when it can be determined. The endpoint requires either
  `placement_decision: suggested` or `placement_decision: linux`; it applies
  that operator-confirmed requirement and creates the initial Workflow in one
  transaction. Cancel leaves the Job unchanged. Bulk Accept skips these Jobs
  so it cannot silently choose placement.
- **Reject** (`POST /api/v1/app/jobs/:job_id/reject_triage`) — "no". Closes the
  Job with `closure_reason: cancelled`. Not one of
  `Job::SUCCESSFUL_CLOSURE_REASONS`: rejecting an unclear request delivers
  nothing, and filing it as a success would corrupt the attribution closure
  reasons exist to keep honest.

**Move to backlog is not offered while a Job is in triage.** An unclassified Job
in the backlog has simply moved from one place nothing acts on to another;
Accept or Reject is the decision that actually needs making.

## Advisory placement recommendations

Issue prose is classifier input, not an authoritative placement declaration.
The classifier can recommend only the validated `linux`, `macos_desktop`, or
`ios_xcode` profiles. A non-Linux recommendation is stored separately with its
explanation, confidence when supplied, and `ingestion_classifier` provenance;
it never changes the Job's active `planned_execution`. `macos_desktop` requires
macOS/arm64 only, while `ios_xcode` additionally requires Xcode and an iOS
simulator. Repository configuration, trusted structured metadata, direct/API
input, and operator choices remain authoritative and bypass recommendation
confirmation.
