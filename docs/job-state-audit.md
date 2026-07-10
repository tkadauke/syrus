# Job state machine audit

Snapshot of every state, event, transition, and the callback wiring around
Job's AASM machine. Goal is the same as the Turbo audit: enumerate the
surface so the next "Job got stuck in <state>" bug is a new class, not a
re-discovery.

## State graph

11 declared states. Reachability via production code paths varies — some
states are listed only as `from:` and have no event that enters them.

| State | Entry events | Exit events | Reachable in prod? |
|---|---|---|---|
| `triaging` (initial) | initial; `reopen` | `advance_after_triage`, `mark_classifier_uncertain` (self), `block_by_epic`, `close` | Yes — initial on every `Job.create!` |
| `blocked_by_epic` | `advance_after_triage`, `block_by_epic` | `release_epic_block`, `close` | Yes |
| `queued` | `advance_after_triage`, `release_epic_block` | `mark_implemented`, `block_by_epic`, `close`, `claim_for_coding` | Yes |
| `open` | **None** | `mark_implemented`, `approve`, `block_by_epic`, `close` | **No** (see Finding 1) |
| `coding` | `claim_for_coding` | `release_from_coding`, `close` | Yes — when `coding_mode` feature flag is on and a chat session claims the implement step |
| `implemented` | `mark_implemented`, `unapprove`, `fail_landing`, `release_from_coding` | `approve`, `close`, `claim_for_coding` | Yes |
| `approved` | `approve`, `defer_landing` | `unapprove`, `land`, `start_landing`, `close` | Yes |
| `landing` | `land`, `start_landing` | `mark_merged`, `fail_landing`, `defer_landing`, `close` | Yes |
| `merged` | `mark_merged` | `close` | **No** (see Finding 2) |
| `landing_failed` | **None** | `mark_implemented`, `approve`, `close` | **No** (see Finding 3) |
| `closed` | `close` | `reopen` | Yes |

### Coding Mode lock (`linked_chat_id`)

When a Job is in `:coding` state, `linked_chat_id` is set to the owning
`ChatSession`. `StepDispatcher.start_workflow` skips dispatch while the Job is
in `:coding` state (and the `coding_mode` feature flag is on), leaving any
newly-created workflows queued.

Three exit paths from `:coding`:

- **New-job cancel** (`Job#cancel_new_coding_job!`): clears `linked_chat_id` then
  closes the Job via `close` (`coding → closed`).
- **Takeover cancel** (`Job#release_coding_mode_takeover!`): clears `linked_chat_id`
  then fires `release_from_coding` (`coding → implemented`) and drains queued workflows.
  Used when the operator discards the coding session without handing off.
- **Handoff** (`Job#complete_coding_handoff!`): fires `release_from_coding`
  (`coding → implemented`) but **keeps `linked_chat_id`** so grader results can be
  routed back to the owning session. Also cancels held `initial` workflows (whose
  `implement` step the coding session has already performed). The caller then
  instantiates a `coding_handoff` workflow
  (prepare → grader_fanout → grader_collect → summarize → test_plan → pr_open)
  which runs freely because the job is no longer in `:coding` state.

## Events

| Event | from → to | Callbacks | Production callers |
|---|---|---|---|
| `advance_after_triage` | `triaging → blocked_by_epic` (guard) or `triaging → queued` (guard, after: create_initial_run_if_needed) | guard + after | Job model itself; deferred dependency resolution |
| `mark_classifier_uncertain` | `triaging → triaging` (self) | sets `triaging_reason = "classifier_uncertain"` | IngestionClassifier |
| `block_by_epic` | `[triaging, queued, open] → blocked_by_epic` (guard) | guard | Job#block_by_epic! self-call |
| `release_epic_block` | `blocked_by_epic → queued` (guard, after: create_initial_run_if_needed) | guard + after | Epic model |
| `mark_implemented` | `[queued, running] → implemented` | after: notify_job_implemented | `Steps::PrOpen`, `AutoApprovalRule`, `Job#approve_for_landing!` |
| `approve` | `implemented → approved` | before: assign_approval_metadata | JobsController, app dashboard bulk API, AutoApprovalRule, PollMergeStateJob, PollPullRequestJob |
| `unapprove` | `approved → implemented` | after: clear_approval_metadata | JobsController, `ChatFeedbackSubmission`, `Job#lock_for_coding_mode!` |
| `claim_for_coding` | `[queued, implemented] → coding` | none | `Job#lock_for_coding_mode!` |
| `release_from_coding` | `coding → implemented` | none | `Job#release_coding_mode_takeover!`, `Job#complete_coding_handoff!` |
| `land` | `approved → landing` | none | **None** (see Finding 4) |
| `start_landing` | `approved → landing` | none | LandingQueueProcessor#land |
| `mark_merged` | `landing → merged` | after: lambda (finished_at, closure_reason, scheduled task outcome, refresh_epic_auto_state) | **None** (see Finding 2) |
| `close` | `[triaging, blocked_by_epic, queued, running, implemented, failed, approved, landing, coding] → closed` | transition-level `after:` lambda (finished_at, scheduled task outcome, refresh_epic_auto_state) | Job#close_with_reason! → Steps::AutoMerge, PollPullRequestJob, JobsController, etc. |
| `fail_landing` | `landing → implemented` | after: clears `approved_at` | RunJob.record_landing_failure! |
| `defer_landing` | `landing → approved` | none | Steps::AutoMerge.handle_needs_rebase! + the TRANSIENT_MERGE_ERRORS rescue |
| `reopen` | `closed → triaging` | clears closure_reason, finished_at, failure_count, sets triaging_reason | JobsController#reopen |

