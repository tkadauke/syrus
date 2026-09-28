# Syrus — agent guide

A multi-user, cross-repo issue→PR automation harness. Owns the
deterministic plumbing (clones, branches, PRs, cleanup) so the
agent can focus on writing code. See `README.md` for the human pitch
and `ROADMAP.md` for milestone planning.

## Repository hygiene

**Never name a private Syrus instance's records in prose.** `JOB-<id>`,
`EPIC-<id>`, `WF-<id>`, `RUN-<id>`, chat IDs, private instance hostnames, and
private repository incident labels must not appear in comments, spec
descriptions, commit-adjacent docs, or any file under `config/syrus_docs/` /
`website/` / a plugin's `docs/`. They mean nothing to anyone outside that one
instance, and they go stale the moment the record is archived.

The moment this bites is right after you debug a production incident, when
the natural thing to write is `# Regression for WF-29556:` or
`# this was JOB-409's root cause`. Write the *explanation* instead — the
identifier was only ever standing in for it:

```ruby
# Bad                                  # Good
# Regression for WF-29556: ...         # Regression: ...
# the WF-480 run storm                 # a production run storm
# matching JOB-5025's delete-only …    # matching the previous delete-only …
# WF-28163 ran 14 of them one at a …   # a production workflow ran 14 of them …
# Part of EPIC-27: groundwork for …    # Part of the access-control work: …
```

This is about prose, **not** about identifier-shaped strings:

- Test fixture values are fine as-is. `run_id: 149674`, `slug: "JOB-874"`,
  `EPIC-7` in a component test — leave them alone, don't renumber them.
- Format examples are fine: `syrus checkout JOB-<id>`, "accepts `JOB-123`,
  `job-123`, or `123`", `JOB-42` in a CLI doc.
- `docs/plans/**` is exempt — it is the designated home for
  instance-specific evidence, alongside the operator conversation.

`spec/architecture/no_private_instance_identifiers_spec.rb` enforces the
comment half of this mechanically; the docs half is on you.

## Stack

Rails 8.1.3 · Ruby 3.4.10 · SQLite (dev/test) / MySQL (prod) ·
Solid Queue + Solid Cache + Solid Cable · React + TypeScript via Vite ·
TanStack Query · Tailwind via `tailwindcss-rails` · Go CLI under `cli/` ·
Octokit for GitHub.

## Architecture in 60 seconds

External polling drives everything — no inbound GitHub callbacks. `PollAllRepositoriesJob`
fans out to one `PollRepositoryJob` per active repository, which lists
issues with the configured trigger label. Each new labeled issue creates
a `Job` (the *thread*), which auto-creates an initial `Workflow` (the
*attempt*), which auto-enqueues its first `Step`'s `Run`. `PollAllPullRequestsJob`
does the same for PR review feedback, creating follow-up `Workflow`s on
existing `Job`s.

The state machines (AASM):

```
Job (one per issue):       open ⇄ closed
Workflow (one per attempt): queued → running → succeeded | failed | cancelled
Step (one per step):        queued → running → succeeded | failed | cancelled
Run (one per step):         queued → running → succeeded | failed | cancelled
```

`Job` carries the GitHub identifiers (issue + PR numbers, branch name) and
the credential mode captured at creation time (`app` or `pat`).
`Workflow` is the top-level unit for a single attempt; it owns a chain of
`Step`s and a shared workspace at `$SYRUS_DATA_ROOT/workflows/<workflow_id>/`.
Each `Step` dispatches to a `Steps::` handler and owns one `Run`. `Run`
carries per-attempt state — prompt, agent metadata, diff, PR copy.

`Job#kind` is `issue` (default, filed from GitHub), `cron` (fired by a
`ScheduledTask` — no issue_number, prompt pre-rendered at fire time), or
`direct` (operator-created free-form prompt, no GitHub issue or scheduled
task — prompt supplied directly at job creation). All three kinds use the
same Workflow pipeline.

**WorkUnit / WorkIntent / WorkDefinition** (`app/models/work_unit.rb`,
`app/models/work_intent.rb`, `app/services/work_definitions/`) is a newer
ownership/scheduling layer being rolled out alongside the AASM machines
above, not a replacement for them: `WorkUnits::Launcher.start!` still always
falls through to `StepDispatcher.start_workflow`, which remains the actual
execution engine. `WorkIntent` is the durable "we want this work done"
record; `WorkUnit` is one runtime attempt at it, holding `WorkUnitLock`s
(mutex per job/epic/repo/landing-slot) and `WorkUnitMember`s. `WorkDefinitions::Base`
subclasses (~28 built-ins — `Initial`, `Rebase`, `AutoMerge`, `MergeTrain`,
`JobBundle`, etc., auto-registered by kind) centralize the retry/lock/landing
policy that used to be scattered across `StepDispatcher` and landing-queue
services. `WorkUnits::PathOwnership` maps each concrete path
(retry/resume/pause, auto_merge/merge_train/stack_rebase, reconciler repairs)
to WorkUnit ownership directly. The old shadow-mode and ownership-cutover
feature flags have been removed; compatibility now lives in
presentation/diagnostic fallbacks, not in the launch funnel.
`WorkEngine::Reconciler` targets repairs at `WorkUnit`/`WorkIntent` records
first. Admin surface: `/admin/work_units`, with normal Job-page WorkUnit
internals gated by `AppSetting.show_work_unit_debug?`.

