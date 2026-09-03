# Plugin Model And Component Moves

Syrus plugins are real Rails engines: they own routes, controllers, models,
migrations, jobs, React components, and translations. `design_docs` proves the
full shape end to end (own tables, own migrations, association injection into
core models). The remaining work is not "can a plugin do this" — it is closing
the platform gaps that force large subsystems to stay core, and then moving
them.

This plan supersedes the earlier review-first draft. Completed extractions have
been removed rather than re-planned; what remains is the enabling program, the
current move candidates, and the decisions that constrain both.

## Status

**Phase 0 complete** except G10 (uninstall/purge lifecycle), carried to Phase 2.
Landed: the boundary audit promoted to the required `plugin-boundaries` grader,
`github_source` made disableable (no bundled plugin declares
`disableable: false` any more), runtime plugin health (G11), and spec-harness
auto-discovery (G9).

**Phase 1 complete.** `spending_insights` finished, `throughput` and
`team_directory` extracted, and the `ui_slot` extension point built.

**Phase 2 complete.** Domain events (G1), a working `tick_interval` (G2),
extensible kind registries (G3), the plugin settings read path (G4), the
uninstall/purge lifecycle (G10), the `step_environment` extension point, and
`build_cache` extracted.

**Next: Phase 3** — the search host (G6) and then `test_insights`.

## Principles

These are rules, not preferences. A move that cannot satisfy them is not ready.

1. **Core must not reference a plugin.** Not by constant, not by table, not by
   route name. Plugins depend on core; the reverse is a defect.
2. **Plugins must not add columns to core tables.** A plugin that needs to
   annotate a core record owns a side table keyed by the core record's id, and
   injects the association in `config.to_prepare`.
3. **No circular dependencies between plugins.** The dependency graph is a DAG.
   `Admin::PluginDependencyGraph#cycles` / `#acyclic?` detect violations
   statically (JOB-4127); wiring that into runtime plugin health is G11.
4. **A plugin is its own feature flag.** Plugins do not define feature flags.
   Enabled means the behavior is on. A plugin may *read* a globally defined
   flag, but must not require one to exist.
5. **Plugins are genuinely disableable and deletable by default.** The model is
   Home Assistant integrations: some are more load-bearing than others, but the
   platform assumes removal is legal. `disableable: false` is a last resort and
   must carry a written justification.
6. **Disabling never mutates schema.** Disable stops behavior and hides UI.
   Deleting data is a separate, explicit operation.
7. **A Job's provenance is generic.** Plugins that create Jobs record an
   origin and an id, never a bespoke core column and never a stored URL. See
   Job Origin.
8. **Plugin tables are namespace-prefixed**, enforced by
   `bin/check-plugin-model-namespaces`. STI onto a core-owned table is the only
   exception and stays rare.

### The boundary, and how it is enforced

**JOB-4127 / PR #3120 (in flight, not yet merged)** builds most of this. It adds
`Admin::PluginSourceBoundaryAudit`, a static source-tree audit that checks four
things: manifest dependencies resolve, the dependency graph is acyclic,
core does not reference plugins, and plugin-to-plugin references are covered by
declared transitive dependencies. It also adds `bin/plugin-boundary-audit`, a
manual runner that physically removes a plugin plus its transitive dependents in
a temporary copy, strips the matching Gemfile path entries, and runs a smoke
command — the stronger check, kept out of default CI because it is expensive.

The same PR fixes the violations this plan previously listed, using deferred
string resolution rather than guards:

```ruby
"ClaudeAgent::SessionPaths".safe_constantize   # app/models/provider_session.rb
"InputSources::Github".safe_constantize        # app/models/repository.rb
```

`ClaudeTranscript` resolves both provider `TranscriptEvents` modules the same
way. A reference routed through a string, the registry, or `class_name:` is
absence-tolerant and passes the audit; a bare constant does not.

Two allowlists in the audit are worth reading as a to-do list rather than a
settled state:

- `GUARDED_CORE_CONSTANTS` — `DesignDocs` in `AgentEnvironmentSnapshot` and
  `Prompts::ChatSystem`, `SyrusBrowser` in `Mcp::Sidecar`. These use the
  `defined?(X) && X.enabled?` guard and are the sanctioned soft-reference form.
- `LEGACY_FRONTEND_IMPORT_EXCEPTIONS` — `ConfigureAgentModal.tsx` and
  `credentials/CredentialCard.tsx` still import plugin frontend modules
  directly. Real remaining optionality work, deliberately left visible.

`CORE_PATH_EXCEPTIONS` exempts `app/frontend/routes/App.tsx` — necessarily,
because sidebar pages have no route wildcard. That exemption disappears when G5
lands, and until then the audit cannot see drift in that file.

Remaining after #3120: promote the audit from a spec to a named grader phase,
and drop `github_source`'s `disableable: false` now that the
`InputSources::Github` references are absence-tolerant.

## Already Done

Recorded so it is not re-planned. Not exhaustive, but covers the previous plan's
phases:

- **Provider plugins** — `claude_agent` / `codex_agent` own invocation, OAuth,
  credential probes, usage probes, and transcript event parsing. Core keeps the
  generic `AgentInvocation`, provider availability, and the circuit breaker.
