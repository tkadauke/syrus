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

**Phase 3 complete.** The search host (G6), the compute-tier indexing fix, and
`test_insights` extracted with its tables. `syrus_dev` storage was carried
forward and has since been resolved as core -- see below.

**Phase 4 in progress.** `github_issues` extracted. Two of the five turned out
to be blocked, both for reasons the inventory missed:

- **`agent_memory`** could not move before `agent_insights` — now unblocked
  and extracted, see its entry.
- **`coverage`** inserts conditional steps into core workflow chains
  (`Workflows::Base.coverage_analyze_for`, `Initial`, the feedback chains),
  which is exactly the Tier 3 blocker `visual_review` has. Moved to Tier 3; it
  needs the workflow-composition extension point, not more plumbing.

Remaining and unblocked: `video_walkthroughs`, and `terminal` once G7 lands.

**The registry model itself is changing (G13).** Registration becomes an
*effect* — a plugin installs its contributions and hands back the teardown,
disposed in reverse when it is disabled or unloaded — replacing 47
`providers_for` call sites that re-derive the active set on every call, and the
hand-invalidated caches behind them that produced most of this session's bugs.
Extension points become owned rather than centrally enumerated, so a plugin can
host a point other plugins contribute to (`global_search:source`), which is what
"search should be a plugin" requires. This lands before further extractions,
because it changes how every plugin registers. Principles 8 and 9, G13.

**Phase 6 designed, not started.** Workflow composition is written up as G12:
four anchors (`judge`, `post_implementation`, `post_pr`, plus the existing
fixed tail), with the `judge` contract carrying the weight because a judge is
half a loop rather than a step. It unblocks `visual_review`, `coverage`, and a
new candidate the design surfaced — `review_plan` as the first `post_pr`
plugin. Graders and `format`/`generate` deliberately stay core; G12 says why.

**Remaining candidates re-checked against the source, not the notes.** Two
entries were wrong: `video_walkthroughs` was recorded as blocked on a
`chat_messages.video_walkthrough_id` column that does not exist, and
`syrus_dev` storage was listed as needing G2/G6, both of which have since
landed -- and it then turned out not to be a move at all. See the Ordering note under Implementation Order for the queue by
readiness.

**Phase 5 in progress.** `agent_insights` and `agent_memory` extracted
(insights first, which is what unblocked memory). `agent_insights` went out of
order: the plan put
`scheduled_tasks` first, but that one is gated on the G8 CLI decision and
insights is not, and moving insights is what unblocks `agent_memory` back in
Phase 4. Three platform gaps had to be closed to finish it, none of which the
inventory predicted:

- **Job kinds were a frozen array on `Job`.** A plugin that runs its own kind
  of work could not create a Job at all. `Job::KINDS` /
  `INFRASTRUCTURE_KINDS` / `USER_FACING_KINDS` are now a `Syrus::KindRegistry`
  (`Job::Kind`) fed by a `job_kinds` method on the same `:workflow_kinds`
  provider, with `infrastructure` and `issueless` flags. The six per-kind
  `issue_number_blank_for_*` validations collapsed into one registry-driven
  check.
- **WorkDefinitions were core-only.** `WorkDefinitions::AgentInsight` lived in
  `built_ins.rb`, so `RegistryValidator` failed the moment the trigger kind
  moved. Definitions now carry `self.plugin`, and the same provider names them
  through `work_definitions` — which both autoloads them and drops them when
  the plugin is disabled, so a definition can never outlive its trigger kind.
- **`McpToolContext` named a plugin step kind** to resolve the insight agent
  role. `Step::Kind::Entry` gained `agent_role`, so a plugin declares the role
  on its own step and core's `case` keeps only core's steps.

Two smaller inversions came out of it: `Steps::AutoClose` now closes with
`job.kind` instead of the literal `"agent_insight"` (matching what
`Job#mark_infrastructure_job_closed` already did), and
`Mcp::Tools::ListRecentWorkflowsTool` moved into the plugin — it filtered on
`kind: "agent_insight"` and defaulted its cutoff to the previous insight Job,
so it was never a core tool.

What did *not* move, and stays as documented residue: `AgentRole::AGENT_INSIGHT`
and `McpToolPolicy#insight_tools`. Those name a *role* an agentic step can run
as, not a plugin — core grants live-state, worker-health, and memory tools for
it, and any plugin can attach a step to that role. Splitting roles out is its
own extension point and is not worth doing for one consumer.

**Boundary stress test (after Phase 5).** `bin/plugin-boundary-audit` was
documented but effectively unused. Running it across all 29 bundled plugins
split the result cleanly:

- **Runtime boundaries hold.** Every plugin boots and eager-loads with itself
  and its transitive dependents physically deleted from a `git archive` copy.
  The dependency graph resolves correctly (selecting `agent_memory` also
  removes `agent_insights`).
- **The suite did not.** Running the actual suite in the copy failed for every
  plugin, because core specs enumerate the bundled set — so "deletable" meant
  "deletable with a red suite." Now fixed and re-verified: **all 26 optional
  plugins remove with 0 failures.** The fixes fell into four kinds — core specs
  subtracting plugin contributions instead of pinning the bundled list;
  examples that drive core logic through a plugin's provider moved into that
  plugin; the 24 language-plugin specs moved out of core's `spec/plugins/` into
  `plugins/<name>/spec/`; and a `:requires_plugin` tag for the handful of core
  specs that legitimately need a plugin as a *fixture* (core ships the
  InputSource model but no source type, the purge lifecycle needs a plugin that
  owns a table, the cascade needs a real dependent pair).
