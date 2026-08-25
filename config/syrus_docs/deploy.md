# Deploy

Deploy lets a repository configure a shell command Syrus can run to actually deploy the target application — not a preview, a real deployment. It is modeled as a first-class Workflow (`trigger_kind: "deploy"`) rather than a bespoke side-model, so it gets retry-from-failed-step, Run transcripts, the admin repair toolkit, and `WorkflowWorkspacePruneJob` cleanup for free.

## Configuration

`deploy:` in the target repository's `.syrus.yml`:

```yaml
deploy:
  mode: manual              # or continuous — default manual
  run: "bin/deploy"         # required
  allow_unapproved: false   # default false
  min_interval_minutes: 15  # optional, continuous-only
```

| Field | Required | Default | Notes |
|---|---|---|---|
| `run` | yes | — | Shell command that performs the deploy |
| `mode` | no | `manual` | `manual` or `continuous` |
| `allow_unapproved` | no | `false` | Allow deploying a Job that hasn't been approved |
| `min_interval_minutes` | no | — | Positive integer; throttles auto-triggered deploys in `continuous` mode only |

Omitting `deploy:` disables the feature for the repository — the same safe default `formatters:`/`generated:` use. See [`syrus_yml.md`](syrus_yml.md#deploy) for how this fits alongside the rest of the `.syrus.yml` schema, including why it is independent of `deployment_stages`' read-only tag tracking.

`deploy:` is parsed by `SyrusYml` (`app/services/syrus_yml.rb`) into a `SyrusYml::DeployConfig`.

## The `deploy` Workflow

`Workflows::Deploy` (`app/services/workflows/deploy.rb`) declares a short, entirely non-agentic chain:

```
prepare → deploy
```

`prepare` is the same deterministic setup step every other chain uses — it runs `.syrus.yml`'s `prepare:` commands (or auto-detects) so the deploy command runs against an installed workspace. `deploy` (`Steps::Deploy`, `app/services/steps/deploy.rb`) then runs `.syrus.yml`'s `deploy.run` command.

`Steps::Deploy` follows `Steps::Prepare#run_shell`'s idiom: streamed output buffered into `JobLog`, a per-command timeout, and a `kind: "deploy"` tag on the underlying `ProcessRunner` call so deploy subprocesses show up in `/admin/processes` like every other spawned subprocess (`SpawnedProcess::KINDS`).

Unlike `prepare`, there is no auto-detected fallback for a deploy command — there's nothing sensible to guess. A missing `.syrus.yml`, an absent `deploy:` block, an unparsable config, or a failing `run` command are all hard failures: the step raises `StepFailed` and the Workflow fails, the same as any other required step. Repair semantics default to `:operator_review` (the non-agentic default), not `:deterministic_idempotent` — a deploy command isn't guaranteed safe to blindly auto-retry the way `prepare`/`format`/grader commands are, so a failure surfaces for an operator to look at rather than auto-retrying.

`WorkDefinitions::BuiltIns::Deploy` (`app/services/work_definitions/built_ins.rb`) registers the matching `WorkDefinition` (`kind: "deploy"`, `workflow_trigger_kind: "deploy"`, `scope: "job"`) so the `deploy` trigger_kind participates in the standard retry/lock/landing policy machinery like every other first-class Workflow.

## Redeploying a closed Job

GitHub deletes a PR's branch shortly after merge, so `WorkflowWorkspace` (which normally clones and checks out `job.branch_name`) cannot set up a workspace for a `deploy` Workflow on an already-landed Job by branch name alone. `WorkflowWorkspace` special-cases this: when the target Job is `closed?` with `landed_sha` present **and** the Workflow's `trigger_kind` is `"deploy"`, it clones the repository's default branch (always present, non-shallow) and checks out `job.landed_sha` directly instead of fetching or creating a branch — the same fix `PreviewWorkspace`'s `:commit_sha` revision mode already applies for post-land previews. This fallback is scoped narrowly to `deploy` Workflows; every other trigger_kind still targets an open/approved Job with a live branch and is unaffected.

A `deploy` Workflow launched on a Job that hasn't landed yet (still open, with a live branch) is unaffected by this fallback and clones/checks out `job.branch_name` as normal.

## Manually triggering a deploy

A Job's detail page shows a **Deploy** control next to **Preview**, inside the same panel (`PreviewPanel.tsx`, `DeployControls`). It is visible whenever the repository has a `deploy:` block configured (`App::DeployAvailability.configured?`) and the Job is `deployable?` — `implemented`, `approved`, `landing`, or `closed` with a `landed_sha` (the same "resolvable revision" shape `previewable?` uses; see "Redeploying a closed Job" above for how the closed case checks out the right commit). Clicking it shows the latest deploy Workflow's state (queued/running/succeeded/failed/cancelled) and links to it in the Workflows tab; it polls while a deploy is in flight the same way the Preview control polls its own environment, since a Workflow's own state-change events only refresh the Workflows tab's query, not this panel.

The same action is available over the API: `POST /api/v1/app/jobs/:job_id/deploy` launches a `deploy` Workflow via `WorkUnits::Launcher.instantiate(kind: "deploy", job:)` + `.start!` (`Api::V1::App::JobDeployController#create`); `GET /api/v1/app/jobs/:job_id/deploy` returns the latest deploy Workflow's status. `Job#deployable?` gates both: a Job with no resolvable revision (still triaging, queued, running, coding, or closed without a `landed_sha`) is rejected with `422 validation_failed`.

### Approval gate

Deploying an unapproved Job is forbidden by default — `403 forbidden` unless the Job is `approved?` or the repository's `.syrus.yml` sets `deploy.allow_unapproved: true` (checked via `App::DeployAvailability.allow_unapproved?`, which reads the same bare-clone `.syrus.yml` copy `configured?` uses). This is separate authorization logic from Preview, which has no approval gate at all — previewing an implemented-but-unapproved Job is fine, since it doesn't touch anything outside Syrus's own preview infrastructure; deploying does, so it defaults to approved-only.

Only one deploy Workflow may be queued or running per Job at a time — a second `POST` while one is active returns `409 conflict` rather than piling deploys up behind Solid Queue's per-Job concurrency limit.

## Continuous deploy

Not yet built (tracked as follow-up work under the same Epic): the continuous-deploy auto-trigger (an `after_success` hook on landing Workflows, concurrency-limited to one in-flight deploy per repository and throttled by `min_interval_minutes`). `deploy.mode: continuous` is parsed and stored today but has no effect yet — until that trigger lands, every deploy is manual regardless of `mode`.
