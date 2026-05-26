# Plan: extend the filter framework to support Epics

_Captured 2026-05-16._

## Context

Search filters exist for Jobs (`Jobs::Filter`, `Filters::Chips::*`, the
`q=` chip-bar UI, SmartFolders) and they work well. But the framework
is implicitly Job-coupled in two places: `Filters::Registry::CHIPS` is
a single flat Job-shaped map, and `Filters::Chips::*` contains both
generic column-driven chips and Job-specific behavioural chips in the
same namespace.

We want the same filter UX for Epics, **without** rewriting the chip
DSL or losing the shared column-type infrastructure. The plan is four
phases: split the Job-coupled pieces from the truly generic ones,
introduce a small "subject" abstraction, namespace the Job chips,
then build out the Epic subject end-to-end.

## Architecture decisions (already agreed)

- **Per-subject Filter classes**: `Jobs::Filter` + new `Epics::Filter`.
  They share AST + Compiler + QueryParam + chip DSL via composition,
  but each owns its URL-param translation and its SmartFolder
  integration.
- **SmartFolders become subject-aware**: add `subject_type` column to
  `smart_folders` (default `"job"` for back-compat). Builtins are
  defined per-subject. Same model, no separate `EpicSmartFolder`.
- **Phase ordering**: 1 → 2 → (3 + 4 together).

## Phase 1 — inventory: identify what's generic vs Job-specific

No production code change. Two deliverables:

1. **Inventory table** in a comment block at the top of
   `app/services/filters/registry.rb` mapping each chip to one of:
   - `generic` — works for any AR model that has the column (e.g.
     `CreatedAt`, `UpdatedAt`, `RepositoryId`, `FkColumn`, the
     `*Column` family)
   - `job` — hard-coded Job behaviour (`PrPresent`, `Attention`,
     `HasActiveRun`, etc.)
   - `column-named-after-job` — mechanism is generic but the
     declared column is Job-specific (e.g. `Title` ⇒
     `column :issue_title`); in Phase 3 these will end up under
     `Filters::Chips::Jobs::*` because each subject wants its own
     column binding.

2. **A test** that asserts every chip class implements the chip DSL
   correctly (`filter_name`, `bucket`, `operators`, `apply`). Cheap
   guard for the namespace move in Phase 3.

Outcome: no behaviour change, clear picture of what moves.

## Phase 2 — introduce `Filters::Subject`

A small new class:

```ruby
module Filters
  class Subject
    attr_reader :name, :model, :chips
    def initialize(name:, model:, chips:); ... end
    def find_chip(field) ... end
  end

  SUBJECTS = {
    job:  Subject.new(name: :job,  model: Job,  chips: { ... }),
    epic: Subject.new(name: :epic, model: Epic, chips: { ... })  # Phase 4
  }.freeze

  def self.subject_for(name)
    SUBJECTS.fetch(name.to_sym) { raise ArgumentError, "unknown subject: #{name}" }
  end
end
```

`Filters::Registry.for(subject)` and `Filters::Schema.for(subject:, user:)`
become thin lookups onto `Subject#chips`. `Filters::Compiler.call(node,
scope:, user:, subject: :job)` gains a `subject:` kwarg; the compiler
uses it to dispatch chip lookups against the right subject.

`Jobs::Filter` passes `subject: :job` everywhere. Existing chips and
the existing `Registry::CHIPS` flat map are kept *as the job
subject's chip map* — no chip files move yet. Bit-for-bit identical
behaviour for Job filtering after this phase.

**Deliverable**: One PR.

## Phase 3 — move Job-specific chips under a namespace

Mechanical refactor. New layout:

```
app/services/filters/chips/
  base.rb
  string_column.rb        # generic
  number_column.rb
  date_column.rb
  enum_column.rb
  fk_column.rb
  boolean_column.rb       # NEW — generalize PrPresent's scope-pair pattern
  created_at.rb           # generic (any model)
  updated_at.rb           # generic
  repository_id.rb        # generic (any model with repository_id)
  jobs/
    state.rb              # job-specific values
    kind.rb
    priority.rb
    closure_reason.rb
    triaging_reason.rb
    validity.rb
    pr_present.rb
    pr_mergeable.rb
    pr_number.rb
    pr_title.rb
    branch_name.rb
    issue_number.rb
    title.rb              # column :issue_title
    description.rb        # column :issue_body
    epic_id.rb
    parent_job_id.rb
    has_active_run.rb
    has_unread_feedback.rb
    has_child_jobs.rb
    has_parent_job.rb
    has_blocked_deps.rb
    pinned_by_me.rb
    latest_workflow_state.rb
    latest_workflow_trigger_kind.rb
    latest_run_state.rb
    last_seen_comment_at.rb
    finished_at.rb         # column :finished_at — Job-specific timing
    age.rb
    agent_provider.rb
    tags.rb
    attention.rb           # the big preset
```