- **One real defect.** `AgentEnvironmentSnapshot::CHAT_TOOL_GROUPS` hardcodes
  plugin tool names and rendered them unconditionally, so with a plugin
  uninstalled a chat agent was told it had tools it could not call. The groups
  are filtered to what the session actually advertises now.

- **`github_source` is nominally disableable but not deletable.** It boots
  with the plugin gone, and the boundary grader is clean, but 6,123 of 12,121
  examples fail. First cause: `Repository` declares
  `has_one :github_input_source, class_name: "InputSources::Github"` — a
  *string* class name, which is exactly why the constant-based grader never saw
  it. Reading the association raises `NameError`, and `trigger_label` /
  `polling_enabled` read it on paths every factory touches. (The *writer*,
  `create_github_input_source`, already guards with `safe_constantize`; the
  reader does not.) Not fixed here: one guard would leave thousands of failures
  and manufacture the appearance of progress. This belongs with the wider
  GitHub extraction in Phase 6, and it now has a concrete starting point.

- **`claude_agent` cannot be disabled at runtime, let alone deleted — and the
  admin UI offers it.** `users.agent_provider` (and `runs`, `workflows`,
  `repositories`) carry a database default of `"claude"`, while the model
  validates `inclusion: { in: -> { User.agent_providers } }` against the
  registry. Turn the plugin off and every existing user with
  `agent_provider: "claude"` becomes unsaveable, and every new user invalid:

  ```
  providers with claude_agent disabled: ["codex"]
  new user default "claude" -> valid? false
  existing user provider="claude" -> ["Agent provider is not included in the list",
                                      "Chat provider is not included in the list"]
  ```

  This is an operator-reachable footgun, not only a test-suite artifact. Fixing
  it needs a decision rather than a patch: a dynamic column default, a
  validation that tolerates a persisted-but-disabled provider, or refusing to
  disable a provider rows still reference. Open question below.

- **Agent-provider plugins are load-bearing for the suite too.** Removing
  `codex_agent` fails ~260 examples across ~20 core spec files that hardcode
  `agent_provider: "codex"` as *a second provider* to exercise multi-provider
  behavior — budget scoping, the circuit breaker, provider availability
  (`provider_availability_spec` alone names it 103 times). Deliberately not
  mass-edited: whether those examples should skip via `requires_plugin` or
  discover a second provider from the registry follows from the open question
  above, and a 20-file speculative rewrite ahead of that decision is churn.

Final tally, every bundled plugin removed at HEAD:

| result | plugins |
|---|---|
| 0 failures | admin_mysql, agent_insights, agent_memory, browser, build_cache, design_docs, discord, django, git_history, go, javascript, linear_source, mysql_db_browser, preview_tools, python, ruby, spending_insights, syrus-rails, syrus_dev, tailscale, team_directory, test_insights, theming_tools, throughput, whiteboard_tools, worker_timeline |
| structural | claude_agent (7,770), github_source (6,123), codex_agent (258) |

`reconciler_chaos_spec` fails intermittently on a random seed and
`admin/stuck_spec` on a workspace-directory leak between examples; both are
pre-existing, unrelated to plugins, and appear in perhaps one run in ten.

The lesson for the remaining moves: the boundary grader catches constant and
path references, but it cannot see a string `class_name` or a database column
default, and neither it nor the normal suite catches a *spec* that assumes a
plugin is installed. The physical-removal audit is the only check that does,
so run it for each new extraction.

## Principles

These are rules, not preferences. A move that cannot satisfy them is not ready.

1. **Core must not reference a plugin.** Not by constant, not by table, not by
   route name. Plugins depend on core; the reverse is a defect.
2. **Plugins must not modify core models.** No injected associations, no
   reopened classes. A plugin reaches its own rows through its own scopes, and
   says "these go when that core record does" through `Syrus::DataCleanup`.
   Note the direction: a plugin can always join *upward* (its table
   `belongs_to` a core one), never downward.
3. **Plugins must not add columns to core tables.** A plugin that needs to
   annotate a core record owns a side table keyed by the core record's id, and
   injects the association in `config.to_prepare`.
4. **No circular dependencies between plugins.** The dependency graph is a DAG.
   `Admin::PluginDependencyGraph#cycles` / `#acyclic?` detect violations
   statically (JOB-4127); wiring that into runtime plugin health is G11.
5. **A plugin is its own feature flag.** Plugins do not define feature flags.
   Enabled means the behavior is on. A plugin may *read* a globally defined
   flag, but must not require one to exist.
6. **Plugins are genuinely disableable and deletable by default.** The model is
   Home Assistant integrations: some are more load-bearing than others, but the
   platform assumes removal is legal. `disableable: false` is a last resort and
   must carry a written justification.
7. **Disabling never mutates schema.** Disable stops behavior and hides UI.
   Deleting data is a separate, explicit operation.
8. **A Job's provenance is generic.** Plugins that create Jobs record an
   origin and an id, never a bespoke core column and never a stored URL. See
   Job Origin.
