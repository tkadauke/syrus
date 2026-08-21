# Epicless Job Bundling (experimental)

Epicless Job bundling lets multiple approved Jobs that don't belong to an
Epic land together as one atomic landing unit, the same way an Epic's
children already land together via the merge train (see
[`merge_train.md`](merge_train.md)). It reuses the merge-train machinery
end to end — `MergeTrain`/`MergeTrainMember`, the
`merge_train_assemble → merge_train_build → merge_train_reconcile → prepare →
retry_until(graders, repair: landing_fix) → merge_train_land` step chain,
and `MergeTrainFailureHandler` — rather than a parallel model or workflow.

A `MergeTrain` row is either **epic-backed** (`epic_id` present) or
**bundle-backed** (`priority` present); a model validation
(`MergeTrain#epic_or_priority_but_not_both`) rejects both or neither being
set. Everything downstream of assembly — build, reconcile, grade, land,
failure handling — is unit-agnostic and does not need to know which kind
of train it's running.

## Feature flag

Epicless Job bundling is gated by the `epicless_job_bundling` Labs feature
flag (`config/features.yml`), off by default:

```ruby
Feature.find_by(slug: "epicless_job_bundling").update(enabled: true)
```

Unlike `merge_train_enabled` (an `AppSetting`, effectively an operations
switch once turned on instance-wide), this is a per-instance experimental
toggle in the same family as `visual_review` or `landing_validation_prefetch` —
operators opt in from Admin → Features.

## Assembly (`JobBundleAssembler`)

`JobBundleAssembler.call(repository)` looks for a ready bundle, trying each
`Job::PRIORITIES` tier in order (`urgent` first) and returning as soon as one
tier has enough candidates:

- **Epicless only** — candidates are `epic_id: nil`.
- **Own-PR only** — `kind: "external_pr"` Jobs are excluded. Externally
  filed PRs land via `external_pr_merge` against the GitHub PR directly;
  they have no Syrus-owned branch for `merge_train_build` to rebase, so
  they are never bundle-eligible, the same way they're excluded from Epic
  merge trains.
- **Priority-homogeneous** — candidates for a given bundle all share one
  `Job#priority` tier. An urgent Job never lands in the same integration
  branch as a medium/low-priority Job; multiple urgent Jobs can bundle
  together with each other, satisfying "urgent goes first" without ever
  mixing tiers. This generalizes the same single-Job urgent-preemption
  check Epic merge trains use
  (`LandingQueueProcessor#unrelated_urgent_job_active_for_repository?`)
  from "is one urgent Job active" to "does the active landing unit contain
  an urgent member."
- **Minimum bundle size is 2** (`JobBundleAssembler::MIN_BUNDLE_SIZE`). A
  single ready epicless Job — urgent or not — falls through to the
  existing per-Job `auto_merge` path instead of spinning up a
  merge-train-style pipeline for one member. `LandingQueueProcessor` only
  routes a Job to `JobBundleDispatcher` once
  `bundle_eligible_epicless_job?` finds at least `MIN_BUNDLE_SIZE`
  same-tier, epicless, own-PR approved siblings for the repository.
- **Dependency ordering and size cap** — candidates are topologically
  ordered by `LandingQueueProcessor.dependency_ordered` the same way Epic
  members are, then capped at `AppSetting.merge_train_max_size`, shrinking
  the cut so a resolved `JobDependency` pair is never split across the cap
  boundary.

`JobBundleAssembler` is a pure query with no side effects; the flag check
lives in its caller, `JobBundleDispatcher`.

## Dispatch (`JobBundleDispatcher`)

`JobBundleDispatcher.try_dispatch!(repository)` mirrors
`MergeTrainDispatcher`'s transactional locking pattern
(app/services/merge_train_dispatcher.rb): it locks the assembled members,
verifies no other Job is already `landing` for the repository and no
rebase workflow is active for any member, then creates the `MergeTrain`
(`epic: nil`, `priority: <tier>`) and its `MergeTrainMember` rows, moves
every member into `:landing`, and dispatches a `merge_train` Workflow on
the last member with `merge_train_id` recorded as a workflow artifact —
the same artifact key `Workflows::MergeTrain.after_fail`/`after_cancel` and
`MergeTrainFailureHandler` read to find the train, regardless of whether it
is epic- or bundle-backed.