## Findings

### 🔴 BUG-class (correctness issues, even if latent)

**Finding 1: `:open` state is unreachable in production.**
- The `after_create :create_initial_run, if: -> { state == "open" && issue? }`
  callback (line 262) and three events with `:open` in their `from:` lists
  imply Jobs can be in `:open` state. But no event transitions TO `:open`,
  and no production `Job.create!` sets `state: "open"` (only Factories does,
  in tests). Jobs are created in `:triaging` (initial) and reach `:queued`
  via `advance_after_triage`. The `after_create` callback never fires in
  prod.
- **Impact:** Dead code; comments at lines 249-260 are stale and misleading.
- **Recommendation:** Either remove `:open` from the AASM state list (and
  from the `from:` lists in `mark_implemented`, `approve`, `block_by_epic`,
  `close`) AND remove the `after_create :create_initial_run` callback, OR
  start using `:open` for something real. Cleaning it up is safer.

**Finding 2: `:merged` state + `mark_merged` event are unreachable in production.**
- `mark_merged` is defined but no production code calls `mark_merged!`. The
  actual merge path runs `job.close_with_reason!("pr_merged")` in
  `Steps::AutoMerge:54` which fires `close` (`:landing → :closed`) — never
  `:merged`. Result: Jobs end up in `:closed` with `closure_reason="pr_merged"`,
  not `:merged`.
- The scope `closed_threads = where(state: %w[closed merged])` matches both
  for compatibility, so queries work either way; but the `:merged` state
  is dead in practice.
- **Impact:** Confusion for new readers. The `Job#merged?` AASM predicate
  always returns false in production despite being called in 6+ places.
  Those calls are effectively no-ops; the real test is
  `closed? && closure_reason == "pr_merged"`.
- **Recommendation:** Either route auto-merge through `mark_merged!` then
  `close!` (preserving the merged-vs-closed distinction) OR delete `:merged`
  + `mark_merged` outright and audit the `merged?` call sites to use
  closure-reason checks. Deleting is simpler and matches actual behavior.

**Finding 3: `:landing_failed` state is unreachable in production.**
- Same shape as `:open`: in three events' `from:` lists, but no event
  transitions TO it, and no direct `state = "landing_failed"` write
  exists in production. RunJob's failure path calls `fail_landing!`
  which sends `:landing → :implemented`, NOT `→ :landing_failed`.
  The `landing_failure_reason` column gets populated on the Job, but
  the state stays `:implemented`.
- **Impact:** Misleading. An operator might assume Jobs in
  `:landing_failed` exist when filtering by state — they don't.
