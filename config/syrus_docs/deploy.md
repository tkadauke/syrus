# Deploy

Deploy lets a repository configure a shell command Syrus can run to actually deploy the target application — not a preview, a real deployment. It is modeled as a first-class Workflow (`trigger_kind: "deploy"`) rather than a bespoke side-model, so it gets retry-from-failed-step, Run transcripts, the admin repair toolkit, and workspace cleanup for free.

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

## The `deploy` Workflow

The `deploy` Workflow is a short, entirely non-agentic chain:

```
prepare → deploy
```

`prepare` is the same deterministic setup step every other chain uses — it runs `.syrus.yml`'s `prepare:` commands (or auto-detects) so the deploy command runs against an installed workspace. `deploy` then runs `.syrus.yml`'s `deploy.run` command.

Like `prepare`, the deploy step streams output into the Job log, applies a per-command timeout, and tags its subprocess so it shows up in `/admin/processes` like every other spawned subprocess.

Unlike `prepare`, there is no auto-detected fallback for a deploy command — there's nothing sensible to guess. A missing `.syrus.yml`, an absent `deploy:` block, an unparsable config, or a failing `run` command are all hard failures: the step fails and the Workflow fails, the same as any other required step. Repair semantics default to `:operator_review` (the non-agentic default), not `:deterministic_idempotent` — a deploy command isn't guaranteed safe to blindly auto-retry the way `prepare`/`format`/grader commands are, so a failure surfaces for an operator to look at rather than auto-retrying.

The `deploy` trigger kind participates in the standard retry/lock/landing policy machinery like every other first-class Workflow.

## Redeploying a closed Job

GitHub deletes a PR's branch shortly after merge, so the workflow workspace (which normally clones and checks out the Job's branch) cannot set up a workspace for a `deploy` Workflow on an already-landed Job by branch name alone. Syrus special-cases this: when the target Job is closed with a landed commit **and** the Workflow's trigger kind is `deploy`, it clones the repository's default branch and checks out the landed commit directly instead of fetching or creating a branch — the same approach post-land previews use. This fallback is scoped narrowly to `deploy` Workflows; every other trigger_kind still targets an open/approved Job with a live branch and is unaffected.

A `deploy` Workflow launched on a Job that hasn't landed yet (still open, with a live branch) is unaffected by this fallback and clones/checks out the Job's branch as normal.

## Manually triggering a deploy

A Job's detail page shows a **Deploy** control next to **Preview**, inside the same panel. It is visible whenever the repository has a `deploy:` block configured and the Job is deployable — `implemented`, `approved`, `landing`, or `closed` with a `landed_sha` (the same "resolvable revision" shape `previewable?` uses; see "Redeploying a closed Job" above for how the closed case checks out the right commit). Clicking it shows the latest deploy Workflow's state (queued/running/succeeded/failed/cancelled) and links to it in the Workflows tab; it polls while a deploy is in flight the same way the Preview control polls its own environment, since a Workflow's own state-change events only refresh the Workflows tab's query, not this panel.

The same action is available over the API: `POST /api/v1/app/jobs/:job_id/deploy` launches a `deploy` Workflow; `GET /api/v1/app/jobs/:job_id/deploy` returns the latest deploy Workflow's status. The same deployability check gates both: a Job with no resolvable revision (still triaging, queued, running, coding, or closed without a `landed_sha`) is rejected with `422 validation_failed`.

### Approval gate

Deploying an unapproved Job is forbidden by default — `403 forbidden` unless the Job is `approved?` or the repository's `.syrus.yml` sets `deploy.allow_unapproved: true` (read from the default branch's `.syrus.yml`). This is separate authorization logic from Preview, which has no approval gate at all — previewing an implemented-but-unapproved Job is fine, since it doesn't touch anything outside Syrus's own preview infrastructure; deploying does, so it defaults to approved-only.

Only one deploy Workflow may be queued or running per Job at a time — a second `POST` while one is active returns `409 conflict` rather than piling deploys up behind Solid Queue's per-Job concurrency limit.

## Continuous deploy

Setting `deploy.mode: continuous` auto-triggers a deploy of the repository's default-branch HEAD every time a Job lands, without any manual click. It reuses the debounce pattern main-branch health checks use.