- **Language and framework plugins** — `ruby`, `javascript`, `python`, `go`,
  `syrus_rails`, `django` own parsers, prepare detectors, autofix commands,
  dependency audit commands, review criteria, and artifact renderers.
- **MySQL diagnostics** — `admin_mysql` owns the inspector, status/kill tools,
  and its admin page.
- **Dev observability UI** — `syrus_dev` owns the performance and operational
  log admin pages, their controllers, `SqlExplain`, and the
  `read_performance_diagnostics` / `read_syrus_logs` tools. The *storage* models
  did not move; see below.
- **Browser tooling** — `browser` owns the MCP browser tool set, session
  registry, loopback guard, and the image-diff renderer.
- **Source ingest** — `github_source` and `linear_source` own their input-source
  STI models and clients.
- **Boundary enforcement (in flight, PR #3120)** —
  `Admin::PluginSourceBoundaryAudit`, `PluginDependencyGraph#cycles`,
  `bin/plugin-boundary-audit`, and absence-tolerant resolution of the
  provider and input-source constants. See the boundary section above.
- **Extracted in this program** — `spending_insights` (finished: payload,
  filter subject, chat tool, i18n), `throughput` (new), `team_directory` (new).
- **Standalone pages** — `design_docs` (with its own migrations),
  `worker_timeline`, `mysql_db_browser`, `spending_insights` (page only),
  `preview_tools`, `whiteboard_tools`, `theming_tools`, `git_history`,
  `discord`, `tailscale`.

## What Stays Core

- `Job`, `Epic`, `Workflow`, `Step`, `Run`, and the state machines
- job dependencies, approvals, landing queue, merge train, retry/reconcile,
  checkpoints, admission control
- `Repository`, repository membership, **team authorization**
  (`Team`, `TeamMembership`, `TeamRepository`, `Repository#role_for`,
  `accessible_repository_ids_for`) — authorization is not an integration
- app settings, feature gates, the plugin registry itself
- generic event, log, and **search infrastructure** — including the search
  database, `SearchRecord`, and the indexing queue. Concrete FTS tables may be
  plugin-owned; the host must not be.
- delivery tracks (promotion, hotfix sync, upstream export) — these are part of
  the core workflow model, not an integration
- main branch health and repair — see Deferred

## Platform Gaps

This is the enabling program. Almost every remaining move is blocked on one or
more of these, and several are cheap.

### G1. Domain events — done

`Syrus::Events` + the `domain_subscriber` extension point. Names are declared in
`Syrus::Events::EVENTS`; async delivery goes through `DomainEventJob` on the
subscriber's `home_queue`, inline delivery runs in the publish for subscribers
that need a workspace before teardown. Publishers wired so far: Job
created/closed/approved/state_changed, `step.grader.completed`, and
`step.command.completed`.

Original problem, for the record:

The single most important gap. Today a subsystem that must react to a Job
closing has to live in core, because the only mechanism is an
`after_update_commit` on `Job`. Plugin callbacks are lifecycle-only
(boot/shutdown/enable/disable/tick).

Introduce a `domain_subscriber` extension point with a published event catalog.
Requirements:

- **Core publishes from explicit call sites**, not from scattered Active Record
  callbacks. `Syrus::Events.publish("job.closed", ...)` sits where the
  transition is decided, so the event list is greppable and reviewable.
- **Payloads are plain data** — ids and primitives, never Active Record
  objects. This keeps plugins off core model internals and makes async delivery
  safe.
- **Two delivery modes.** `:async` (default) enqueues onto the subscribing
  plugin's `home_queue`. `:inline` runs synchronously inside the publishing
  call, for subscribers that need resources that will not survive the turn.
- **A subscriber failure must not fail the publisher** in `:async` mode, and
  must be explicitly opt-in to do so in `:inline` mode.

Initial catalog, driven by the moves below:

| Event | Needed by |
|---|---|
| `job.created`, `job.state_changed`, `job.closed`, `job.approved` | scheduled tasks, agent insights |
| `workflow.started`, `workflow.finished` | agent insights, throughput |
| `run.finished` | coverage, throughput |
| `step.grader.completed` (inline; carries run id, grader name, output path, format hint, workspace path) | **test insights**, coverage |
| `repository.created`, `repository.archived`, `repository.destroyed` | scheduled tasks, insights, test insights |

`step.grader.completed` must be `:inline` — the subscriber parses a file inside
the workflow workspace, which is torn down on workflow terminal transition.

### G2. Recurring jobs — done

`PluginTickSchedulerJob` runs every minute and enqueues `PluginTickJob` for
each enabled, healthy plugin whose `tick_interval` has elapsed, on that
plugin's `home_queue`, claiming the tick with a conditional UPDATE on
`plugin_records.last_ticked_at`.

Original problem, for the record:

`tick_interval` is stored on the manifest and read by nothing;
`PluginTickJob` exists but is never enqueued; `home_queue` only affects
`PluginLifecycleJob`. No plugin can run a scheduled job today without editing
the host's `config/recurring.yml`.

`config/syrus_docs/plugins.md` (lines 366 and 406) currently documents both as
working; that documentation is wrong and must be corrected or made true as part
of this gap.

Make `tick_interval` real, and allow a manifest to contribute recurring entries
with an explicit queue and schedule. Ticks must be skipped when the plugin is
disabled, and must not fire on workers that do not consume the target queue.

### G3. Kind and action registries — partly done

`Workflow::TriggerKind` and `Step::Kind` now merge `:workflow_kinds`
contributions through `Syrus::KindRegistry`, keyed on
`PluginRegistry.generation` so enable/disable invalidates exactly. A plugin
cannot shadow a built-in kind.

Still core-only, and deliberately so until a mover needs them: `Job::KINDS`,
closure reasons, `WorkDefinitions`, `Notification` kinds, `AdminAction` actions,
and `PendingActions`. Building those before something uses them would be
speculative. Note that Job Origin removes the main reason `Job::KINDS` looked
like it needed extending.

Original problem, for the record:

`Workflow::TriggerKind::ENTRIES`, `Step::Kind::ENTRIES`, `Job::KINDS`, closure
reasons, `WorkDefinitions::BuiltIns`, `Notification` kinds, `AdminAction`
actions, and `PendingActions` are frozen literals with zero registry awareness.
A plugin that owns a workflow cannot express it.

Make each merge plugin contributions at boot. `Filters.register_subject` and
`SmartFolder.register_subject!` already prove the shape — but note they are
currently called as raw singletons from plugin `register!`, with no
enable/disable gating and no unregistration. Route new registries through
`PluginRegistry` so disable actually takes effect.

Design note: prefer *not* extending `Job::KINDS` where a plugin-owned link table
would do. See the scheduled-tasks entry below.

### G4. Plugin settings — done

`Syrus::PluginSettings` resolves a plugin's settings through its declared
schema: `:secret_env` from `ENV` only, everything else the saved value then the
schema default, and an undeclared key returns nil rather than reading a raw
column. `tailscale` was switched off its private reader.

Original problem, for the record:

`config_schema` renders an admin form and writes `PluginRecord#config["settings"]`
— which nothing ever reads back. Plugins that need configuration currently read
`ENV` directly.

Add a read path (`MyPlugin.setting(:key)`), with `secret_env` values continuing
to resolve from `ENV` and never being returned to clients. This is also the
landing zone for the plugin-shaped columns currently sitting on `app_settings`:
`discord_bot_token`, `telegram_bot_token`, `telegram_bot_handle`,
`telegram_update_offset`, `video_retention_days`, `video_storage_budget_mb`,
and the `github_app_*` block.

### G5. UI surfaces

**Done: in-page slots.** `ui_slot` (`Syrus::Plugin::UiSlot`,
`App::UiSlotsPayload`, `pluginUiSlots.tsx`) lets a plugin contribute a panel to
a named slot on a core page rather than only owning a whole page. Slot names are
declared, not free-form. `repository.detail` is in use by `throughput`;
`job.detail` is declared and awaits `build_cache`.

Still outstanding:

- **Sidebar pages need two host edits** (`config/routes.rb` and
  `App.tsx`). `/admin/*` and `/repositories/:id/plugin/*` already have
  wildcards; sidebar pages need the same on both sides.
- **No slot for in-page contributions.** Throughput needs a repository-detail
  panel; build cache needs a job-detail card; main health needs a dashboard
  banner. Add named, ordered slots rather than one-off props.
- **Artifact renderers are hardcoded** — `pluginArtifactRenderers.tsx` imports
  `@plugins/rails/...` directly. Convert to the same `import.meta.glob` pattern
  the other four plugin frontend surfaces use.

### G6. Search host

Make the search subsystem a plugin host:

- register an FTS table (schema SQL + the `syrus:prepare_search` required-table
  set, today a fixed constant in `lib/tasks/search_database.rake`)
- register a search result type (`SearchController::TYPES` and its dispatch
  hashes are hardcoded)
- filter subjects already work via `Filters.register_subject`

Related defect to fix while here: `test_identity_fts` is written *synchronously*
from `TestRunIngester` on the `runs` (compute) tier, which contradicts the
documented home/compute split in `config/queue.compute.yml`. Route it through
an `indexing` job like every other index.

### G7. Routes beyond the two API namespaces

Plugin routes dispatch only under `api/v1/app/` and `api/v1/admin/`. No engine
mount, no HTML routes, no Action Cable channels. Terminal needs a channel.

### G8. CLI extensibility

The Go CLI is a single binary with no plugin story. Scheduled tasks alone owns
`syrus schedule` with five subcommands. Options:

- **(a) Compile-time** — plugins ship `plugins/<name>/cli/`, aggregated by a
  generated import list. Fastest to build, works only for in-repo plugins.
- **(b) Server-described commands** — the CLI fetches a command manifest from
  the instance and synthesizes subcommands from it. No recompile, works for
  third-party plugins, matches how plugin HTTP routes already work.
- **(c) External binaries** — `syrus-<name>` on `PATH`, the git/kubectl model.

Recommendation: **(b)** as the primary mechanism, **(c)** as the escape hatch
for commands that need local execution. **(a)** is acceptable as an interim step
for in-repo plugins if it unblocks the scheduled-tasks move sooner.

### G9. Test harness

`config/initializers/plugin_registry.rb` calls `reset!` in test, and
`spec/support/bundled_plugins.rb` re-registers a hardcoded 16-plugin list. A new
plugin is invisible in every spec until that host file is edited. Auto-discover
instead.

### G10. Lifecycle and data retention — done

Disable / uninstall / purge are now three distinct operations.
`Syrus::PluginPurge` plus `plugin:data` and `plugin:purge` drop a plugin's
tables, deriving ownership from the namespace rule rather than guessing at
table names, and refusing while the plugin is still registered.

Original problem, for the record:

There is no `plugin:purge` task and no documented uninstall path. Given
Principle 5, define:

- **Disable** — behavior off, UI hidden, jobs skipped, data retained.
- **Uninstall** — gem removed. Tables remain until purged.
- **Purge** — explicit, per-plugin, irreversible; drops the plugin's tables.

Also define the reverse-FK story: plugin tables reference core rows, so plugins
must clean up when the core row goes away. The sanctioned pattern is
association injection with `dependent: :destroy` in `config.to_prepare`
(`DesignDocs::HostAssociations`), with `repository.destroyed` /
`job.destroyed` events as the fallback for anything that cannot be expressed
as an association.

### G11. Dependency resolution and plugin health

JOB-4127 covers the **static** half of this: `PluginDependencyGraph#cycles`
and `#acyclic?` detect cycles, and `PluginSourceBoundaryAudit` reports missing
manifest dependencies, in a spec that runs against the source tree.

What remains is the **runtime** half. `depends_on` is still a name-existence
assertion checked once at boot: `validate_dependencies!` raises,
`config/initializers/plugin_registry.rb` rescues and logs — so a misconfigured
instance boots, but silently — and the declaration gates nothing while running.
Static analysis catches drift in a repository; it cannot catch a deployment
where a dependency is disabled by an operator, a gem is absent from the image,
or a boot callback crashed.

The governing constraint: **a misconfigured plugin must never stop Syrus from
booting.** The operator has to be able to start the instance and fix it from
inside. So dependency problems resolve into a health state, not an exception.

**Declaration strengths**

| Declaration | Meaning |
|---|---|
| `depends_on: ["x"]` | Hard. Cannot be enabled without `x` enabled. If `x` later goes away, this plugin becomes `degraded`. |
| `optionally_depends_on: ["y"]` | Soft. Enhances behavior when `y` is present, must function without it. This is the declaration form of the `defined?(Y) && Y.enabled?` guard pattern. |
| `conflicts_with: ["z"]` | Mutually exclusive. Needed once an extension point expects a single provider — e.g. two `memory_store` implementations. |

**Health states**, computed at boot and recomputed on every enable/disable:

| State | Meaning | Effect |
|---|---|---|
| `ok` | Dependencies satisfied, self-check passed | Normal |
| `degraded` | Enabled, but a hard dependency is missing/disabled, or a self-check failed | **Providers are withheld** — `providers_for` skips it. Data, admin row, and settings survive; routes answer the existing `plugin_disabled` 404. |
| `blocked` | Cannot be enabled from its current state | Enable is refused with the specific missing name |
| `cycle` | Participates in a dependency cycle | Every member is withheld |

Withholding providers rather than raising is the whole trick: a broken plugin
becomes inert instead of fatal, and the rest of the instance is unaffected.

**Boot never fails.** Replace the `raise` with resolution + reporting:

- one structured log line per unhealthy plugin, naming the plugin, the state,
  and the specific unmet dependency or failed check
- a `SystemAlerts` entry, since that mechanism is already admin-visible
- a health badge and reason on `/admin/plugins`
- plugin health in the admin API so a deploy can assert on it

**Cycle detection** is no longer new work — reuse
`PluginDependencyGraph#cycles` at boot, mark every member `cycle`, withhold
their providers, and report. The detector exists; only the runtime consequence
is missing. That is what makes Principle 3 real at runtime as well as in CI.

**Enable/disable semantics**

- Enabling with an unsatisfied hard dependency is refused, and the UI offers to
  enable the dependency chain — the mirror of the cascade-disable confirmation
  that already exists.
- Disabling a plugin with enabled hard dependents **cascade-disables** them
  after confirmation. `degraded` is reserved for states the operator did not
  choose (missing gem, failed self-check, crashed boot callback); an explicit
  operator action should produce an explicit, visible result.

**Self-checks share the same surface.** Let a plugin declare a readiness check
that resolves to the same `degraded` state with a human-readable reason. This is
what the earlier plan was reaching for when it said `build_cache` "should
degrade to a clear not-configured state": `build_cache` needs `SCCACHE_BUCKET`,
`admin_mysql` needs a MySQL adapter, `video_walkthroughs` needs a Gemini key.
One mechanism, one badge, one place to look.

Deferred: version constraints (`depends_on: { "agent_memory" => ">= 2.0" }`).
Manifests already carry `version`, so this is additive whenever it is wanted.

## Job Origin

`Job` currently records where it came from in at least five overlapping ways:
`kind` (`issue`/`cron`/`direct`/`external_pr`/...), `input_source_id`,
`external_ref`, `issue_number`, and `scheduled_task_id`. Every one of those is a
separate special case in core, and each new job source adds another.

These are conceptually one thing: **an origin, plus an identifier within that
origin.**

### The model

Two core-owned, generic columns:

| Column | Meaning |
|---|---|
| `jobs.origin` | The **plugin name** that created the Job, or `"core"` for built-in origins. Not null. |
| `jobs.origin_id` | The identifier of the originating thing, within that origin. Opaque string; core never parses it. |

`origin_id` identifies **the thing that caused the Job**, not the Job and not
the causing event: a GitHub issue number, a Linear issue id, a `ScheduledTask`
id, an `InsightSuggestion` id. Several Jobs may share one `origin_id` — a
recurring schedule fires repeatedly, and that is correct.

**No URL is ever stored.** URLs change when a repository is renamed, a
workspace moves, or an instance is rehosted. The origin plugin computes the URL
on demand from `origin_id` plus the Job's repository.

### The contract

A `job_origin` extension point:

```ruby
module Syrus::Plugin::JobOrigin
  # .origin_key                        => String, must equal the plugin name
  # .label(origin_id:, repository:)    => String   # "#123", "Nightly dependency sweep"
  # .url(origin_id:, repository:)      => String | nil   # computed, never stored
  # .icon                              => String | nil
end
```

Rules:

- `url` may return `nil`. A deploy Job has no external page; a scheduled task
  links to an internal `/scheduled_tasks/:id`. Both are fine.
- Core seeds its own built-in origins through the same registry, so `"core"` is
  not a special case in the rendering path.
- **When the owning plugin is disabled or uninstalled, core degrades to
  rendering `origin` and `origin_id` as plain text.** No dangling reference, no
  crash, no orphaned foreign key — which is exactly what Principle 5 requires
  and what a `scheduled_task_id` column can never give us.

This also retires the hardcoded GitHub URL construction currently sitting in
`IngestionClassifier`, `ChatJobStatusQuery`, `PrStackFooter`, and the job
payloads.

### What it subsumes

This is a better answer than the per-plugin link tables sketched elsewhere in
this plan, because it removes core columns instead of relocating them:

| Today | Becomes |
|---|---|
| `jobs.scheduled_task_id` | `origin: "scheduled_tasks"`, `origin_id: "<task id>"` |
| `jobs.input_source_id` + `jobs.external_ref` | `origin: "github_source" \| "linear_source"`, `origin_id: <dedup key>` |
| `jobs.issue_number` (as an identifier) | `origin_id` |
| `jobs.kind` values `issue`, `cron`, `external_pr` | derived from `origin` |

`InputSource#dedup_key` already produces exactly this value; it becomes the
`origin_id` producer rather than a bespoke `external_ref` writer.

### What it does not subsume

- **`jobs.pr_number` and the mergeability columns are not origin.** They record
  where the work *landed*, which is a source-control concern and belongs to the
  GitHub extraction program. Do not conflate the two.
- **`jobs.system_kind` stays.** `kind` currently conflates *who created this
  Job* with *what internal role it plays*; `main_grader`, `agent_insight`, and
  `deploy` are the latter. Origin takes the first meaning, `system_kind` keeps
  the second, and `kind` shrinks to a derived compatibility attribute.
- **`issue_title` / `issue_body` stay for now**, though they are misnamed —
  they are the prompt input for any origin, not a GitHub concept. Rename to
  `origin_title` / `origin_body` when the churn is affordable.

### Migration shape

`issue_number` has ~73 referencing files in `app/`, so this is staged, not
atomic:

1. Add `origin` / `origin_id` with an index on
   `(repository_id, origin, origin_id, state)`, backfilled from the existing
   columns. Both writable, old columns still authoritative.
2. Move dedup and creation paths onto the new columns; old columns become
   derived and read-only.
3. Move readers over. Convert `Job#cron?`, `Job#issue?` and friends to origin
   predicates.
4. Drop `scheduled_task_id`, `external_ref`, `input_source_id`; keep
   `issue_number` only as long as GitHub-specific code still needs a numeric
   handle.

Steps 1 and 2 are prerequisites for the `scheduled_tasks` move. Step 4 is not.

## Move Candidates

### Tier 1 — movable now, no new platform

**`throughput`** — `RepositoryThroughputMetricContract` (866 lines), one
controller action, one route, one React panel, no tables, no i18n. Only inbound
reference is the panel mount in `RepositoryDetail.tsx`. Needs G5's
repository-detail slot, or ships as a repo page tab (wildcard already works) in
the interim. The cleanest extraction available.

**`build_cache`** — **done.** Owns the S3 client, stats capture/summary, the
`build_cache_clear_requests` table (renamed from `admin_build_cache_clear_requests`,
migration shipped in the plugin), the admin page, and the Job-detail card.
Reaches step subprocesses through `:step_environment` and captures through the
inline `step.command.completed` event. Its first cut left core computing the
card's payload, which the boundary grader rejected — so `ui_slot` panels can now
carry their own props.

Original assessment, for the record: the
inventory was right — one table (`admin_build_cache_clear_requests` →
`build_cache_clear_requests`), four services, two controllers, an admin page
(wildcard already works), a job-detail card — but "no new platform" was wrong.

Two core hooks are missing. `Steps::Prepare::PREP_ENV_FORWARD` folds in
`SCCACHE_ENV_FORWARD`, so the plugin needs to contribute environment variables
to prepare/grader/deploy subprocesses. And `Steps::Base#capture_sccache_stats!`
runs after every shell command in three steps, which is a domain event
(`step.command.completed`) rather than anything build-cache-specific. Building a
bespoke callback now would duplicate what G1 provides, so this waits for
Phase 2. The `job.detail` slot it needs already exists.

Scope note: this is *only* an S3 compiler cache. There is no cache warming and
no shared dependency cache — `WorkspaceDependencyEnv` is per-workspace
isolation, and the shared-bare-clone plan in `WorkflowWorkspace` is still
aspirational. Do not let the plugin name imply more than exists.

**`spending_insights` (finish)** — today the plugin contains a sidebar page and
one nav string. `App::SpendingPayload`, `App::SpendingFilter`, six filter chips,
the controller, the `get_spending` MCP tool, ~45 `common.json` strings, and an
index migration are all still core. Pure code motion, no schema change. Worth
doing early as proof the template survives a real backend.

**`team_directory`** — the `/profiles` page only. It lists `User` rows and has
zero dependency on the `Team` model. Team authorization stays core (Principle:
it backs `Job.accessible_to` / `Epic.accessible_to`). Note the codebase uses
"team" for three unrelated things; the extraction should not blur them further.

### Tier 2 — movable after the platform work

**`test_insights`** — with G1's inline `step.grader.completed` event, all five
tables move: `test_runs`, `test_cases`, `test_identities`,
`test_identity_runtime_summaries`, and the `test_identity_fts` index. This
reverses the previous plan's position, which kept them core.

Required first: G1 (inline grader event), G6 (FTS table + search result type
registration), G5 (repository tab already works; job-detail tab needs a slot).

Remaining inbound couplings to sever, none behind an extension point today:
`MainBranchFailureClassifier` (a *semantic* dependency — it diffs test
identities to decide inherited vs. introduced failures),
`App::JobDetailPayload#has_test_results?`, `RepositoriesController`'s
`app_flaky_tests_path`, the `test_case` filter subject, and
`SearchController`'s hardcoded types. The five MCP tools are wired into four
separate hardcoded lists and must move to a plugin-provided tool set.

Because main branch health stays core and consumes test identities, core would
depend on the plugin. Resolve by having the classifier degrade when the plugin
is absent (it already has a `classify_binary_contextual` fallback path) and
consume the data through a registered provider interface rather than the model.

Language plugins keep contributing parsers via `test_result_parser`; the
`test_insights` plugin owns storage, query, UI, and tools.

**`agent_memory`** — `ChatMemory`, `ChatMemoryAuditEvent`, nine MCP tools, the
`/memories` page, the filter subject, and `Prompts::MemoryContext`.

Frame this as **swappable, not merely optional**: define a `memory_store`
extension point (read/write/delete/search/list plus prompt-context rendering),
make the current implementation the default provider, and have core prompts call
through a resolver that returns empty when no provider is enabled. That turns
"you can turn memory off" into "you can replace memory," which is the more
useful property.

Constraints: seven core prompts inject memory context; the chat side has a
second, separate injection path in `Prompts::ChatSystem`; the five workflow
tools live in the explicitly non-disableable `CoreToolSet`. `InsightSuggestion`
references `ChatMemory` — see the DAG note below.

Dead surface to drop rather than port: `embedding`, `visibility`, `expires_at`,
and `last_verified_at` are written by nothing.

**`github_issues` (into `github_source`)** — the repository issues tab, its five
routes and controller actions, `RepositoryIssues.tsx`, the issue i18n block, and
`list_open_issues` / `delegate_issue`. The repo-tab wildcard already works.

This is explicitly *not* "extract GitHub." `github_source` is ~350 LOC against
`GithubClient` alone at 1,221 lines, ~90 core files referencing it, twelve
pollers, `Installation`, and GitHub columns on `jobs`, `repositories`, `users`,
and `app_settings`. Moving the issues UI is a week. Moving GitHub is a separate
program that starts by fixing the `InputSources::Github` boundary violation and
by introducing generic source artifacts.

Also note `SourceControl::Providers` is a dead extension point — referenced only
by its own spec. Either wire it or delete it.

**`terminal`** — `TerminalSession`, `TerminalRelay`, `TerminalChannel`,
`TerminalSessionJob`. Self-contained and already gated. Blocked only on G7
(Action Cable channel registration). Per Principle 4, the existing `terminal`
feature flag is replaced by the plugin's own enabled state.

**`coverage`** — `coverage_snapshots`, the hit-map TTL prune job, the coverage
PR comment steps, and the `get_coverage_report` tool. The `coverage_analyzer`
extension point already exists and stays; the plugin takes storage and UI.
Needs G1 (`run.finished` or the grader event) and G2 (prune job).

**`video_walkthroughs`** — `ChatVideoWalkthrough`, the Gemini client and
transcoder, `VideoWalkthroughAnalysisJob`, `VideoWalkthroughPruneJob`, three
chat MCP tools, four prompts, the `videos` queue, and the composer/media-panel
UI. Strongest unlisted candidate: it is the only thing dragging a non-Anthropic
model vendor into core, it already degrades cleanly when off, and it owns a
retention job. Needs G2 (prune + analysis scheduling) and G4 (retention and
storage-budget settings currently on `app_settings`).

**`scheduled_tasks`** — `ScheduledTask`, `CronTemplate`, `PollScheduledTasksJob`,
`ScheduledTaskFire`, the pileup policies, the `Schedules::*` parsing layer,
twelve MCP tools, four pending actions, two controllers, five React routes, and
the `syrus schedule` CLI family.

Needs G1, G2, G3, G4, G8, and Principle 2's schema inversion. The three core
columns it owns today:

| Today | Becomes |
|---|---|
| `jobs.scheduled_task_id` | `origin: "scheduled_tasks"`, `origin_id: "<task id>"` |
| `jobs.kind = "cron"` | derived from `origin` |
| `users.scheduling_paused` | plugin-owned `scheduled_tasks_user_settings(user_id, paused)` |

The Job Origin work does the heavy lifting here: scheduled tasks need no column
on `jobs` and no `Job::KINDS` value, only the two generic origin columns. That
also removes the `Job#cron?` branches in `Steps::Base`, `Steps::PrOpen`,
`BotIdentity`, `WorkflowWorkspace`, and `AutoApprovalRule` — `Job#synthetic_issue`
already handles the non-issue case.

What remains genuinely coupled: `Job#record_outcome_to_scheduled_task!` inside
the AASM callback (→ `job.closed` subscriber), the `replaced_by_scheduled_task`
closure reason (→ G3), and `AutoApprovalRule`'s candidate chain (needs an
auto-approval-source contribution point).

