# Delivery Tracks

Delivery tracks let a repository declare its own branching model — a single strict branch, a development/release split, a hotfix track, or an upstream-export posture for forks — in a shared, non-personal `.syrus.yml` block, instead of every workflow special-casing branch names. See `docs/plans/delivery-tracks-and-promotion.md` for the full design and Story-by-Story rationale; this document tracks only what's actually implemented.

This started as the first Job in EPIC-268 (Delivery Tracks, Promotion, and Branch Policy), adding the `.syrus.yml` parser and the `DeliveryPolicy` object described below; a follow-up Job added the `approval:` block (Story 7: owner + peer local approval, optional promotion maintainer approval); a third Job added the `Job#delivery_track` column and wired `DeliveryPolicy#job_landing_branch` into PR base-branch resolution (see "`Job#delivery_track`" below) — that's the only runtime caller so far. Grader/landing-phase selection based on `review_grade_phase`/`landing_grade_phase` is still unwired; later Jobs in the Epic cover that.

## `.syrus.yml` shape

`delivery:` is optional, the same safe-default posture as `formatters:`/`generated:`/`deploy:` — omitting it keeps a repository's current behavior unchanged.

```yaml
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review_minimal
        landing: landing_minimal
      after_landing:
        sync_to: default   # optional; another track name to sync into after landing

    hotfix:
      branch: main
      grade_phases:
        review: review_minimal
        landing: promotion

  promotion:
    enabled: true
    mode: auto_pr          # direct, auto_pr, manual_pr — default auto_pr
    approval_required: false
    grade_phases: [promotion]
    repair_skill: integrate_release_branch

  hotfix_sync:
    enabled: true
    direction: release_to_development   # only supported value for now
    mode: auto              # auto, auto_pr, manual_pr — default auto
    grade_phases: [promotion]
    repair_skill: backport_release_hotfix

  upstream_export:
    enabled: true
    mode: per_job_pr        # per_job_pr, branch_pr — default per_job_pr
    after_local_approval: true
    target: upstream_intake

  ref_movement_actions:
    send_job_upstream:
      enabled: true
      source: { kind: job_branch }
      target: { kind: upstream_intake }
      mode: manual_pr        # direct, auto_pr, manual_pr
      grade_phases: [promotion]
```

Every sub-block (`tracks`, `promotion`, `hotfix_sync`, `upstream_export`, `ref_movement_actions`) is independently optional within an explicit `delivery:` mapping. If `tracks:` is given at all, it must include a `default` entry — that's the track existing workflows fall back to until a Job can select one explicitly.

### Backward-compatible default

When `.syrus.yml` has no `delivery:` section (or omits a sub-block), `SyrusYml` normalizes it to:

- one `default` track with no explicit branch (resolved to `Repository#default_branch` — see below), `review`/`landing`/`ci_failure`/`branch_health` grade phases of `review`/`landing`/`ci`/`ci`;
- `promotion`, `hotfix_sync`, and `upstream_export` all disabled;
- `ref_movement_actions: {}`.

This is exactly today's behavior expressed as delivery config, so a repository with no `delivery:` block is unaffected.

### Grade phase names are free-form here

Unlike `grade.steps[].phases` (still restricted to `review`/`landing`/`ci`), the `grade_phases` fields inside `delivery:` (per-track `review`/`landing`/`ci_failure`/`branch_health`, plus `promotion.grade_phases`/`hotfix_sync.grade_phases`/`ref_movement_actions.*.grade_phases`) accept arbitrary phase name strings — `review_minimal`, `promotion`, `branch_health`, or anything else a repository's `grade.steps[].phases` chooses to name. Wiring those custom phase names into actual grader selection is a later Job in this Epic; today they're parsed and stored, not consumed anywhere.

## `SyrusYml::Config#delivery` and `#raw_delivery`

`SyrusYml` (`app/services/syrus_yml.rb`) parses `delivery:` into two fields on `Config`:

- `raw_delivery` — exactly what `.syrus.yml` declared, `nil` when the `delivery:` key is absent. Kept for display/debugging so an operator can see the repository's literal config, not the defaulted one.
- `delivery` — always present, normalized per the backward-compatible defaults above, so runtime code never has to branch on "missing delivery block."

One thing normalization can't do inside `SyrusYml`: resolve a track's blank `branch` to the repository's default branch, because `SyrusYml` only ever sees file content, never a `Repository` record. A blank `DeliveryTrack#branch` means "use `Repository#default_branch`," resolved by `DeliveryPolicy` below.

## `DeliveryPolicy`

`DeliveryPolicy` (`app/services/delivery_policy.rb`) answers delivery questions for a repository/job by reading the repository's local bare clone (`RepositoryBareClone.path_for`) the same way `App::DeployAvailability`/`App::PreviewAvailability` read `.syrus.yml` off `HEAD` without a live workspace — no bare clone yet, or an unparsable `.syrus.yml`, both fall back to the backward-compatible default instead of raising.