9. **A plugin installs its contributions and can take them back.** Registration
   is an *effect*: the plugin performs an install and hands back the teardown,
   and disabling or unloading runs those teardowns in reverse. Core does not
   poll the registry from every use site to discover what is currently active;
   the active set *is* what is installed. See G13.
10. **Extension points are owned, not centrally enumerated.** Any plugin may
   host a point for other plugins to contribute to, declared in its manifest
   and named for its owner (`global_search:source`). Core's own points are simply
   the ones the kernel hosts. See G13.
11. **Plugin tables are namespace-prefixed**, enforced by
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

### G14. One plugin interface — done

A plugin was four files: a gemspec, `lib/<name>/version.rb`, an
`lib/<name>/engine.rb`, and the manifest. Three of those carried no
information -- all thirty versions said `0.1.0`, and the gemspecs had drifted
into three variants of `spec.files`, two of `require_paths`, and
`rails` vs `railties`. `enabled?` was copy-pasted into fourteen plugins in two
different spellings, and each engine chose its own registration hook.

`Syrus::PluginApi` replaces all of it: one declaration per plugin, and the
framework owns timing. See `config/syrus_docs/plugins.md` for the shape. The
parts that matter beyond tidiness:

- **Registration moved to `to_prepare`.** `lib/` is autoloaded, so
  `Syrus::PluginRegistry` was itself replaced on every reload while every
  plugin registered once per boot -- measured at 30 plugins before a reload
  and 0 after. The first file save under `bin/dev` silently unloaded every
  plugin.
- **`while_enabled` vs `always`** replaces "did you remember `plugin:` on the
  `Syrus::Installer.define` label?" with two verbs that say what they mean.
- **Interface modules are derived** from the extension point rather than
  hand-included at boot by fourteen engines -- includes that were lost on the
  next reload anyway.
- **Contributions are named as strings**, so they cannot pin a stale class.

Two latent bugs fell out of it: two plugins defined `ChatToolSet` inside
`mcp_tool_set.rb`, which raises `superclass mismatch` the first time a reload
re-opens it, and `bin/plugin-boundary-audit` read `optionally_depends_on` as
`depends_on`, so it had never once exercised the optional-dependency path it
exists to protect.

### G6. Search host — done, then federated

`:search_source` let a plugin register FTS tables (created by
`syrus:prepare_search` alongside the built-ins, with an optional
drift-rebuild hook) and a global-search result type. `test_insights` owns
`test_identity_fts` and the `test_case` type through it. The compute-tier
indexing defect below is fixed: identities index through
`IndexTestIdentitiesJob` on `indexing`.

G13 then finished the job: search itself is the `global_search` plugin, which
*hosts* `global_search:source` instead of core pre-declaring `:search_source`.
Core keeps only the search-database infrastructure (`SearchRecord`, the
`indexing` queue, `syrus:prepare_search`) and `ChatMessageSearchIndex`, which
core chat features query directly. The plugin owns the Job and Epic indexes,
their index jobs, `SearchController`, the `/search` UI, and the API client.
`test_insights` contributes through `optionally_depends_on: ["global_search"]`,
so removing `global_search` leaves it installed and merely without a search
type -- verified by `bin/plugin-boundary-audit global_search`.

Original problem, for the record:

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
"plugins are genuinely disableable and deletable by default", define:

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
is missing. That is what makes the "no circular dependencies" principle real at runtime as well as in CI.

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

### G12. Workflow composition — designed, not built

Tier 3's shared blocker: a plugin cannot insert a step into a core workflow
chain. `Workflows::Base.steps_for(job)` builds them, and every optional piece
(`adversarial_review_loop`, `visual_review_loop`, `coverage_analyze_for`) is
materialized by core reading `.syrus.yml`.

The mechanics are cheaper than they look. `steps_for` already returns a flat
array whose elements are either a step-kind string or a `Workflows::Loop` /
`Workflows::RetryUntil` value object, and `to_chain_template` serializes all of
them down to plain step-kind strings. A plugin-contributed node round-trips
through the persisted `chain_template` with no new persistence work, and the
step kind plus handler already come from `:workflow_kinds` (G3). What is
missing is only the *positions*.

**Four anchors**, of which two are ordinary step insertion. Under G13 these are
points the *workflow host* declares (`workflow:judge`,
`workflow:post_implementation`, `workflow:post_pr`) rather than three more
names in core's frozen enum — which is the more honest home for them, since
core never wanted to know about judges:

```
prepare
implement                                   core, always
  <judge>            adversarial_review, visual_review ...   loop cluster
  <grade loop>       core
  <post_implementation>  coverage, dependency_audit ...      once, after loops
summarize -> test_plan -> pr_open           core, fixed
  <post_pr>          review_plan ...                         once, after PR
```

`post_implementation` and `post_pr` take a list of step kinds with an `order`
and an `enabled_for?(job)` predicate, so the plugin reads its own `.syrus.yml`
block — which also moves `RepoCoveragePlanReader` and `RepoVisualReviewPlan`
out of core.

**`judge` is the anchor with real content**, because a judge is not a step but
half of a loop:

```ruby
def self.judges
  [ {
      step_kind: "visual_review",              # registered via workflow_kinds
      order: 20,
      trigger_kinds: %w[initial retry pr_comment chat_feedback],
      rounds_for: ->(job) { VisualReview::RepoPlan.for_job(job).rounds }
    } ]
end
```

