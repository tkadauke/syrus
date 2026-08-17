# Skills

Skills are named, freeform instruction sets — the escape hatch for tasks
(broad investigations, judgment-heavy debugging, one-off operational actions)
that resist decomposition into the deterministic Workflow/Step pipeline. See
`config/syrus_docs/trigger_kinds.md` (the `skill` trigger kind) and
`config/syrus_docs/workflow_steps.md` (the `run_skill` step) for how a skill
launch executes once a Job exists.

## Two tiers, resolved in order

1. **repo-local** — `.syrus/skills/<name>/SKILL.md`, git-tracked in the
   target repository (YAML frontmatter `name`/`description`/`parameters` plus
   a markdown instruction body).
2. **built-in** — Ruby PORO classes under `app/services/skills/`, registered
   in `Skills::Registry`.

A repo-local skill shadows a built-in one of the same name — there is no
separate namespace. `Skills.for(repository:, name:)` always reports which
tier actually resolved (`source: :repo_override` or `:built_in`); later
surfaces (the launch picker, the Run detail view) always show that source so
a shadowed skill is never a silent debugging trap.

## Parameter schema

A skill declares its launchable parameters as an array of fields — the same
shape `InputSource#config_schema` uses for input-source config forms
(`Skills::ParameterSchema`):

```ruby
[
  { key: "question", type: "string", required: true, label: "Question" },
  { key: "notes", type: "text", required: false, label: "Notes" },
  { key: "dry_run", type: "boolean", required: false, label: "Dry run", default: false },
  { key: "retries", type: "integer", required: false, label: "Retries", default: 3 },
  { key: "environment", type: "select", required: true, label: "Environment", options: %w[staging production] }
]
```

Supported `type` values: `string`, `text` (multi-line), `boolean`, `integer`,
`select` (requires `options`). `Skills::ParameterSchema.validate!` checks a
submitted args hash against the schema — every problem is collected and
reported together (missing required fields, an unlisted `select` option, a
non-integer `integer` value, an undeclared key) rather than failing on the
first one.

## Launching a skill from the UI

Repository detail → **More → Launch skill** opens the skill picker at
`/repositories/:repository_id/skills/new`. The picker lists every skill
available to that repository (built-ins plus that repo's `.syrus/skills/*`
overrides) with its description, resolution source, and — for a repo-local
skill — the resolved `SKILL.md` path. A repo-local skill that shadows a
built-in of the same name is flagged explicitly before launch.

Selecting a skill renders a form generated from its parameter schema
(reusing the same field-rendering approach as the input-source config form).
Submitting creates a `direct` Job with `skill_name`/`skill_args` set via
`SkillJobs::Creator`, which validates the skill resolves and the submitted
args satisfy its parameter schema before creating anything. The created
Job dispatches a `skill` Workflow (see `trigger_kinds.md`).

## API

- `GET /api/v1/app/repositories/:repository_id/skills` — lists available
  skills for the repository, each with `name`, `description`, `source`
  (`built_in`/`repo_override`), `resolved_path`, `resolved_class`,
  `shadows_built_in`, and the normalized `parameters` schema.
- `POST /api/v1/app/repositories/:repository_id/skills` — creates a skill
  Job. Params: `name`, `args` (a hash matching the skill's parameter schema),
  optional `agent_provider`, optional `priority`. Returns `422` with a
  `validation_failed` error when the skill doesn't resolve or the submitted
  args fail schema validation.

## Slash-command execution in chat

A repository-scoped chat can run a skill immediately with `/skill-name
key=value ...` instead of launching a separate Job. The available commands
are that chat's attached repository's resolved skill set (`Skills.all_for`,
built-ins shadowed by `.syrus/skills/*` overrides) — computed dynamically per
chat, not hardcoded, so repo-local skills show up as soon as they exist on
the default branch. A chat with no attached repository has no skill slash
commands.

Typing a recognized `/skill-name ...` in a repo-scoped chat executes
immediately — no proposal or confirmation card. A slash command is already a
deliberate, explicit operator action, the same trust level as `/loop` or
`/code-review`. `Skills::ChatInvocation` resolves the command and validates
its args against the skill's parameter schema server-side before anything
runs; an unresolvable name or invalid args gets a clear chat message instead
of being handed to the agent to guess at.

Execution reuses the chat's own Coding Mode turn — the writable checkout and
direct command execution the agent already has in Coding Mode — rather than a
second, separate sandboxed path. A skill invoked this way therefore requires
Coding Mode to be enabled for that chat; if it isn't, Syrus posts a clear
system message telling the operator to enable Coding Mode instead of running
the skill read-only or silently doing nothing. If the skill's execution
produces a code diff, the *existing* Coding Mode handoff confirmation
(`complete_implement_step` / `submit_coding_changes` → `coding_handoff`,
already requiring operator confirmation) applies unchanged before any Job or
PR is created — slash-command immediacy is about running the skill, not
about bypassing that gate. A skill that produces no diff (an operational or
`investigate`-style skill) simply reports its results in the chat thread;
there is nothing further to confirm.

Which skill definition resolved (built-in vs. repo override, and the
resolved path/class) is recorded as a synthetic `resolve_skill` tool call in
the chat's ordinary tool-call trace, immediately after the slash-command
message — the same provenance requirement as the Job/Run detail view below,
so a shadowed skill is never a silent debugging trap in chat either.

## Provenance on the Job/Run detail view

Once a skill Job runs, the Run detail view shows which tier actually
resolved (`skill_source`) and the resolved path/class — the same provenance
data surfaced pre-launch in the picker, so a shadowed skill remains
debuggable after the fact too. See `Admin::JobStateSerializer` and
`app/services/app/job_detail_payload/workflow_serializers.rb`.