### Trigger point

Auto-merge, the merge train, and external-PR merges each trigger the continuous-deploy check once a Job (or, for a merge train, an Epic's children) has actually landed on the default branch. The check re-reads the repository's `.syrus.yml` and, only when `deploy.mode == "continuous"`, enqueues a deploy-admission job. A repository without `deploy:` configured, or with `mode: manual` (the default), never enqueues anything — landing a Job costs nothing extra unless continuous deploy is opted into.

### Deploy admission

The admission job does the actual gating, mirroring main-branch health-check debouncing:

- Admission checks for one repository are serialized, so only one runs at a time. This covers only the (fast) admission check, not the deploy Workflow's runtime.
- **Concurrency guard**: if a deploy Workflow is already `queued` or `running` for the repository, this run is a no-op. It does not reschedule — a fresh trigger is not needed here because every subsequent landing independently triggers the check again, and by the time a later merge lands (if one does), the earlier deploy has typically already settled.
- **Throttle guard**: if `deploy.min_interval_minutes` is configured and less time has elapsed since the most recent deploy Workflow finished for this repository than that interval, the trigger is **rescheduled** for the earliest allowed time — never silently dropped. A burst of merges inside the throttle window therefore produces exactly one deploy of the latest HEAD once the window opens: the check that runs at that instant resolves the default branch's *current* HEAD, so any commits that landed in between are included.
- **Launch**: otherwise, admission creates a synthetic anchor Job (kind `deploy`, no issue number — the same shape as the main-branch health-check anchor Job), resolves the default branch's current HEAD sha, and launches the `deploy` Workflow pinned to that sha. The workspace detaches HEAD at that exact commit, so the deploy command runs against the resolved commit even if the default branch advances again before the workspace clones.
- **Anchor Job closure**: the anchor Job is closed when the deploy Workflow finishes, regardless of outcome, since the pass/fail detail lives on the Workflow/Run, not the Job. A manual deploy's ordinary Job is never closed this way. Like main-branch health-check anchor Jobs, the anchor Job is hidden from the operator dashboard and other Job pickers.

A manually-triggered deploy (see above) is unaffected by any of this — it always targets the ordinary Job it was launched on and is never subject to the concurrency/throttle checks here, which only gate the synthetic continuous-deploy anchor Job.


For Syrus maintainer rollout procedures, see
[`deploying-syrus.md`](../../docs/engineering/operations/deploying-syrus.md).

# Server and user time zones

`SYRUS_TIME_ZONE` selects the server's IANA time zone. Boot resolution is an
explicit `SYRUS_TIME_ZONE`, then a valid process `TZ`, then `Etc/UTC`. An
invalid explicit value aborts boot with a configuration error; an invalid
ambient `TZ` is ignored. Set the variable consistently for local/macOS launch
agents, Docker Compose, every k3s/Kubernetes process, and generic cloud process
groups. Never infer it from a host, cluster, IP address, or cloud region.

Rails calendar operations use the resolved server zone. Active Record and all
MySQL sessions continue storing instants in UTC. Each user separately has an
IANA zone and an `automatic` or `manual` mode. Authenticated browsers report
`Intl.DateTimeFormat().resolvedOptions().timeZone`; reports update automatic
users as they travel and never move manual overrides. This state is independent
from approval-delivery quiet hours, whose existing zone and behavior are not
changed. Admin Overview shows process `TZ`, the Rails zone, resolution source,
and database UTC policy separately.

Calendar-relative UI (including chat day dividers and date groups) uses the
user zone; elapsed durations still compare UTC instants. Operational absolute
times such as schedules and wakeups show one zoned value when the user and
server zones match, or explicitly labeled user and server values when they
differ. The underlying HTML `time` value remains an ISO-8601 instant.

Interactive chat agents receive one captured instant rendered in UTC, the
server zone, and the user's zone (with identical zones collapsed). Relative
calendar language defaults to the user zone. Recurring schedules continue to
use their stored zone, while newly created schedules default to the server
zone unless the operator names another one. Ordinary workflow workers do not
receive this interactive time context. User-facing spending date filters,
daily buckets, coworker daily memory, and journaling boundaries use the user's
zone; persisted instants and database sessions remain UTC.