Filter-name strings stay the same (`"state"`, `"pr_present"`, etc.)
so stored `q=` URLs and SmartFolder filters keep working.
`Subject.find(:job).chips` gets updated to point at the new class
names.

**Deliverable**: One large rename PR. Mostly diff churn, zero
behaviour change.

## Phase 4 — Epic subject end-to-end

### Phase 4a — SmartFolder gains `subject_type`

```sql
ALTER TABLE smart_folders
  ADD COLUMN subject_type VARCHAR(16) NOT NULL DEFAULT 'job';
CREATE INDEX index_smart_folders_on_subject_type_and_user_id
  ON smart_folders (subject_type, user_id);
```

Existing rows backfill to `'job'`. The model:

```ruby
class SmartFolder < ApplicationRecord
  enum :subject_type, { job: "job", epic: "epic" }, validate: true
  scope :for_subject, ->(name) { where(subject_type: name.to_s) }
end
```

`BUILTIN_DEFINITIONS` splits into two arrays — `JOB_BUILTINS` (today's
list, unchanged) and `EPIC_BUILTINS` (new, see 4c). Built-in seeding
checks `for_subject(:job)` / `for_subject(:epic)` separately.
Uniqueness scope on `(user_id, name)` widens to `(user_id, name,
subject_type)` so a user can have a `"In progress"` folder for both
subjects.

### Phase 4b — `Epics::Filter`

Mirror of `Jobs::Filter`:

```ruby
module Epics
  class Filter
    LEGACY_URL_KEYS = %w[ state repository_id ].freeze

    def self.from_params(params, smart_folder: nil, user: nil)
      # same shape as Jobs::Filter but Epic-specific URL keys
      # ...
      new(tree, user: user)
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :epic)
    end
    # ...
  end
end
```

### Phase 4c — Epic chip set

New chips under `Filters::Chips::Epics::*`. Inventory:

**Reused generic chips** (just point at the right column):

| Chip | Mechanism | Notes |
|---|---|---|
| `RepositoryId` | FkColumn | shared verbatim |
| `CreatedAt`    | DateColumn | shared verbatim |
| `UpdatedAt`    | DateColumn | shared verbatim |

**Epic-specific column chips** (new subclasses, generic mechanism):

