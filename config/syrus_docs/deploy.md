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

Setting `deploy.mode: continuous` auto-triggers a deploy of the repository's default-branch HEAD every time a Job lands, without any manual click. It reuses the exact debounce pattern `Workflows::MainGrader`/`MainGraderWorkflowJob` already use for main-branch health checks.

### Trigger point

`Workflows::AutoMerge`, `Workflows::MergeTrain`, and `Workflows::ExternalPrMerge` each call `DeployContinuousTrigger.after_landing!(repository)` from their `after_success` hook — i.e. once a Job (or, for a merge train, an Epic's children) has actually landed on the default branch. `DeployContinuousTrigger` re-reads the repository's `.syrus.yml` (the same bare-clone read `App::DeployAvailability` uses for the manual-deploy gate) and, only when `deploy.mode == "continuous"`, enqueues `MaybeDeployJob.perform_later(repository_id)`. A repository without `deploy:` configured, or with `mode: manual` (the default), never enqueues anything here — landing a Job costs nothing extra unless continuous deploy is opted into.

### `MaybeDeployJob`

`MaybeDeployJob` (`queue_as :control_plane`) does the actual gating, mirroring `MainGraderWorkflowJob`:

- `limits_concurrency to: 1, key: "deploy:<repository_id>"` bounds how many `MaybeDeployJob` executions for one repository can be in flight at once — this only serializes the (fast) admission check itself, not the deploy Workflow's runtime.
- **Concurrency guard**: if a `deploy`-trigger_kind Workflow is already `queued` or `running` for the repository, this run is a no-op. It does not reschedule — a fresh trigger is not needed here because every subsequent landing independently calls the trigger point again, and by the time a later merge lands (if one does), the earlier deploy has typically already settled.
- **Throttle guard**: if `deploy.min_interval_minutes` is configured and less time has elapsed since the most recent `deploy`-trigger_kind Workflow's `finished_at` for this repository than that interval, the trigger is **rescheduled** (`MaybeDeployJob.set(wait_until: ...).perform_later(repository_id)`) for the earliest allowed time — never silently dropped. This is what turns a burst of merges landing inside the throttle window into exactly one deploy of the latest HEAD once the window opens: each merge's trigger either launches the deploy or reschedules for the same "earliest allowed" instant, and whichever check actually runs at that instant resolves the default branch's *current* HEAD, not a HEAD captured at trigger time — so any commits that landed in between are included for free, with no explicit commit-batching data structure.
- **Launch**: otherwise, `MaybeDeployJob` creates a synthetic anchor `Job` (`kind: "deploy"`, no `issue_number` — same shape as the `main_grader` anchor Job), resolves the repository's current default-branch HEAD sha via `GithubClient#branch_head_sha`, and launches `Workflows::Deploy` on it through `WorkUnits::Launcher.instantiate(kind: "deploy", job:, artifacts: { "deploy_sha" => sha })` + `.start!`. `WorkflowWorkspace` clones the default branch and detaches HEAD at that exact `deploy_sha` (the same `checkout_main_sha!`-style pinning `main_grader` Workflows use), so the deploy command runs against the resolved commit even if the default branch advances again before the workspace clones.
- **Anchor Job closure**: `Workflows::Deploy#after_success`/`#after_fail` close the anchor Job (`job.deploy_job?` is true only for this synthetic Job, never for a manual deploy's ordinary Job) the same way `Workflows::MainGrader.close_anchor_job!` closes its own anchor Job — regardless of whether the deploy succeeded, since the pass/fail detail lives on the Workflow/Run, not the Job. The anchor Job is filtered out of the operator dashboard and other Job pickers the same way `main_grader` Jobs already are (`Filters::Chips::Jobs::JobType::SYSTEM_KINDS`, chat attachment search, agent-insight's recent-Job sampling).

A manually-triggered deploy (see above) is unaffected by any of this — it always targets the ordinary Job it was launched on and is never subject to the concurrency/throttle checks here, which only gate the synthetic continuous-deploy anchor Job.