**`agent_insights`** — `InsightSuggestion`, `InsightScheduleConfig`,
`InsightSuggestionAuditEvent`, `InsightSweepJob`, `Workflows::AgentInsight`,
two step handlers, eight MCP tools, two controllers, two React routes.

Needs G1, G2, G3, G4. Per Principle 4 the `agent_insights` feature flag and
`Feature.agent_insights_enabled?` are removed — the plugin is the flag.

The specific thing the user called out: `Job#after_update_commit
:trigger_insight_if_max_threshold_reached` must become a `job.closed`
subscriber. No plugin should monkey-patch an Active Record callback onto `Job`;
association injection is sanctioned, behavioral injection is not.

Dependency note: this plugin writes `ChatMemory` (`source_type: "insight"`) and
`InsightSuggestion` has an FK to it. Once memory is a plugin, `agent_insights`
declares a hard `depends_on: ["agent_memory"]`, with G11's semantics: if memory
is disabled, `agent_insights` goes `degraded` and its providers are withheld —
it does not crash, and it does not silently half-work.

### Tier 3 — needs design first

**`visual_review`** — the step, prompt, artifacts, and review-loop membership
would move to `browser`. The hard part is not the code, it is that a plugin must
insert a *conditional step into core workflow chains*. `Workflows::Base` builds
those chains; today the visual review loop is materialized by core based on
`.syrus.yml` and a feature flag.

