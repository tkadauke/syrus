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


## Progressive disclosure index

Muse-backed agents load `CLAUDE.md` at startup, so this file stays intentionally
small. Read the referenced files only when your task touches that area:

- [Workflow architecture details](docs/agent-guide/architecture-details.md): trigger kinds, workflow pipelines, terminal feature, scheduled tasks, and live UI notes.
- [Conventions and tests](docs/agent-guide/conventions.md): the full engineering conventions catalog and the detailed testing contract.
- [Deployed operations](docs/agent-guide/deployed-operations.md): deployed-instance testing, admin API usage, kubectl debugging, workflows, and deploy target notes.
- [Gotchas and key files](docs/agent-guide/gotchas-and-key-files.md): incident lessons, sharp edges, and a file-by-file orientation map.
- Agent skills live under [.claude/skills/](.claude/skills/): use [implement](.claude/skills/implement/SKILL.md), [rebase](.claude/skills/rebase/SKILL.md), or [syrus-debug](.claude/skills/syrus-debug/SKILL.md) when the task shape matches.

## Conventions summary

- **Public website/docs stay current.** Product-facing behavior changes must
  update `website/` in the same PR. See the full rule in
  [Conventions and tests](docs/agent-guide/conventions.md).
- Detail pages graduate to shared underline tabs only when the sections are
  peer workflows operators revisit independently.
- Prefer plugin seams and registered providers over hardcoding plugin-specific
  behavior in core. Disabled plugins must not be eagerly loaded.
- Use existing workflow, Run, agent-invocation, MCP, polling, repository-content,
  and preview test seams instead of shelling out to real agents or GitHub in specs.
- Every behavior change needs focused tests. During implementation, run the
  narrowest useful local validation; the configured Syrus graders handle broad
  suite coverage after the agent step.

## Operational pointers

- For local debugging and deployed-instance checks, start with
  [Deployed operations](docs/agent-guide/deployed-operations.md).
- Before adding a new workflow step, trigger kind, tool surface, or plugin seam,
  read [Workflow architecture details](docs/agent-guide/architecture-details.md)
  and [Conventions and tests](docs/agent-guide/conventions.md).
- Before touching fragile areas, skim [Gotchas and key files](docs/agent-guide/gotchas-and-key-files.md)
  for prior failures and the files most likely to matter.