Only one landing unit — Epic train, Job bundle, or solo Job — occupies a
repository's landing slot at a time (`Job.landing.where(repository_id:)`).
An active Epic-backed train and an active Job bundle in the same repository
never race each other for that reason; `JobBundleDispatcher` only checks for
another active *bundle* (`epic_id: nil`) directly and otherwise relies on
the shared single-landing-slot check.

## Failure handling

`Workflows::MergeTrain.after_fail`/`after_cancel` call
`MergeTrainFailureHandler.call(workflow:)` exactly as they do for Epic
trains — the handler is already epic-agnostic: it resolves the train from
`workflow.artifact("merge_train_id")`, classifies the failure reason, and
routes each member through `LandingFailureHandler`:

- A genuine failure fails the member Jobs back to `:implemented`, requiring
  operator re-approval.
- A transient/infrastructure blocker, a stale-base rebuild requirement, or a
  transient landing-start blocker defers the member Jobs back to `:approved`
  so they re-enter the landing queue automatically.

`JobBundleDispatcher::RETRY_COOLDOWN` is the same constant as
`MergeTrainDispatcher::RETRY_COOLDOWN` (30 minutes) and is applied the same
way: after a bundle fails, `JobBundleDispatcher.blocker_reason` blocks
re-dispatching a bundle for that repository until the cooldown elapses,
so a genuinely stuck group of Jobs surfaces for an operator instead of
churning the landing queue every tick. Like the Epic-backed dispatcher, the
cooldown excludes transient landing-start-blocker and stale-base rebuild
failures (`LandingQueueReentry.landing_start_blocker?`,
`LandingFailureHandler.merge_train_rebuild_required?`) — those aren't
"genuinely stuck" bundles, so Syrus can retry as soon as the underlying
blocker clears rather than waiting out the full cooldown. Operators (or
automation) can pass `bypass_cooldown: true` to force an explicit rebuild.

## Accepted tradeoff: unvalidated intermediate commits

Same tradeoff as the existing Epic merge train: only the final integrated
tip that lands is validated by graders. Intermediate commits inside the
integration branch — one per rebased member, plus any `merge_train_reconcile`
fix — may not individually pass graders. What actually lands should
typically not be broken, but the branch's history may contain states that
were never independently graded.

## Speculative landing prefetch

`LandingValidationPrefetcher` generalizes to epicless bundle candidates the
same way it already does for Epic units: once a repository has enough
same-tier approved candidates to be bundle-eligible,
`LandingQueueProcessor.bundle_eligible_epicless_job?` routes speculative
validation the same way it routes Epic children, and cache entries are keyed
so a bundle's speculative validation is never conflated with an Epic train's
for the same repository/base. See
[`landing_queue.md`](landing_queue.md#speculative-landing-validation).

## Dashboard visualization

`Job#landing_queue_entry_key` returns `"job_bundle:<merge_train_id>"` for a
Job whose bundle has already been dispatched, the same way it returns
`"epic:<id>"` for Epic children. The landing queue dashboard
(`app/frontend/routes/dashboard/JobsTable.tsx`) uses this key to draw group
separators and attribution the same way it already does for Epics —
`epicGroupKey`/`isMultiJobGroupKey`/`isMultiJobLandingUnitKey` treat
`job_bundle:` keys as a multi-job landing unit boundary, distinct from
consecutive standalone (unbundled) epicless Jobs, which do not get a
separator between them.

## Which workflow chain runs

Bundle-backed trains run the exact same `Workflows::MergeTrain` chain as
Epic-backed trains: `merge_train_assemble → merge_train_build →
merge_train_reconcile → prepare → retry_until(graders, repair: landing_fix)
→ merge_train_land` (plus the base-moved rebase recovery branch). See
[`merge_train.md`](merge_train.md) for the full phase-by-phase description —
everything there about build, reconciliation, grading, and land applies
unchanged to epicless bundles.