This needs a workflow-composition extension point: plugins declare optional
loops or steps that named chains will admit, with core owning ordering and the
retry semantics. That is a real design problem and should not be smuggled in as
part of a code move. Until it exists, visual review stays core.

### Deferred

**`main_branch_health`** — skipped for now by decision, and the analysis
supports it. It is not a feature, it is a *gate*: `StepDispatcher.main_health_blocking?`
blocks every workflow start, `LandingQueueProcessor` pauses landing on it,
`WorkEngine::Reconciler` references it 26 times, and `SystemAlerts`,
`PollPullRequestJob`, and `RunJob`'s concurrency exemption all branch on it. It
also added eleven columns to `repositories` and two to `app_settings`, all of
which Principle 2 would require inverting.

Revisit only behind generic `work_gate`, `system_alert`, and repair-classifier
extension points — i.e. after core can express "something can veto a workflow
start" without knowing what that something is.

**`delivery_tracks`** — promotion, hotfix sync, and upstream export are part of
the core workflow model. Not a move candidate.

### Still outstanding from the previous plan

**`syrus_dev` storage** — the admin pages, controllers, and tools moved; the
models did not. `OperationalLogEvent`, `OperationalLogIndex`, and
`BrowserErrorEvent` are still core, along with their indexing and prune jobs.
Moving them needs G2 (prune jobs) and G6 (two of the seven FTS tables are
theirs).