```ruby
policy = DeliveryPolicy.for(repository:, job: nil)

policy.job_landing_branch(job)          # => "develop", or repository.default_branch if the track has no explicit branch
policy.job_delivery_track(job)          # => "hotfix" when job.delivery_track == "hotfix" and a "hotfix" track is configured; else "default"
policy.review_grade_phase(job)
policy.landing_grade_phase(job)
policy.branch_health_grade_phase(branch)  # matches branch against configured track branches, falling back to the default track
policy.promotion_enabled?
policy.promotion_mode
policy.hotfix_sync_enabled?
policy.hotfix_sync_mode
```

## `Job#delivery_track`

`Job#delivery_track` is a plain nullable string column — like `target_branch`, it carries no enum/validation, because valid track names are repository-configured (`delivery.tracks` keys), not a fixed set. `nil` means "use the policy default" (`DeliveryPolicy#track_for` resolves a blank or unrecognized track name to the config's `default` track), so every existing Job is unaffected until something explicitly sets it.

Track selection is exposed at every surface that creates a Job:

- **Direct job API** (`Api::V1::App::DirectJobsController#create`) and **admin job creation** (`Api::V1::Admin::JobsController#create`) both accept an optional `delivery_track` param, persisted as-is (trimmed, blank -> `nil`).
- **Issue ingestion** (`PollRepositoryJob`) reads a `syrus-track-<name>` label off the GitHub issue — e.g. `syrus-track-hotfix` sets `delivery_track: "hotfix"` — via `Workflows.track_label_value`, the same label-based convention `SKIP_PREPARE_LABEL` uses. Removing/changing the label on a later poll resyncs the column on the existing Job, mirroring `skip_prepare`'s resync behavior.
- **Skills that file jobs** (`SkillJobs::Creator`, and the `Api::V1::App::SkillsController#create` surface backing it) accept an optional `delivery_track:` kwarg/param, passed straight through to the created Job.

None of these surfaces validate the value against the repository's configured track names — an unrecognized or unconfigured name (e.g. `delivery_track: "hotfix"` on a repository with no `hotfix` track) just resolves to the `default` track at read time via `DeliveryPolicy#track_for`, the same graceful-fallback posture the rest of this policy already has for a missing/unparsable `.syrus.yml`. A repository that defines a `hotfix` track (per the `.syrus.yml` shape above) makes `hotfix` a live selectable track the moment a Job sets `delivery_track: "hotfix"` — no separate opt-in is required beyond configuring the track.

`JobStackBase#effective_base_branch` (`app/models/concerns/job_stack_base.rb`) is the first runtime caller: once its `target_branch` override, `stack_base: main` override, and open stack/dependency parent checks are all exhausted, its final fallback calls `DeliveryPolicy.for(repository: base_repository).job_landing_branch(job)` instead of `base_default_branch` directly. `target_branch` is not removed and still short-circuits first — it remains the explicit, unconditional per-Job branch override; `delivery_track` only applies once every other resolution path has nothing to say. Because `effective_base_branch` feeds PR base-branch resolution (`PullRequestOpener`), rebase targeting, and workspace checkout across the codebase, this one change point is what actually lands a track-selected Job against its track's branch.

## `approval:` block (Story 7: owner + peer local approval)

`approval:` is optional and independent of `delivery:` — a repository can configure one, both, or neither. Omitting it entirely means "use current approval behavior" (the repository's existing `review_policy` — `self`/`two_person`/`final_say`, see `ReviewPolicies`), not some new default.

```yaml
approval:
  job:
    required:
      owner: true       # bool — default true when approval.job is configured but omits this key
      peer_count: 1      # int — default 0 when omitted

  promotion:
    required:
      maintainer_count: 1   # int; only meaningful via DeliveryPolicy#requires_operator_approval_for_promotion?
```

`SyrusYml::Config#approval` is `nil` when the `approval:` key is absent — unlike `delivery`, there is no always-present normalized shape, because "absent" is itself the fallback signal. When present, `approval.job` and `approval.promotion` are each independently optional and default to `nil` when their own key is missing.

A peer approval only counts toward `peer_count` when that peer has repository access on this Syrus instance — a `RepositoryMembership` row for that user on the repository (any role). An approval from a user who has since lost access doesn't count, mirroring the collaborator-access check `ChatAttachment` already uses.

`DeliveryPolicy` exposes two additional methods built from this config:

```ruby
policy.job_approval_satisfied?(job)
# No approval.job block at all -> job.approval_satisfied? (existing ReviewPolicies::REGISTRY lookup by repository.review_policy)
# approval.job configured        -> owner approval (if required) AND at least peer_count eligible peer approvals

policy.requires_operator_approval_for_promotion?
# approval.promotion.required.maintainer_count present -> true when > 0
# approval.promotion absent                             -> falls back to delivery.promotion.approval_required
```

Neither method is wired into any actual landing/approval gate yet — that happens in a later EPIC-268 Job (`landing-queue-track-approval-gating`).