**Repository content** (`app/services/repository_content.rb`) is how Syrus
reads a repository without cloning it: the pre-workflow `.syrus.yml` read,
preview projects, skills, the Job source browser and diff viewer, `read_pr`.
`RepositoryContent.for(repository).resolve(ref)` gives an immutable revision;
`tree`/`read`/`changes` read at it and are cached. Answers come from
`repository_content_provider` plugins, replicas before upstreams:
`git_mirror` (a local mirror service run through `plugin_runtime`) first,
`github_host` (the GitHub API) after. `NotFound` is a final answer;
`Unavailable`/`Unsupported`/`UnknownRevision` fall through to the next
provider, and `Truncated` carries a partial answer only display code may use.
Never read content through `GithubClient` directly --
`spec/architecture/repository_content_reads_spec.rb` enforces it -- and never
treat `Unavailable` as "the file does not exist". Core specs read through a
fake provider by default (`spec/support/repository_content.rb`,
`stub_repository_content`).

## Progressive disclosure

`AGENTS.md` is a symlink to this file. Keep the root guide slim enough for
Muse-backed agents to load at startup, and put deep detail behind explicit
references instead of expanding this file in place.

Read the reference file that matches the work in front of you:

- [Architecture details](.claude/reference/architecture-details.md) — trigger
  kinds, workflow pipelines, terminal feature, scheduled tasks, and live UI.
- [Conventions](.claude/reference/conventions.md) — full implementation,
  frontend, plugin, migration, deployment, and testing conventions.
- [Deployed operations](.claude/reference/deployed-operations.md) — testing on
  the deployed instance, kubectl debugging, workflow operations, and deploy
  targets.
- [Gotchas and key files](.claude/reference/gotchas-and-key-files.md) — known
  failure modes and the file map for common subsystems.
- [.claude/skills/implement/SKILL.md](.claude/skills/implement/SKILL.md) —
  live implement-step prompt instructions.
- [.claude/skills/rebase/SKILL.md](.claude/skills/rebase/SKILL.md) — live
  rebase and stack-rebase prompt instructions.
- [.claude/skills/syrus-debug/SKILL.md](.claude/skills/syrus-debug/SKILL.md) —
  live operational debugging instructions.

## Conventions summary

Public docs, operator docs, prompt source, plugin boundaries, frontend i18n,
CLI/API behavior, desktop behavior, workflow registries, credentials, queues,
migrations, and tests all have detailed rules in
[.claude/reference/conventions.md](.claude/reference/conventions.md). Before
editing any of those surfaces, read that file and follow the local convention
instead of inventing a parallel pattern.

High-frequency reminders:

- **Public website/docs stay current.** Product-facing behavior changes must
  update `website/` in the same PR.
- Keep product-facing behavior aligned with `website/` and operator-facing
  behavior aligned with `config/syrus_docs/`.
- Preserve `AGENTS.md -> CLAUDE.md`; edit the shared guidance through this file.
- Add new workflow trigger or step metadata in `Workflow::TriggerKind` or
  `Step::Kind` rather than scattering constants.
- Do not add core references that make bundled plugins undeletable; plugin-owned
  tools, docs, routes, and specs belong with the plugin.
- New chat-facing MCP tools need an explicit rendering decision: add a tool card
  under `app/frontend/routes/chat/tool_cards/` or
  `plugins/<name>/app/frontend/tool_cards/`, or register an explicit
  `generic`/`hidden`/`deferred` status in
  `Admin::McpToolCardCoverage::EXPLICIT_CARD_STATUSES`.
- When drafting work for chat, keep proposals finishable inside one bounded
  implementation attempt. Do not ask a Job to dogfood, burn in, monitor
  production, or wait for future operator action; avoid brand-new Epics with
  only one child Job.
- Generate migrations with `bin/rails generate migration`, make them idempotent,
  and avoid JSON column database defaults on MySQL.
- Use `git diff <base>...HEAD` for three-dot diffs.

## Tests are not optional

**Every PR must include tests for the behavior it changes. PRs without
tests will not be merged.** This applies to every kind of change —
new features, bug fixes, refactors, plumbing, "trivial" tweaks. If
the change is too small to justify a test, the change is too small
to need a PR; fold it into something testable.

What "with tests" means here:

- **New behavior** → a spec that fails without your change and passes
  with it. If you can't write one, the behavior isn't well-defined yet.
- **Bug fix** → a regression spec that reproduces the bug. The fix
  without the spec is half a fix; nothing stops it from regressing.
- **Refactor** → existing specs must still pass, AND if the refactor
  touches an under-tested area, add the missing coverage as part of
  the same PR. "I didn't change behavior" is not a free pass.
- **Anything touching the agent loop, RunJob, AgentInvocation, MCP,
  or the polling jobs** → exercise it with the existing test seams
  (`RunJob.agent_runner`, `PrSummarizer.runner`, WebMock for Octokit,
  stubbed AgentInvocation Result). These seams exist precisely so
  every code path can be tested without shelling out to real claude
  or hitting real GitHub.

If the test would require infrastructure that doesn't exist in the
test environment (e.g. SolidQueue tables aren't loaded in test —
test runs single-database), stub the boundary and say so in a
comment. Don't skip the test.

The suite is large. During implementation, run the narrowest useful local
validation: the exact failing example, the smallest affected spec file, or the
focused frontend test file. Syrus runs typed framework graders from
`.syrus.yml` after agentic steps for broader feedback.