Open question carried forward: are browser and backend exception events core
product diagnostics or dev observability? If core pages surface them, they stay
core and only the *dev* views move.

## Schema Inversion Backlog

Principle 2 applied to what exists today. Each entry is a data migration, not
just a code move, and each should land with its plugin.

| Core table | Columns | Owner |
|---|---|---|
| `jobs` | `scheduled_task_id` | scheduled_tasks — resolved by Job Origin, not a side table |
| `users` | `scheduling_paused` | scheduled_tasks |
| `app_settings` | `video_retention_days`, `video_storage_budget_mb` | video_walkthroughs |
| `app_settings` | `discord_bot_token` | discord |
| `app_settings` | `telegram_bot_token`, `telegram_bot_handle`, `telegram_update_offset` | telegram — still a core `PlatformDelivery` adapter; should follow `discord` into a plugin |
| `app_settings` | `github_app_*` (8 columns) | github_source, eventually |
| `repositories` | 11 `main_branch_*` / health columns | deferred with main health |

New plugins must not add to this list.

## Plugin Dependency Graph

The moves above form a DAG with no cycles:

```
core
 ├── agent_memory ◄── agent_insights
 ├── test_insights
 ├── build_cache
 ├── throughput          (extracted)
 ├── team_directory      (extracted)
 ├── spending_insights   (completed)
 ├── coverage
 ├── video_walkthroughs
 ├── terminal
 ├── scheduled_tasks
 └── github_source ◄── github_issues (same gem)
```