Core pairs the judge with whatever agent step that chain uses (`implement` or
`respond`), builds the `Workflows::Loop`, and decides `review_first` itself.
That flag is a property of *position*, not of the plugin — true only for the
first judge in a chain that already ran a top-level agent step — so keeping it
in core stops a plugin from producing a redundant re-implement.

**Two things this deliberately does not move.**

`format`/`generate` are not post-loop steps, despite reading like siblings of
coverage and dependency audit. They run *inside* the grade loop on every
iteration, so a style-only failure or stale codegen never costs an agent turn.
Relocating them after the loop would make a formatting-only failure burn a
grade iteration. If a formatter should ever be plugin-contributed, the anchor
is `grade_loop_autofix`, not `post_implementation`.

Graders are a different shape from judges. A judge is `Loop(agent, judge)` with
a verdict; graders are the *check* phase of a `RetryUntil` whose repair is the
agent step, they own `grade_max_iterations`, and they fan out into per-grader
children at runtime. Expressing that as a plugin grows the contract from "I am
a judge" to "I am the check phase of the repair loop, and I materialize N
children" — a large contract for a single consumer. Graders stay core until a
second grader implementation exists to justify it.

**Risk to settle first.** `chain_template` is persisted, so an in-flight
workflow keeps its shape when a plugin is disabled mid-run — but the handler is
gone and `Step::Kind` lookup fails on the next dispatch. This is the
`disableable` question from the stress-test findings with a running workflow
attached. G13 supplies the mechanism (disable disposes what was installed); the
policy on top of it is still a choice — refuse the disable while the plugin
owns step kinds in a non-terminal workflow is the safest.

Build order: the anchors plus `judge`, with `visual_review` as the proof, then
`coverage` on `post_implementation` and `review_plan` on `post_pr`.
`adversarial_review` as a second judge is what shows the anchor is not shaped
around one caller.

### G13. Installation effects and federated extension points — done

The registry is a *pull* model today: 47 `providers_for(...)` call sites in
core, each re-asking "which plugins are active and what do they contribute?"
on every call. Nothing is ever installed, so nothing ever has to be removed —
which sounds simple until you count what it costs.

**What it actually costs.** Every derived view of plugin state has to be
cached and invalidated by hand, and each such cache has been a bug:
`Workflows::REGISTRY` froze the enabled set at autoload; `Job::KINDS` and
`Workflow::TRIGGER_KINDS` did the same; `Syrus::KindRegistry` needs a
generation counter to stay honest. Meanwhile six registrations are *already*
push-style — `Filters.register_subject`, `SmartFolder.register_subject!`,
`HostAssociations.apply!` — with no teardown at all, which is why
`HostAssociations` needs a `reflect_on_association` guard to survive reload and
why a disabled plugin's filter subject stays registered. We converged on
push-registration independently; we just never recorded the cleanup.

**The model.** Prior art: Cordis (the kernel under DeepSeek Harness). Its
`effect(execute) -> Disposable` runs an install whose return value is the
disposer; disposers collect on the owning fiber and run **in reverse order** on
teardown; effects nest, so a child's disposer registers on its parent and
unloading a plugin disposes its whole subtree. It also refuses to create an
effect on an inactive context.

**What does not transfer.** Cordis is one long-lived Node process with a live
object graph. Syrus is multi-process — web pods, worker pods, MCP sidecar
subprocesses, `bin/rails runner` — plus Zeitwerk reloading in development. An
effect installed in one process cannot be disposed by an admin click served by
another. So ours is not a one-shot mount: each process installs from current
plugin state and re-applies (disposing first, in reverse) when
`PluginRegistry.generation` moves. Closer to `useEffect` with a dependency than
to a fiber mount. Reload gets *safer* rather than more dangerous, because
teardown replaces the idempotence guards.

**Registration and evaluation are different things.** An early draft of this
section claimed context-dependent providers had to stay pull, because
`repo_page_tabs(repository:, user:)` cannot be answered at install time. That
conflated two steps. The *set* of tab providers is a static install; the
per-repository, per-user filtering is evaluation over that installed set. Same
for `available_for?(chat_session, tier:)` and `enabled_for?(job)`. Effects
install; call sites evaluate.

**Federated extension points.** `EXTENSION_POINTS` is a frozen array of names
in core and `providers_for` raises on anything else, so a plugin can only
contribute to a point core anticipated. `search_source` showed the limit: it
existed and `test_insights` contributed to it, but *search itself was core*, so
the interface had to be pre-declared by the kernel. G6 made search a plugin
**host** without making it a plugin; G13 made it a plugin outright.

Under this model a plugin declares the points it hosts, and contributions name
them qualified — `global_search:source`, `workflow:judge`. Core's points are the
ones the kernel hosts, nothing more. Contributing to `global_search:source`
implies a dependency on `global_search`, which the existing health model already
handles: a disabled hard dependency degrades the dependent and withholds its
providers. A contributor that only wants the point when it happens to be there
declares `optionally_depends_on:` instead and stays healthy without it --
`test_insights` is the worked example.

Two properties to preserve deliberately:

- **Declared, not free-form.** Plugin-hosted points still go in the manifest.
  `EXTENSION_POINTS` + `INTERFACE_FOR` is what lets the boundary audit and the
  graders reason about the surface; federating that list must not mean losing
  it.
