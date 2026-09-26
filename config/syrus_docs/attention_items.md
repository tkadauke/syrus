# Attention Items (Decision/Escalation Queue)

`AttentionItem` (workflow-engine-v3 B2) is the unit of human attention: one
problem, its structured evidence, an adjudicator's verdict if one exists
(`Adjudication`), and one to three typed actions bound to the existing
`PendingActions` registry. It replaces reconstructing "what needs a decision"
from Job/Workflow state and logs.

Backend producers open items into one of the queues
(`AttentionItem::QUEUES`):

- **`AttentionItems::Escalator`** — opens an `operator` queue item when a
  Workflow fails and nothing cheaper resolved it (rung 4 of the attention
  ladder — see `app/services/attention_ladder.rb`). Reuses an open item for
  the same problem `signature` rather than filing one per occurrence, and
  declines entirely once a prior decision for that signature is still in
  scope and unexpired.
- **`AttentionItems::Triage`** — opens a `triage` queue item when
  `IngestionClassifier` cannot place an incoming Job (`state: "triaging"`,
  `triaging_reason: "classifier_uncertain"`). Different audience and SLA from
  operator escalations, hence the separate queue on the same mechanism.
- **`WorkEngine::RepeatedFailureCircuit`** — opens an urgent `operator` queue
  item when the reconciler sees the same failed-workflow exception fingerprint
  three attempts in a row on the same app revision. The item is deliberately
  distinct from an ordinary failed-Run notification: automatic retry/rebuild is
  paused, the evidence includes the latest fingerprint, revision, streak count,
  exception class/message, top stack frames, and current Workflow/Step/Run
  identifiers, and the admin system-alert banner links operators back to this
  queue. The open queue item is keyed to the actionable Job plus repeated-failure
  circuit, not to the volatile fingerprint or app revision, so a later trip for
  the same Job refreshes the existing row with current evidence and supersedes
  older repeated-failure rows. Operators should still inspect the latest
  fingerprint and app revision before retrying, but the queue represents one
  decision: fix or deploy the underlying condition, manually retry after that
  change, or deliberately dismiss the evidence as a false positive.

## Operator surface

Admin -> Attention Items (`/admin/attention_items`,
`Api::V1::App::Admin::AttentionItemsController`) lists open items
(`AttentionItem.open_decisions`, most urgent first) with row-level detail:
evidence, the adjudicator's verdict when present, and each typed action's
label/detail (`AttentionItems::ActionContext` renders the same
`PendingActions::Base#action_detail` a chat pending-action card would).

- **Run an action** (`POST .../:id/act`) executes one of the item's own
  `actions` entries through `AttentionItems::ActionExecutor` — the same
  `PendingActions::*` command classes chat confirmation uses, without a
  `ChatPendingAction` row (an `AttentionItem` is opened by a backend
  producer, not proposed in a chat turn, so there is no chat session to
  attach one to). The acting admin is wrapped in
  `AttentionItems::AdminActingUser` so `PendingActions::Base#action_job`-style
  Job lookups (`user.jobs.find`) resolve any Job, not only ones the admin
  happens to own — an operator working an escalation queue routinely isn't
  the Job's creator. Every run is audited via `AdminAction.log!` under
  `attention_item_<action_key>`.
- **Decide** (`POST .../:id/decide`) records the human verdict
  (`AttentionItem#decide!`: `upheld` / `dismissed` / `deferred` + reason) and
  moves the item out of the default open view. `AttentionItems::Opener`
  consults prior decisions by signature before filing a new item, so a
  dismissal compounds instead of re-asking the same question.

Filtering (state/queue/urgency/repository) uses the shared `FilterBar`
(`Admin::EventLogFilterDefinition`, the same pattern as `/admin/work_units`).
The React page uses the shared admin data-table panel: top summary,
pagination controls, column selector, sortable headers, table body, and bottom
pagination. The app payload returns `filter_schema`, `filter`, `filters`, and
`pagination`; sortable columns use `sort` / `direction` and currently cover
urgency (the default open-queue ordering), creation time, queue, state, and
problem code. Smart folders were deliberately not added for this surface — the
queue is meant to stay small by design (see `AttentionItems::Opener`'s
dedupe/decision reuse above), so a saved-view layer wasn't worth the added
surface yet.