Two edges need enforcement work. `agent_insights → agent_memory` needs G11's
hard-dependency semantics. And `test_insights` is consumed by core's
`MainBranchFailureClassifier` — core must degrade around it rather than depend
on it, since G11's health states govern plugins, not core.

## Migration And Deploy

Plugin migrations live in `plugins/<name>/db/migrate` and are globbed onto
`config.paths["db/migrate"]` by `config/application.rb`. They run under normal
`bin/rails db:migrate` against the primary database, and land in the single
unified `db/schema.rb`.

Consequences worth stating:

- Only plugins physically under `<Rails.root>/plugins/` can ship migrations.
  `db/` is not in any gemspec's `spec.files`, so a plugin installed from
  RubyGems cannot contribute schema. Acceptable while all plugins are in-repo;
  a blocker for third-party plugins, and the reason G10's uninstall story
  matters.
- Plugin migrations inherit every core migration rule: generator-issued
  timestamps, idempotent guards, no JSON column defaults, valid from an empty
  database. `bin/check-migration-collisions` already covers plugin paths.
- Production must never generate migrations at runtime.

## Implementation Order

### Phase 0 — Boundary and conventions
- Land PR #3120, then promote `PluginSourceBoundaryAudit` from a spec to a
  named grader phase so drift fails a normal grade loop.