- **Disposal cascades both ways.** A contribution to a plugin-hosted point has
  two lifetimes — dispose when the contributor unloads, and when the host
  unloads. This is what effect nesting buys, and it is the part most likely to
  be got wrong if each call site hand-rolls it, so it belongs in the mechanism.

**This is the answer to the `disableable` open question**, which currently
gates three separate things: the wider `github_source` extraction, the
agent-provider plugins, and G12's mid-run disable where a persisted
`chain_template` references a step kind whose handler just vanished. "Disable
means dispose what was installed" turns `disableable: true` from a claim into a
mechanism, and reverse-order disposal is what makes `agent_insights` unwind
before `agent_memory`.

**Build order.** The mechanism first (install + teardown + generation
re-apply), then manifest-declared namespaced points, proven on the kind
registries — `Job::Kind`, `Workflow::TriggerKind`, `Step::Kind` — because that
is where the staleness bugs actually happened. `bin/plugin-boundary-audit` is
the proof that removal removes.

**Step 1 landed.** `Syrus::EffectScope` records teardowns and disposes in
reverse; `Syrus::Installer` re-applies when `PluginRegistry.generation` moves;
`Syrus::KindRegistry` now installs plugin entries instead of merging them on
every read, so disabling a plugin removes its kinds rather than relying on a
downstream cache to notice. Cross-process propagation moved into the
plugin-record cache: when the TTL expires and the enabled set turns out to have
changed, it bumps the generation, which keeps `sync!` an integer compare on
hot read paths. (A database-backed fingerprint there would have been a
per-read query in test, where the TTL is zero — the same trap that once made
the suite 30% slower.)

**Step 2 landed: the core push registries.** `Filters.register_subject` /
`register_chips`, `SmartFolder.register_subject!`,
`CredentialProbe.register_probe` / `register_secret_extractor` and
`ChatSessionRehydrator.register` all return the teardown that removes exactly
that registration again, and the eight plugin call sites moved into
`Syrus::Installer.define(label, plugin:)` — which only installs while that
plugin is enabled, so no plugin writes the guard itself. Disabling a plugin now
retires its filter vocabulary, which `spending_insights` already claimed in a
comment and nothing implemented.

Two things this shook out, both worth keeping in mind for the remaining
conversions:

- Installing only while enabled is *stricter* than what came before, because
  the old registrations ran unconditionally at boot. `worker_timeline` is
  `default_enabled: false`, so its filter subject used to exist for a disabled
  plugin; its specs now enable it. A core spec pinning `has_claude_token` on
  the admin-user subject became order-dependent for the same reason and now
  asserts only core's own chips.
- Teardown makes registration state *stateful*, so anything that clears it
  without restoring is unrecoverable mid-process. Installers are defined once,
  where their code loads; `Installer.snapshot`/`restore` exist so a spec can
  borrow an empty installer and put the real one back.

**Step 3 landed: host associations are gone.** All four plugins that injected
associations onto core models (`test_insights`, `agent_memory`,
`agent_insights`, `design_docs` — 12 associations across `User`, `Repository`,
`Run`, `ChatSession`) now reach their rows through their own scopes and clean
up through `Syrus::DataCleanup`. No plugin modifies a core class any more, and
`reflect_on_all_associations` no longer depends on which gems are installed.

Measuring first is what made this cheap. Repository is *archived*, never
destroyed; User is never destroyed at all; ChatSession is soft-deleted; and
there are no database foreign keys by policy. So `dependent: :destroy` on
those associations only ever fired in specs. Better still, four of
`design_docs`' six injections had **zero readers** — both core call sites that
look at design docs start from `DesignDocs::DesignDoc` and use the plugin's
own association — so they were carrying nothing but their `dependent:`
behaviour.

Three things worth carrying into the remaining work:

- An injected association is also a *join path*. Two `test_insights` queries
  traversed `Job -> workflows -> steps -> runs -> test_runs` downward and
  broke. A plugin can always join upward, since its own table `belongs_to` a
  core one, so both were inverted to start from the plugin's table.
- `dependent:` is not always `:destroy`. `design_docs` used `:nullify` for the
  origin chat back-reference — a document outlives the chat it came from — and
  the cleanup preserves that.
- Cleanup registrations carry no `plugin:` scope. They could not be
  `:domain_subscriber`s either, since `Events.subscribers_for` resolves through
  `providers_for`, which is enabled-filtered.

**Step 4 landed: federated extension points.** A plugin declares `hosts:` in
its manifest and contributions name the point qualified (`test_insights:parser`).
Proven on a real case rather than a synthetic one: `test_result_parser` was a
core-owned point consumed only by `test_insights` and provided only by `ruby`,
so core owned an interface that existed solely for one plugin's ingestion path.
`test_insights` hosts it now and core's frozen list is one shorter.

The interesting constraint came from `ruby`: a language plugin contributes a
parser but must work with `test_insights` uninstalled. `Ruby::RspecParser.include(TestInsights::Parser)`
turned an optional hook into a hard load-time dependency, and the boundary
grader caught it. Contributors duck-type the contract instead; the qualified
string is a *weak* reference that names the host without depending on it, with
`optionally_depends_on` recording the relationship in the graph. That also
answers what "no core-declared interface" means for hosted points: the shape is
the host's business, and the host validates its contributors at call time.