| Chip | Type | Column / values |
|---|---|---|
| `Filters::Chips::Epics::State`       | EnumColumn   | values: `backlog`, `ready`, `in_progress`, `done` |
| `Filters::Chips::Epics::Title`       | StringColumn | `column :title` |
| `Filters::Chips::Epics::Description` | StringColumn | `column :description` |
| `Filters::Chips::Epics::DoneAt`      | DateColumn   | `column :done_at` |
| `Filters::Chips::Epics::Number`      | NumberColumn | `column :number` |
| `Filters::Chips::Epics::AutoApproveMode` | EnumColumn | values from `Epic::AUTO_APPROVE_MODES` |
| `Filters::Chips::Epics::Tags`        | (deferred — Epic doesn't have tags yet) |
| `Filters::Chips::Epics::Priority`    | (deferred — Epic doesn't have priority yet) |
| `Filters::Chips::Epics::Kind`        | (deferred — Epic doesn't have kind yet) |

The "maybe" chips from question 3 (`tags`, `priority`, `kind`) are
**deferred** until the columns exist on Epic. Adding them later is a
one-file addition; not worth bundling them speculatively now.

**Epic-specific derivation chips** (new, with custom `apply`):

| Chip | Semantics |
|---|---|
| `HasChildJobs`           | boolean — `EXISTS (SELECT 1 FROM jobs WHERE epic_id = epics.id)` |
| `HasOpenChildren`        | boolean — at least one child Job is `state = "open"` |
| `HasBlockedChildren`     | boolean — at least one child Job has unsatisfied `JobDependency` |
| `ChildJobCount`          | NumberColumn-style — count of child Jobs (range / threshold ops) |
| `ChildProgressPercent`   | NumberColumn-style — % of child Jobs merged (`closure_reason ∈ pr_merged/external_pr_merged`); operator filters like "is_above 50%" |
| `HasEpicDependency`      | boolean — has at least one unresolved `EpicDependency` |
| `Attention` (epic-flavored) | preset macro chip — see below |

### Epic attention presets (Phase 4c, `Filters::Chips::Epics::Attention`)

Candidates — pick the ones to ship in v1:

| Preset | Definition |
|---|---|
| `ready_to_start`      | `state = "ready"` (auto-readied — dependencies resolved + child jobs confirmed) |
| `in_progress`         | `state = "in_progress"` |
| `stalled`             | `in_progress` + no Run activity on any child Job in last 7 days |
| `empty`               | no child Jobs yet — operator should add work |
| `all_children_merged_not_done` | every child Job merged but Epic not yet `done` (auto_complete didn't fire) |
| `blocked_by_dependency` | has at least one unresolved `EpicDependency` |
| `recently_done`       | `state = "done"` + `done_at` within last 7 days |
| `awaiting_approval`   | child Jobs in `implemented` state (operator needs to approve them) |

I'd ship: `ready_to_start`, `in_progress`, `stalled`, `empty`,
`blocked_by_dependency`, `recently_done`. Defer the others until
usage shows they're useful.

### Phase 4c — Builtin SmartFolders for Epics

```ruby
EPIC_BUILTINS = [
  { key: "epics_in_progress",     name: "In progress",     visibility: :always,       filter: epic_attention_preset_filter("in_progress") },
  { key: "epics_ready",           name: "Ready",           visibility: :when_present, filter: epic_attention_preset_filter("ready_to_start") },
  { key: "epics_blocked",         name: "Blocked",         visibility: :when_present, filter: epic_attention_preset_filter("blocked_by_dependency") },
  { key: "epics_stalled",         name: "Stalled",         visibility: :when_present, filter: epic_attention_preset_filter("stalled") },
  { key: "epics_empty",           name: "Empty",           visibility: :on_demand,    filter: epic_attention_preset_filter("empty") },
  { key: "epics_recently_done",   name: "Recently done",   visibility: :on_demand,    filter: epic_attention_preset_filter("recently_done") }
].freeze
```

### Phase 4d — controller / UI wiring

- `EpicsController#index` consumes `Epics::Filter.from_params(...)`,
  surfaces a sidebar of Epic SmartFolders.
- Chip-bar UI partial accepts a `subject:` parameter and renders
  `Filters::Schema.for(subject: :epic, user: current_user)`.
- The existing `filter_memory_controller.js` becomes
  subject-aware (key the memory by `subject` so navigating between
  Jobs and Epics doesn't clobber each other's last filter).

## Acceptance (whole plan)

- [ ] Phase 1: inventory comment + chip-DSL guard test land. No
      behaviour change.
- [ ] Phase 2: `Filters::Subject` exists. `Filters::Registry.for(:job)`
      / `Filters::Schema.for(subject: :job)` work. Job filter
      end-to-end behaviour byte-identical (spec-verified).
- [ ] Phase 3: Job chips live under `Filters::Chips::Jobs::*`.
      Filter-name strings unchanged. URL/SmartFolder back-compat
      preserved.
- [ ] Phase 4a: `smart_folders.subject_type` column with default
      `'job'`. Existing rows backfilled. Uniqueness scoped per
      subject_type.
- [ ] Phase 4b/c: `Epics::Filter` + the listed Epic chip set ship.
      The 6 epic builtin SmartFolders seed correctly.
- [ ] Phase 4d: `EpicsController#index` accepts `q=` chip-bar URLs and
      renders the sidebar. Chip-bar UI is subject-aware.
- [ ] No regressions: full Job filter spec suite passes unchanged.

## Out of scope

- Adding `tags`, `priority`, `kind` to Epic. Defer until those
  columns exist.
- A unified cross-subject search ("show me everything matching X").
  Plausible later; not in this plan.
- Filter chips for `Workflow` or `Run` (no UI demand yet).
- Migrating the legacy URL-key dropdown form on the Jobs side
  (`LEGACY_URL_KEYS`) — that stays as-is.
- Composite "Epic with child Job criteria" chips (e.g. "Epics whose
  children include a failed run"). Doable but adds complexity;
  defer until requested.

## Risks

- **Phase 3 rename churn**: ~30 file renames. Reviewer-fatigue risk.
  Mitigation: land Phase 2 first (proves the subject abstraction
  works), then a single mostly-mechanical PR for Phase 3 that the
  CI-rubocop diff makes easy to scan.
- **SmartFolder uniqueness scope change**: `(user_id, name)` →
  `(user_id, name, subject_type)`. If existing user-created folders
  conflict with new Epic-builtin names (unlikely — current builtins
  don't include "In progress" for both subjects today, but
  user_defined folders could), the migration needs to handle the
  conflict. Mitigation: data-migration step that adds a "(Jobs)"
  suffix to any conflicting user folders before adding the unique
  index.
- **Phase 4 chip semantics could drift from intent**: the Epic
  `attention` presets are guesses without real usage data. Mitigation:
  ship the 6-preset minimum, instrument view counts, drop / add
  presets based on observed usage.

---

# Appendix (added 2026-05-17 after Phases 1–4 shipped)

The original four phases delivered Epic filters and a standalone
`/epics` index. The next chunk of work merges Jobs and Epics onto a
single dashboard surface and extends the same filter + kanban
treatment down to Workflows so the operator gets the same UX at all
three levels of the hierarchy (Epic → Job → Workflow).

## Phase 5 — universal dashboard with subject + view toggles

### Goal

Single landing dashboard at `/`. Two orthogonal toggles:

- **Subject**: `Epic` / `Job` / `Workflow` (Workflow added in Phase 6)
- **View**: `List` / `Kanban`

Filters (the chip-bar) and SmartFolders work in both views. All four
(eventually six) combinations are first-class.

### URL shape

```
/                          → user's persisted last subject + view (default: epic/list on first visit)
/?subject=epic&view=kanban → explicit selection
/?subject=job&view=list
/jobs                      → 302 to /?subject=job
/epics                     → 302 to /?subject=epic
```

The chip-bar `q=` param still rides on top: `/?subject=epic&view=kanban&q=<base64>`.

### Persistence

Per-user, in a new `users.dashboard_preferences` JSON column (or
existing preferences column if one exists). Stores `last_subject`,
`last_view`. On `/` with no params, redirect to the persisted state.
Explicit `subject=`/`view=` params take precedence and update the
preference.

### Kanban column dimensions per subject

Each subject's kanban needs a column-defining attribute. Decisions
here are load-bearing — they shape the operator's mental model.

| Subject | Column dimension | Columns |
|---|---|---|
| Epic | `state` | `backlog`, `ready`, `in_progress`, `done` |
| Job | `latest_workflow_state` (derived) | `queued`, `running`, `succeeded`, `failed` |
| Workflow | `state` (direct AASM) | `queued`, `running`, succeeded/failed/cancelled rolled into a single `done` column (or split — see Phase 6 open question) |

Jobs don't have a useful native state machine for kanban (`open`/`closed`
is binary). `latest_workflow_state` is the most informative
derivation — "what is this Job's most recent attempt doing right now."
Alternative considered: a synthetic "stage" enum (Triage / Implementing
/ Reviewing / Merged). Rejected for v1 — would require additional
derivation logic and operator re-education vs. just showing the
existing state.

### What stays on the dashboard alongside the toggle

The existing home dashboard surfaces more than a Job list (cost
totals, recent activity, smart-folder counts). On the unified
dashboard:

- **Top of page (unchanged across subjects)**: user-wide cost totals,
  user-wide recent-activity summary. These are user-scoped, not
  subject-scoped.
- **Subject toggle + view toggle**: a horizontal control row beneath
  the user-wide summary.
- **Filter chip-bar**: subject-aware (`Filters::Schema.for(subject:)`),
  re-renders when subject changes. Filter state is scoped per subject
  in `filter_memory_controller.js` (key by subject so switching
  doesn't clobber the other's filter).
- **Sidebar with SmartFolders**: subject-aware
  (`SmartFolder.for_subject(name)`), built-ins appear per subject.
- **Main content area**: List view or Kanban view, depending on the
  view toggle.

### Kanban renderer shape

A shared partial `app/views/shared/_kanban_board.html.erb` that
accepts:

```erb
<%= render "shared/kanban_board",
      subject: :epic,
      records: @records,                    # the filtered AR collection
      column_attribute: :state,             # how to bucket
      columns: %w[backlog ready in_progress done],  # explicit order
      card_partial: "epics/card",            # subject-specific card render
      drag_enabled: true                     # whether DnD transitions are wired up
%>
```

Drag-and-drop for state transitions reuses the existing
`epic_kanban_controller.js` pattern (originally from PR #496), but the
controller becomes subject-aware via a `data-` attribute pointing at
the AASM-transition endpoint per subject. The Jobs kanban probably
doesn't get drag-and-drop in v1 (Jobs transition implicitly when
their Runs do, not by operator action).

### Acceptance

- [ ] `/` honours `subject=` and `view=` URL params; defaults from
      `users.dashboard_preferences` when unset
- [ ] `/jobs` and `/epics` 302 to `/?subject=job` / `/?subject=epic`
      for back-compat with existing bookmarks
- [ ] Subject toggle visibly switches the chip-bar, sidebar, and
      content area; filter state isolated per subject
- [ ] View toggle switches between List and Kanban for the current
      subject; filter state preserved across the switch
- [ ] Epic kanban: columns `backlog → ready → in_progress → done`;
      drag-and-drop transitions work via the existing controller
- [ ] Job kanban: columns derived from `latest_workflow_state`; no
      drag-and-drop in v1 (read-only kanban)
- [ ] Workflow kanban: lands in Phase 6
- [ ] Persisted preference: refreshing `/` lands on the last subject +
      view the user used
- [ ] Spec coverage: each (subject × view) combination round-trips
      through URL + chip-bar + filter without state leaking across
      subjects

### Open question

- **Kanban drag for Jobs?** Jobs don't have operator-driven state
  transitions today (state machine is `open ⇄ closed`, advanced by
  workflow completion). Read-only kanban is simpler and probably the
  right v1; revisit if there's demand for "drag a Job between buckets
  to manually advance it."

### Out of scope

- A combined cross-subject view ("show me everything matching X
  regardless of subject"). Different problem.
- Persisting per-subject *filter state* in the DB (vs localStorage).
  Today's chip-bar filter memory is browser-local; that stays.
- Kanban swim lanes (e.g. group Jobs in each column by repository).
  Plausible later; not v1.

## Phase 6 — Workflows as a third subject

### Goal

Apply the same filter + kanban treatment to Workflows. Without this,
the dashboard is consistent for two of three hierarchy levels and
operators have to drop into a Job's detail page to see Workflow state.

### Phase 6a — `Workflows::Filter` + Workflow chip set

Mirror of `Epics::Filter` / `Jobs::Filter`:

```ruby
module Workflows
  class Filter
    LEGACY_URL_KEYS = %w[ state trigger_kind job_id ].freeze
    # same shape as Jobs::Filter / Epics::Filter
    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :workflow)
    end
  end
end
```

Register the subject:

```ruby
Filters::SUBJECTS[:workflow] = Filters::Subject.new(
  name: :workflow,
  model: Workflow,
  chips: { ... }
)
```

#### Workflow chip set

Reused generics (no new files):

| Chip | Source |
|---|---|
| `CreatedAt` | generic |
| `UpdatedAt` | generic |

Workflow-specific column chips (new files under `Filters::Chips::Workflows::*`):

| Chip | Type | Column / values |
|---|---|---|
| `State` | EnumColumn | `queued`, `running`, `succeeded`, `failed`, `cancelled` |
| `TriggerKind` | EnumColumn | `initial`, `pr_comment`, `ci_failure`, `retry`, `manual`, `rebase` |
| `JobId` | FkColumn | `column :job_id` |
| `AgentProvider` | EnumColumn | from `AgentProviders::REGISTRY` |
| `StartedAt` | DateColumn | `column :started_at` |
| `FinishedAt` | DateColumn | `column :finished_at` |
| `FailureReason` | StringColumn | `column :failure_reason` |

Workflow derivation chips:

| Chip | Semantics |
|---|---|
| `HasFailedSteps` | boolean — `EXISTS Step.where(workflow_id: ..., state: "failed")` |
| `IsStuck` | boolean — `state = "running"` AND latest Run's `last_heartbeat_at` older than `Run::STALE_HEARTBEAT_THRESHOLD` |
| `RunCount` | numeric — total Runs in this Workflow (range / threshold ops) |

#### Attention preset (`Filters::Chips::Workflows::Attention`)

v1 preset list:

| Preset | Definition |
|---|---|
| `running` | `state = "running"` |
| `stuck` | `state = "running"` + stale heartbeat |
| `just_failed` | `state = "failed"` + `finished_at` within last 1h |
| `queued` | `state = "queued"` (not yet picked up) |
| `interrupted` | `state = "cancelled"` AND a `cancellation_reason` indicating worker-died (only meaningful once that distinction is encoded) |

### Phase 6b — Workflow SmartFolder builtins

Add to `SmartFolder` per the Phase 4a `subject_type` machinery:

```ruby
WORKFLOW_BUILTINS = [
  { key: "workflows_running",    name: "Running",    visibility: :always,       filter: workflow_attention("running") },
  { key: "workflows_stuck",      name: "Stuck",      visibility: :when_present, filter: workflow_attention("stuck") },
  { key: "workflows_just_failed", name: "Just failed", visibility: :when_present, filter: workflow_attention("just_failed") },
  { key: "workflows_queued",     name: "Queued",     visibility: :on_demand,    filter: workflow_attention("queued") }
].freeze
```

### Phase 6c — Workflow on the dashboard

Add `Workflow` to the dashboard's subject toggle (Phase 5). Wire:

- `/?subject=workflow&view=list` — table of workflows; uses
  `Workflows::Filter`. Columns: `id`, `job_id`, `trigger_kind`,
  `state`, `started_at`, `finished_at`, action links.
- `/?subject=workflow&view=kanban` — columns by `state`.
  - **Column layout question** (operator review needed): three columns
    (`queued`, `running`, `done` with succeeded/failed/cancelled as
    coloured chips inside the cards), or five flat columns. v1
    recommendation: three columns + status chip on each card. Less
    horizontal scroll; the terminal-state distinction is captured by
    chip colour. Operators can filter by `state` for the precise view.
  - No drag-and-drop. Workflow transitions are driven by the system,
    not the operator.

### Acceptance (Phase 6 as a whole)

- [ ] `Workflows::Filter`, `Filters::Chips::Workflows::*` chip set,
      and `Filters::SUBJECTS[:workflow]` exist and pass the
      chip-DSL contract spec
- [ ] `SmartFolder.for_subject(:workflow)` seeds the 4 builtins on
      first boot
- [ ] Dashboard subject toggle includes `Workflow`; both list and
      kanban views render correctly
- [ ] Workflow kanban columns match the chosen layout (default: 3
      columns)
- [ ] No drag-and-drop on Workflow kanban; cards are read-only with
      click-through to Workflow detail
- [ ] Specs cover each chip class plus integration tests for the 4
      attention presets
- [ ] No regressions on Job / Epic sides

### Out of scope

- A separate `Runs` subject. Runs are children of Workflows; they
  surface within the Workflow detail page. If a runs-level dashboard
  becomes useful later, it slots in as Phase 7 with the same
  mechanical shape.
- Workflow drag-and-drop. State transitions are system-driven.
- Cross-subject hierarchical drill-down on the dashboard (clicking
  an Epic row jumping to its Jobs filtered by `epic_id`). Worth a
  follow-up; not blocking.

## Risks (appendix)

- **Subject-toggle URL collisions with existing bookmarks**: any
  existing link to `/` expecting "Jobs dashboard" now lands on the
  user's persisted choice, which may surprise them on first visit.
  Mitigation: explicit one-time toast / banner ("We unified the
  dashboard — pick your default subject"), backed by a one-shot user
  flag.
- **`latest_workflow_state` derivation cost on the Jobs kanban**: this
  is the Job kanban's column dimension and it requires a per-row
  lookup unless we denormalize. Already used by the existing chip
  (`latest_workflow_state`) so the SQL is solved, but the kanban
  rendering hits it for *all* Jobs in the visible filter — could be
  slow on big lists. Mitigation: scope kanban view to a reasonable
  page size; surface a "showing the first 100; refine filters" hint
  if hit.
- **Workflow volume**: a long-running deployment can accumulate
  thousands of Workflow rows. Default Workflow list filter should
  probably scope to "recent" (last 7 days, say) or "non-terminal" to
  avoid loading 50k rows. Operator can override via chips.