- Drop `github_source`'s `disableable: false`.
- Dependency resolution and plugin health (G11) — the runtime half. Cheap,
  independent of every move, and it is what makes a half-migrated instance
  debuggable instead of dead.
- Document the model/migration/settings conventions and the uninstall/purge
  lifecycle (G10).
- Auto-discover plugins in the test harness (G9).

### Phase 1 — Cheap proof (done)
- Finished `spending_insights`; extracted `throughput` and `team_directory`;
  built the `ui_slot` extension point.
- `build_cache` deferred to Phase 2: it needs a step-environment hook and a
  post-command domain event, which G1 provides.
- What it validated: the template holds for a real backend, and two hazards
  showed up only by doing it — a plugin controller namespace can shadow a core
  top-level module, and the `Current.user` scope audit did not cover plugin
  controllers, so a move would silently drop a documented scope.

### Phase 2 — Core platform
- Domain events (G1), recurring jobs (G2), kind registries (G3), plugin
  settings read path (G4), uninstall/purge lifecycle (G10).
- Then `build_cache`, which is waiting on G1 plus a step-environment hook.
- Job Origin steps 1-2: add and backfill `origin` / `origin_id`, move creation
  and dedup paths onto them, register the `job_origin` extension point, and
  retire the hardcoded GitHub URL construction in `IngestionClassifier`,
  `ChatJobStatusQuery`, and `PrStackFooter`.