**Still to convert**: the `providers_for` call sites
whose results are static installs — nav and admin pages, repo tabs, domain
subscribers, search sources, routes. Per-call evaluation over an installed set
(`available_for?`, `enabled_for?`) stays where it is.

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
  crash, no orphaned foreign key — which is exactly what "genuinely disableable
  and deletable" requires
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

**`test_insights`** — **done.** All five tables moved, plus the query layer,
five MCP tools, the repository Tests tab, and the Job detail Tests tab. Core
keeps `JunitXmlParser` (its `ParsedRun` is the `:test_result_parser` contract),
a `Steps::Grader` that only publishes the event, and a
`MainBranchFailureClassifier` that asks `:test_evidence` providers instead of
reading a model. Two extensions fell out: `ui_slot` gained a `job.detail.tab`
slot, and the namespace grader now skips separate-database models.

Original assessment, for the record: with G1's inline `step.grader.completed`
event, all five tables move: `test_runs`, `test_cases`, `test_identities`,
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

**`agent_memory`** — **done.** `AgentMemory::Entry`/`AuditEvent` (tables
`agent_memory_entries`, `agent_memory_audit_events`), nine MCP tools, the
`/memories` page, the filter subject, and the prompt-context renderer. It ships
`default_enabled: true` and `agent_insights` declares
`depends_on: ["agent_memory"]`, so the FK from a suggestion to the entry it
proposes retiring is plugin-to-plugin, and disabling the store degrades
`agent_insights` (providers withheld) rather than breaking it.

The ordering constraint that blocked it held exactly as predicted:
`insight_suggestions.target_memory_id` is a schema-level FK into
`chat_memories`, which no `defined?` guard could have papered over. Insights
moved first; memory followed.

Framed as **swappable, not merely optional**, as intended. The `memory_store`
extension point takes `prompt_context`, `chat_context_lines` and
`chat_instructions`; core reaches it only through `Syrus::Memory`, which
returns empty for a missing provider and logs-and-degrades for a raising one.
`Prompts::MemoryContext` survives as core's seam, so the six prompts that
compose it did not change at all.

Two things the inventory missed:

- **The chat system prompt's memory copy names the tools.** Leaving it in core
  would advertise `write_memory`/`publish_memory` to an agent that has no such
  tools, so `chat_instructions` moved to the provider with them.
- **`/memories` is a settings page, not a primary sidebar page.** `sidebar_page`
  fed only the main nav, so it gained an optional `section:` (`"primary"` by
  default, `"settings"` for this), with the settings side nav merging pages that
  declare it. Advertising the admin-only audit tool needed the chat tool-set
  contract widened too: `tool_definitions` now takes an optional
  `chat_session:`, mirroring the workflow side's optional `context:`, so an
  admin tool is withheld rather than merely refused at call time.

Dead surface: `embedding` was dropped in the move (nothing reads or writes it).
`visibility`, `expires_at`, and `last_verified_at` are written by nothing but
*are* read — the first two in tool payloads, the last in the context ordering —
so removing them is a behavior change and stays a separate piece of work.

**`github_issues` (into `github_source`)** — **done.** The controller, the API
client, the component, and the issue i18n moved; the tab is contributed through
`repo_page_tab`, so its simple-mode hiding is the plugin's decision rather than
a branch in core's tab serializer. `repository_detail_json` and its helpers
became the `RepositorySummarySerialization` core concern so the plugin could
render the same repository header without duplicating it.

This is explicitly *not* "extract GitHub." `github_source` is ~350 LOC against
`GithubClient` alone at 1,221 lines, ~90 core files referencing it, twelve
pollers, `Installation`, and GitHub columns on `jobs`, `repositories`, `users`,
and `app_settings`. Moving the issues UI is a week. Moving GitHub is a separate
program that starts by fixing the `InputSources::Github` boundary violation and
by introducing generic source artifacts.

Also note `SourceControl::Providers` is a dead extension point — referenced only
by its own spec. Either wire it or delete it.

**`terminal`** — `TerminalSession`, `TerminalRelay`, `TerminalChannel`,
`TerminalSessionJob`. Self-contained and already gated. Per "a plugin is its own feature flag", the
existing `terminal` feature flag is replaced by the plugin's own enabled state.

Blocked on **G7** (Action Cable channel registration), which is the only real
gap. One further coupling, confirmed in the source rather than assumed:
`app/frontend/routes/jobDetail/WorkflowGraph.tsx:7` imports
`createTerminalSession` from core's terminal API to render its "open terminal"
button. That is now cheap — `ui_slot` (G5) declares a `job.detail` slot, so the
button becomes a plugin-contributed panel rather than a core import.

**Nearest to ready of everything left**: one scoped gap, one small UI move, no
schema work, no design question.

**`coverage`** — **moved to Tier 3.** `coverage_snapshots`, the hit-map TTL
prune job, the coverage PR comment steps, and the `get_coverage_report` tool.
G1 and G2 cover the events and the prune job, but `coverage_analyze` and
`coverage_pr_comment` are conditional steps that `Workflows::Base` inserts into
the `initial`, `retry`, and feedback chains. That is the same problem
`visual_review` has, and it wants the same answer: a workflow-composition
extension point, not more plumbing.