- **Recommendation:** Either route `fail_landing` to `:landing_failed`
  (which would give the operator a clear "this Job tried to land and
  failed" state, distinct from "just implemented, not yet approved")
  OR delete `:landing_failed`. Routing to it is the more honest UX.

**Finding 4: `:land` event is dead code; `:start_landing` is the live one.**
- Two events transition `:approved → :landing` with no callbacks: `land`
  and `start_landing`. Only `start_landing` is fired in production
  (LandingQueueProcessor#land:67). The old `AutoApprovalRule.@job.land!`
  was just removed (commit `7fb6aae`).
- **Impact:** Maintenance hazard; future callers might pick either and
  silently diverge.
- **Recommendation:** Delete the `:land` event.

### 🟡 Inconsistency / smell

**Finding 5: `Job#open?` overrides AASM's literal `state == :open` predicate.**
- `def open?; !closed? && !merged?; end` (line 296). AASM generated `open?`
  for the `:open` state; the override means `job.open?` returns true for
  any state OTHER than `:closed`/`:merged`. Callers expecting "is the
  thread alive" get the right answer; anyone who genuinely wanted "is
  state == :open" silently gets the wrong predicate.
- Compounded with Finding 1: since `:open` is unreachable, the override
  is "always returns the right semantic answer." But the naming is
  treacherous.
- **Recommendation:** If we keep `:open` (Finding 1 says drop it),
  rename the semantic predicate to `active?` or `live?` and let AASM
  own `open?`. If we drop `:open`, the collision goes away and the
  override is the only `open?` definition; just add a comment.

**Finding 6: `close` event has dual `after:` callbacks (event-level + transition-level).**
- Line 210: `event :close, after: :refresh_epic_auto_state do`
- Line 211: `transitions ..., after: -> { finished_at = ...; record_outcome_to_scheduled_task! if cron? }`
- Per AASM, transition-level `after:` runs first, then event-level
  `after:`. Both fire on every close. Works correctly but the dual
  declaration is unusual and easy to misread.
- **Recommendation:** Inline `refresh_epic_auto_state` into the transition
  lambda for consistency with how other events declare their callbacks.

**Finding 7: `refresh_epic_auto_state` fires multiple times per save.**
- `after_save :refresh_epic_auto_state, if: -> { epic_id.present? }` fires
  on EVERY save (not just state changes). Combined with the `close` event's
  callbacks, a single close-with-epic Job triggers refresh_epic_auto_state
  twice (once via transition, once via after_save).
- Likely idempotent (the method probably re-derives state from
  current data), but wasteful — and contributes to the dashboard
  chatter from the Turbo audit (Risk B there).
- **Recommendation:** Tighten the after_save condition to
  `if: :saved_change_to_state? || :saved_change_to_closure_reason?` etc.
  Or move the refresh entirely to AASM transitions.

**Finding 8: Transitions can no-op silently due to `whiny_transitions: false`.**
- `aasm column: :state, whiny_transitions: false do` (line 150) means
  any `state_event!` that doesn't match a transition silently does nothing
  (returns false). This is per-AASM-default; the override is intentional.
- BUT — combined with the dead states (`:open`, `:landing_failed`,
  `:merged`), code like `job.mark_implemented! if job.may_mark_implemented?`
  is defensive in all the right ways. The risk: someone writes
  `job.land!` (no `if may_land?`), the Job isn't in `:approved`, the
  call silently no-ops, and they think it worked. This was nearly the
  shape of the auto-approval bug fixed in `7fb6aae`.
- **Recommendation:** Keep `whiny_transitions: false` (the override is
  needed for the `if may_X?` defensive style we use widely). But add
  a CLAUDE.md note that **never call a state event without `may_`
  guarding it**, and add a single-purpose method when a transition
  needs to be definite (like `LandingQueueProcessor.try_land!`).

### 🟢 Worth noting (low priority)

**Finding 9: `mark_merged`'s callback duplicates `close`'s transition callback.**
- `mark_merged`: sets `finished_at`, `closure_reason ||= "pr_merged"`,
  `record_outcome_to_scheduled_task! if cron?`, `refresh_epic_auto_state`.
- `close` (transition `after:`): sets `finished_at`,
  `record_outcome_to_scheduled_task! if cron?`. Event-level `after:`
  adds `refresh_epic_auto_state`. Doesn't set closure_reason — relies
  on the caller (e.g. `close_with_reason!`) to set it first.
- Once we resolve Finding 2 (drop `:merged` OR route through it), this
  duplication goes away.

**Finding 10: `triaging_reason` is set but never explicitly cleared.**
- `reopen` event clears it back to `"classifier_pending"` (line 244 sets it
  with `||=`). When a Job moves from `:triaging → :queued` via
  `advance_after_triage`, `triaging_reason` keeps its value forever (used
  by the inbox filter `pending_epic_ref` etc.). This is intentional — the
  reason is metadata about the triage process, not just a state — but
  worth confirming queries that filter on `triaging_reason` also gate on
  `state == "triaging"` so post-triage reasons don't leak.
- **Recommendation:** Audit `Filters::Chips::Jobs::TriagingReason` and
  related to confirm they gate on state. (Filed for future review.)

## Recommended cleanup, in priority order

These are concrete code changes, ordered by "biggest correctness/confusion
reduction per LOC touched."

1. **Delete the `:land` event** (Finding 4). Already unused. Net: 4-line
   delete + zero behavior change. Lowest-risk cleanup.

2. **Delete `:open`, `:landing_failed`, `:merged` + their from-references**
   (Findings 1-3). All unreachable. Removes ~15 lines of `from:` lists,
   the dead `after_create :create_initial_run` callback, the
   `mark_merged` event, and the `Job#open?` override (Finding 5). Audit
   call sites of `closed?` / `merged?` and adjust to closure_reason
   checks where needed. Bigger diff but eliminates the audit's largest
   source of confusion.

   ALTERNATIVELY (if we want to ACTUALLY use these states):
   - Route `mark_implemented!` from RunJob.record_landing_failure! to
     `landing_failed!` instead, so failed landings get their distinct
     state.
   - Route auto-merge success through `mark_merged!` then `close!` so
     `:merged` becomes the canonical merged-state.
   - Decide what `:open` is for or drop it.

3. **Tighten `after_save :refresh_epic_auto_state` condition** (Finding 7).
   One-line change; cuts unnecessary callback fan-out and reduces Turbo
   broadcast chatter.

4. **Add CLAUDE.md note: always `if may_X?`-guard state event calls**
   (Finding 8). Documents the convention; no behavior change.

5. **Inline `close` event's outer `after:` into the transition `after:`**
   (Finding 6). Cosmetic but reduces "what fires when" confusion.

## How to use this doc

When introducing or modifying a Job state event:
1. Add the event/state to the tables above.
2. Cross-check the findings: does the change resurrect dead code? Reuse
   a deprecated state? Create new redundancy?
3. If a transition has a callback, document who fires it and what the
   downstream side effects are.

Goal: the next Job-state bug should be a NEW class of issue, not a
re-discovery of something this audit caught.