- These unblock everything in Tier 2.

### Phase 3 — Search host and storage
- Search registration (G6); fix the compute-tier FTS write.
- `test_insights` and `syrus_dev` storage.

### Phase 4 — Agent-facing plugins
- `agent_memory` as a swappable provider, then `coverage`,
  `video_walkthroughs`, `github_issues`.
- `terminal` once G7 lands.

### Phase 5 — Scheduling and insights
- CLI extensibility (G8), then `scheduled_tasks`, then `agent_insights`.
- Job Origin step 3: move readers onto origin predicates and drop
  `scheduled_task_id`, `external_ref`, and `input_source_id`.

### Phase 6 — Design work
- Workflow composition extension point; only then `visual_review`.
- Revisit `main_branch_health` and the wider GitHub extraction.

## Open Questions

- Which CLI mechanism (G8 a/b/c)? This gates `scheduled_tasks`.
- Do operational and browser-error logs stay core as product diagnostics, or
  move to `syrus_dev` as developer observability?
- Does `MainBranchFailureClassifier` consume test data through a registered
  provider, or does main health accept reduced classification when
  `test_insights` is absent?
- Is `SourceControl::Providers` worth wiring, or should it be deleted?
- Should `issue_title` / `issue_body` be renamed to `origin_title` /
  `origin_body` as part of the origin migration, or left until the GitHub
  extraction forces the issue?
- Does `origin_id` need a uniqueness constraint per `(repository, origin)` for
  open Jobs, or is dedup left to each origin plugin as it is today?

## Non-Goals

- Moving core workflow state into plugins.
- Making runtime enable/disable mutate schema.
- Creating plugins that cannot actually be disabled.
- Renaming large existing tables without a compatibility and staging plan.
- Plugin-defined feature flags. The plugin is the flag.
- Plugin-owned columns on core tables.
- Storing origin URLs. They are computed from `origin_id`, always.
- Failing boot on plugin misconfiguration.