**`video_walkthroughs`** — `ChatVideoWalkthrough`, the Gemini client and
transcoder, `VideoWalkthroughAnalysisJob`, `VideoWalkthroughPruneJob`, three
chat MCP tools, four prompts, the `videos` queue, and the composer/media-panel
UI. Still the strongest candidate on value: it is the only thing dragging a
non-Anthropic model vendor into core, it already degrades cleanly when off, and
it owns a retention job.

**Correction — the recorded schema blocker was wrong.** An earlier note had
this waiting on a `chat_messages.video_walkthrough_id` column. That column does
not exist. The chat linkage is a JSON key in `chat_draft_content.metadata`,
which needs no schema inversion at all.

Its two listed prerequisites, G2 and G4, have both landed. What actually
remains:

- `ChatTurnJob#walkthrough_orientation` injects prompt text into a chat turn
  when the incoming message carries a walkthrough. There is no chat-turn
  injection point — `prompt_injector` is workflow-only (`call(repository:,
  job:)`). This is the real gap, and it is small and well-shaped.
- `app_settings.video_retention_days` / `video_storage_budget_mb` move to
  plugin settings (G4), joining the Schema Inversion Backlog entries below.
- Remaining touch points: `chat_serialization`, `credential_probe` (the Gemini
  key probe), `chat_session`, `chat_draft_content`.

**`scheduled_tasks`** — `ScheduledTask`, `CronTemplate`, `PollScheduledTasksJob`,
`ScheduledTaskFire`, the pileup policies, the `Schedules::*` parsing layer,
twelve MCP tools, four pending actions, two controllers, five React routes, and
the `syrus schedule` CLI family.

Needs G1, G2, G3, G4, G8, and the schema inversion "plugins must not add columns to core tables" requires. The three core
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

**Status: the only listed prerequisite still open is G8.** G1, G2, G3 and G4
have landed, and the `job_kinds` registry built for `agent_insights` covers the
`Job::KINDS` half of the schema inversion. G8 remains an unanswered design
question — the CLI has no plugin story, and `scheduled_tasks` owns a whole
`syrus schedule` command family, so extracting it either strands those commands
or forces the answer. That makes G8, not the code, the gate. Recommended shape
when it is taken up: server-described commands (the instance advertises the
command surface, the CLI renders it), with `syrus-<name>` binaries on `PATH` as
an escape hatch for anything that needs real client-side behaviour.

**`agent_insights`** — extracted. `AgentInsights::Suggestion`/`ScheduleConfig`/
`AuditEvent` (tables `agent_insight_suggestions`,
`agent_insight_schedule_configs`, `agent_insight_audit_events`),
`InsightSweepJob`, `AgentInsights::Workflow`, its run step, its `WorkDefinition`,
its Job/trigger/step kinds, seven MCP tools, three controllers, two React
routes. Per "a plugin is its own feature flag" the `agent_insights` feature flag and
`Feature.agent_insights_enabled?` are gone — the plugin is the flag, and it
ships `default_enabled: false` to match the flag's old default.

The specific thing the user called out — `Job#after_update_commit
:trigger_insight_if_max_threshold_reached` — is now `AgentInsights::Subscribers`
on `job.closed`, carrying the whole gate (skip the plugin's own kind, config
enabled, count past `max_jobs_since_last_run`) rather than leaving it in core.
No plugin monkey-patches an Active Record callback onto `Job`; association
injection is sanctioned, behavioral injection is not.

See the Phase 5 status note for the three platform gaps this move exposed
(`job_kinds`, plugin-owned `WorkDefinition`s, `Step::Kind#agent_role`).

Dependency note: this plugin writes memory entries (`source_type: "insight"`)
and `AgentInsights::Suggestion` has an FK to one. It declares a hard
`depends_on: ["agent_memory"]` with G11's semantics: if memory is disabled,
`agent_insights` goes `degraded` and its providers are withheld — it does not
crash, and it does not silently half-work.

### Tier 3 — waiting on G12

Both entries share one blocker: a plugin cannot insert a step into a core
workflow chain. That is now **designed** — see G12 for the four anchors, the
`judge` contract, and the two things deliberately left in core — but not built.

**`visual_review`** — the step, prompt, artifacts, and review-loop membership
move to `browser`, contributed as a `judge` (G12). `RepoVisualReviewPlan` moves
with it, so the plugin reads its own `.syrus.yml` block instead of core
materializing the loop. Intended as the proof of the anchor, since it exercises
the hardest part: a judge is half a loop, not a step.

**`coverage`** — `coverage_snapshots`, the hit-map TTL, the analyzer, and
`coverage_analyze`/`coverage_pr_comment`. A `post_implementation` contribution
plus `RepoCoveragePlanReader` moving into the plugin. Straightforward once the
anchor exists; it is a step that runs once after the loops, not a judge.

**`review_plan`** — a new candidate this design surfaces. It is already the
only step after `pr_open`, is opt-in per repository, and must never fail the
parent workflow. That makes it the natural first `post_pr` plugin and a useful
test that the anchor honours `fail_policy: :advance`.

### Deferred

