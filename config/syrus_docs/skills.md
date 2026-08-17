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

## Provenance on the Job/Run detail view

Once a skill Job runs, the Run detail view shows which tier actually
resolved (`skill_source`) and the resolved path/class — the same provenance
data surfaced pre-launch in the picker, so a shadowed skill remains
debuggable after the fact too. See `Admin::JobStateSerializer` and
`app/services/app/job_detail_payload/workflow_serializers.rb`.
