# Delivery Tracks

Delivery tracks let a repository declare its own branching model — a single strict branch, a development/release split, a hotfix track, or an upstream-export posture for forks — in a shared, non-personal `.syrus.yml` block, instead of every workflow special-casing branch names. See `docs/plans/delivery-tracks-and-promotion.md` for the full design and Story-by-Story rationale; this document tracks only what's actually implemented.

This is the first Job in EPIC-268 (Delivery Tracks, Promotion, and Branch Policy): it adds the `.syrus.yml` parser and the `DeliveryPolicy` object described below. **Nothing in the runtime calls `DeliveryPolicy` yet** — no workflow, landing path, or grader selection reads it. Later Jobs in the Epic wire it into job PR opening, landing, and grading.

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
policy.job_delivery_track(job)          # => "default" — Job has no delivery_track column yet, so this always resolves to "default"
policy.review_grade_phase(job)
policy.landing_grade_phase(job)
policy.branch_health_grade_phase(branch)  # matches branch against configured track branches, falling back to the default track
policy.promotion_enabled?
policy.promotion_mode
policy.hotfix_sync_enabled?
policy.hotfix_sync_mode
```

`Job` has no `delivery_track` column yet — that's a later Job in EPIC-268 (Delivery Tracks, Promotion, and Branch Policy). Until it lands, `job_delivery_track` and every job-scoped method above always resolve against the config's `default` track regardless of which job is passed.