**`main_branch_health`** — skipped for now by decision, and the analysis
supports it. It is not a feature, it is a *gate*: `StepDispatcher.main_health_blocking?`
blocks every workflow start, `LandingQueueProcessor` pauses landing on it,
`WorkEngine::Reconciler` references it 26 times, and `SystemAlerts`,
`PollPullRequestJob`, and `RunJob`'s concurrency exemption all branch on it. It
also added eleven columns to `repositories` and two to `app_settings`, all of
which "plugins must not add columns to core tables" would require inverting.

Revisit only behind generic `work_gate`, `system_alert`, and repair-classifier
extension points — i.e. after core can express "something can veto a workflow
start" without knowing what that something is.

**`delivery_tracks`** — promotion, hotfix sync, and upstream export are part of
the core workflow model. Not a move candidate.

### Still outstanding from the previous plan

**`syrus_dev` storage — resolved: it stays core.** The admin pages,
controllers, and tools moved; the models were listed as a mechanical follow-up.
On inspection they are not a follow-up at all, they are core infrastructure,
and this plan's own boundary rule already says so: *generic event, log, and
search infrastructure* is core, and only concrete tables may be plugin-owned.

- `OperationalLogEvent` is registered as a durable sink in core's
  `Observability::EventStream`, and `PerformanceLogging` -- which writes
  through it -- is called from 44 core files, the plugin registry included.
  Moving the model would invert the dependency: core would need the plugin in
  order to log.
- `BrowserErrorEvent` is written by `api/v1/app/browser_errors#create`, the
  non-admin endpoint the SPA reports its own exceptions to. The open question
  asked whether core pages surface these; they do, and they ingest them.
- `OperationalLogIndex` is the FTS index over the above, so it follows them.

What was genuinely dev-facing -- the performance and operational log admin
pages, `SqlExplain`, the `read_performance_diagnostics` and `read_syrus_logs`
tools -- has already moved. There is no remaining storage move here, and the
boundary stress test agrees: removing `syrus_dev` leaves the suite green.

## Schema Inversion Backlog

"Plugins must not add columns to core tables", applied to what exists today. Each entry is a data migration, not
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
 ├── agent_memory      (extracted) ◄── agent_insights (extracted)
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

One edge still needs enforcement work. `agent_insights → agent_memory` is
live and uses G11's hard-dependency semantics: disabling the store puts
`agent_insights` in `degraded` and withholds its providers. And `test_insights` is consumed by core's
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
- `test_insights` storage.

### Phase 4 — Agent-facing plugins
- `agent_memory` as a swappable provider (done, after `agent_insights`),
  `github_issues` (done); `coverage` moved to Tier 3.
- Remaining: `video_walkthroughs`, and `terminal` once G7 lands.

### Phase 5 — Scheduling and insights
- `agent_insights` (done, taken first — it is unblocked and it unblocks
  `agent_memory`), then CLI extensibility (G8), then `scheduled_tasks`.
- Job Origin step 3: move readers onto origin predicates and drop
  `scheduled_task_id`, `external_ref`, and `input_source_id`.

### Phase 6 — Registry model, then design work
- G13 first: installation effects with teardown, then manifest-declared
  namespaced extension points, proven on the kind registries and verified with
  `bin/plugin-boundary-audit`. Everything below assumes it.
- Workflow composition (G12) — anchors plus `judge`, with `visual_review` as
  the proof, then `coverage` on `post_implementation` and `review_plan` on
  `post_pr`. `adversarial_review` as a second judge is what shows the anchor is
  not shaped around one caller.
- Answer the `disableable` question the stress test raised (see Open
  Questions). It gates the wider GitHub extraction, the agent-provider
  plugins, and G12's mid-run disable case — three problems, one decision.
- Revisit `main_branch_health`.

### Ordering note

Of what is left, the queue by readiness rather than by phase number:

| | blocker |
|---|---|
| `terminal` | G7 only, plus one `ui_slot` move — nearest to ready |
| `video_walkthroughs` | a chat-turn prompt injection point (small, well-shaped) |
| `visual_review`, `coverage`, `review_plan` | G12, now designed |
| `scheduled_tasks` | G8, an open design question, not code |
| `github_source`, `claude_agent`, `codex_agent` | G13 for the mechanism, then the data half of the `disableable` decision |
| `main_branch_health`, `delivery_tracks` | deferred by decision |

## Open Questions

**How should a plugin that rows already reference be disabled?** The stress
test found `claude_agent` is marked `disableable: true` but disabling it makes
every `agent_provider: "claude"` row invalid (see the stress-test findings
above).

G13 answers the *mechanical* half — disable disposes what the plugin installed,
so its kinds, subjects, tabs and steps genuinely go away instead of lingering
in a hand-invalidated cache. It does not answer the *data* half: rows that
already reference the plugin outlive any teardown. Three candidates there, none
obviously right:

1. Dynamic default — drop the `"claude"` column default and pick the first
   registered provider at write time. Cheapest, but a migration across four
   tables, and it does not help rows already persisted.
2. Tolerant validation — validate inclusion only when the value changed, so a
   persisted-but-disabled provider stays readable. Keeps existing rows usable,
   but lets a Job dispatch to a provider that is not there.
3. Refuse the disable — the registry knows which providers rows reference, so
   the admin action could decline with a reason. Safest, and makes
   `disableable` mean something enforceable rather than declarative.

`github_source` has the same shape through `Repository`'s `has_one`, so the
answer should cover both.


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
