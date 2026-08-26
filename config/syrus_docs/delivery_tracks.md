# Delivery Tracks

Delivery tracks let a repository declare its own branching model — a single strict branch, a development/release split, a hotfix track, or an upstream-export posture for forks — in a shared, non-personal `.syrus.yml` block, instead of every workflow special-casing branch names. See `docs/plans/delivery-tracks-and-promotion.md` for the full design and Story-by-Story rationale; this document tracks only what's actually implemented.

This started as the first Job in EPIC-268 (Delivery Tracks, Promotion, and Branch Policy), adding the `.syrus.yml` parser and the `DeliveryPolicy` object described below; a follow-up Job added the `approval:` block (Story 7: owner + peer local approval, optional promotion maintainer approval); a third Job added the `Job#delivery_track` column and wired `DeliveryPolicy#job_landing_branch` into PR base-branch resolution (see "`Job#delivery_track`" below); a fourth Job (`landing-queue-track-approval-gating`) generalized the landing queue's per-slot lock and in-progress checks to key off `job_landing_branch` instead of bare `repository_id`, and wired `job_approval_satisfied?` into the landing approval gate (see "Landing queue integration" below); a fifth Job added the `JobPrLink` model (see "`JobPrLink`" below) as the durable foundation the promotion/hotfix-sync/upstream-export Jobs later in this Epic persist their PR links to; a sixth Job added `DeliveryStatus` (see "`DeliveryStatus` (apparent delivery status)" below), the first reader of `JobPrLink`, deriving a Job's UI-facing delivery status from delivery facts instead of a new AASM state; a seventh Job added `Workflows::Promotion` (see "Promotion workflow" below), the first ref-movement workflow and the first consumer of the `promotion` grade phase; an eighth Job added `Workflows::HotfixSync` and its detection poller (see "Hotfix sync workflow" below), the reverse `main -> develop` ref-movement workflow. Grader/landing-phase selection based on `review_grade_phase`/`landing_grade_phase` (per-track, not promotion's/hotfix-sync's) is still unwired; later Jobs in the Epic cover that.

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

Unlike `grade.steps[].phases`, the `grade_phases` fields inside `delivery:` (per-track `review`/`landing`/`ci_failure`/`branch_health`, plus `promotion.grade_phases`/`hotfix_sync.grade_phases`/`ref_movement_actions.*.grade_phases`) accept arbitrary phase name strings — `review_minimal`, `promotion`, `branch_health`, or anything else a repository's `grade.steps[].phases` chooses to name. Wiring most of those custom phase names into actual grader selection (the per-track `review`/`landing`/`ci_failure`/`branch_health` phases, and `ref_movement_actions`) is still a later Job in this Epic; today they're parsed and stored, not consumed, for everything except `promotion`/`hotfix_sync` (below).

`grade.steps[].phases` itself now accepts one addition beyond the original `review`/`landing`/`ci`: `promotion` (`SyrusYml::GRADE_PHASES`). This is the phase `Workflows::Promotion`'s grader loop actually selects graders by (see "Promotion workflow" below). Unlike `review`/`landing`/`ci`, a grader with no explicit `phases:` at all does **not** default into `promotion` (`SyrusYml::DEFAULT_GRADE_PHASES` stays `review`/`landing`/`ci`) — every existing repository's graders keep running exactly where they already did, and a grader only runs during a promotion when it explicitly lists `phases: [promotion]` (or includes `promotion` alongside other phases). `Workflows::HotfixSync`'s grader loop (see "Hotfix sync workflow" below) reuses this same `promotion` grade phase rather than introducing a separate `SyrusYml::GRADE_PHASES` entry — `LandingGraderPlan::PROMOTION_TRIGGER_KINDS` maps both `promotion` and `hotfix_sync` trigger kinds to grader phase `:promotion`, so a repository opts one grader into both ref-movement workflows with the same `phases: [promotion]`.

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
policy.promotion_repair_skill          # delivery.promotion.repair_skill, or nil
policy.promotion_source_branch         # the "default" track's resolved branch (e.g. "develop")
policy.promotion_target_branch         # repository.default_branch (e.g. "main")
policy.hotfix_sync_enabled?
policy.hotfix_sync_mode
policy.hotfix_sync_repair_skill        # delivery.hotfix_sync.repair_skill, or nil
policy.hotfix_sync_source_branch       # repository.default_branch (e.g. "main") — the mirror image of promotion_target_branch
policy.hotfix_sync_target_branch       # the "default" track's resolved branch (e.g. "develop") — the mirror image of promotion_source_branch
```

## `Job#delivery_track`

`Job#delivery_track` is a plain nullable string column — like `target_branch`, it carries no enum/validation, because valid track names are repository-configured (`delivery.tracks` keys), not a fixed set. `nil` means "use the policy default" (`DeliveryPolicy#track_for` resolves a blank or unrecognized track name to the config's `default` track), so every existing Job is unaffected until something explicitly sets it.

Track selection is exposed at every surface that creates a Job:

- **Direct job API** (`Api::V1::App::DirectJobsController#create`) and **admin job creation** (`Api::V1::Admin::JobsController#create`) both accept an optional `delivery_track` param, persisted as-is (trimmed, blank -> `nil`).
- **Issue ingestion** (`PollRepositoryJob`) reads a `syrus-track-<name>` label off the GitHub issue — e.g. `syrus-track-hotfix` sets `delivery_track: "hotfix"` — via `Workflows.track_label_value`, the same label-based convention `SKIP_PREPARE_LABEL` uses. Removing/changing the label on a later poll resyncs the column on the existing Job, mirroring `skip_prepare`'s resync behavior.
- **Skills that file jobs** (`SkillJobs::Creator`, and the `Api::V1::App::SkillsController#create` surface backing it) accept an optional `delivery_track:` kwarg/param, passed straight through to the created Job.

None of these surfaces validate the value against the repository's configured track names — an unrecognized or unconfigured name (e.g. `delivery_track: "hotfix"` on a repository with no `hotfix` track) just resolves to the `default` track at read time via `DeliveryPolicy#track_for`, the same graceful-fallback posture the rest of this policy already has for a missing/unparsable `.syrus.yml`. A repository that defines a `hotfix` track (per the `.syrus.yml` shape above) makes `hotfix` a live selectable track the moment a Job sets `delivery_track: "hotfix"` — no separate opt-in is required beyond configuring the track.

`JobStackBase#effective_base_branch` (`app/models/concerns/job_stack_base.rb`) is the first runtime caller: once its `target_branch` override, `stack_base: main` override, and open stack/dependency parent checks are all exhausted, its final fallback calls `DeliveryPolicy.for(repository: base_repository).job_landing_branch(job)` instead of `base_default_branch` directly. `target_branch` is not removed and still short-circuits first — it remains the explicit, unconditional per-Job branch override; `delivery_track` only applies once every other resolution path has nothing to say. Because `effective_base_branch` feeds PR base-branch resolution (`PullRequestOpener`), rebase targeting, and workspace checkout across the codebase, this one change point is what actually lands a track-selected Job against its track's branch.

`WorkDefinitions.landing_lock_key_for(job)` (`app/services/work_definitions.rb`) is the second runtime caller — see "Landing queue integration" below.

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

`DeliveryPolicy` exposes three additional methods built from this config:

```ruby
policy.approval_configured?
# true once the repository has an approval: block at all (any sub-key); false when absent

policy.job_approval_satisfied?(job)
# No approval.job block at all -> job.approval_satisfied? (existing ReviewPolicies::REGISTRY lookup by repository.review_policy)
# approval.job configured        -> owner approval (if required) AND at least peer_count eligible peer approvals

policy.requires_operator_approval_for_promotion?
# approval.promotion.required.maintainer_count present -> true when > 0
# approval.promotion absent                             -> falls back to delivery.promotion.approval_required
```

`job_approval_satisfied?` is wired into the landing gate — see "Landing queue integration" below. `requires_operator_approval_for_promotion?` is not wired into any gate yet; that lands with the promotion ref-movement workflow later in the Epic.

## Landing queue integration

`LandingQueueProcessor` (`app/services/landing_queue_processor.rb`) generalizes both its per-slot landing lock and its approval re-check to be delivery-track-aware, per Job:

- **Per-slot lock.** `WorkDefinitions.landing_lock_key_for(job)` (also used by `WorkDefinitions::Base#lock_keys_for`, so the actual `WorkUnitLock` rows agree with `LandingQueueProcessor`'s own in-progress checks) resolves `DeliveryPolicy#job_landing_branch(job)` and keys the landing slot by branch instead of bare `repository_id`. When the resolved branch equals `Repository#default_branch` — true for every repository that only has the implicit `default` track, and for any job whose track happens to target the actual default branch — the key is the unchanged, unsuffixed `"landing:repository:<id>"`; only a job resolving to some other branch gets a `":branch:<branch>"`-suffixed key. A `hotfix` track landing straight to `main` and a `default` track landing to `develop` therefore hold distinct locks and land concurrently; two Jobs resolving to the same branch still serialize through the same lock, exactly as before this change.
- **Approval gate.** `LandingQueueProcessor#try_land!`'s pre-existing approval re-check (guarding against a final approver being removed, or similar, after a Job reached `:approved`) now asks `DeliveryPolicy#job_approval_satisfied?(job)` whenever the repository's `approval:` block is configured (`policy.approval_configured?`), regardless of whether the Job has any `job_approvals` rows — a configured owner/peer policy is enforced even for Jobs that reached `:approved` through a path that never recorded a `JobApproval`. Repositories with no `approval:` block keep the exact previous behavior: the gate only runs (`job.approval_satisfied?`) when `job_approvals` rows exist at all, and auto-approved Jobs (no rows) bypass it by design.

## `JobPrLink`

`Job` currently tracks provider PRs through four overloaded, single-purpose columns: `pr_number`/`pr_repository_id` (the PR that actually lands the Job's work — either a same-repo PR or a fork's direct PR to its in-instance upstream), `fork_review_pr_number` (a fork's staging review PR, never merged), and `external_pr_number` (an externally-authored PR ingested into Syrus for grading). Each column conflates "what kind of PR is this" with "where did the number get stored," which doesn't generalize to the promotion/hotfix-sync/upstream-export ref-movement PRs later Jobs in this Epic need to persist.

`JobPrLink` (`app/models/job_pr_link.rb`) is the forward-looking replacement: a durable `job_pr_links` row per `(job, role)` pair, carrying `source_repository_id`/`source_ref`, `target_repository_id`/`target_ref`, the provider `pr_number`, and a free-form `metadata` JSON column reserved for later PR-classification work. `role` is one of `JobPrLink::ROLES` (`local`, `upstream_export`, `promotion`, `hotfix_sync`, `external_ingest`) — the taxonomy grows as later Epic Jobs add upstream-export ref-movement and PR-ingestion classification; `Workflows::Promotion`/`Workflows::HotfixSync` write `promotion`/`hotfix_sync`-role links (see below), nothing beyond `local`/`promotion`/`hotfix_sync` is written yet.

**Migration posture — additive only.** Per the Epic's explicit migration posture, this Job does not remove or stop writing any of the four legacy columns above. `Steps::PrOpen` writes a `role: "local"` link, via `JobPrLink.record!`, at both of its existing `pr_number`-setting call sites — `open_pr` (same-repo/non-fork PR) and `open_upstream_pr` (fork → in-instance-upstream direct PR) — immediately alongside the `job.update!(pr_number:, pr_repository_id:, ...)` call already there. `JobPrLink.record!` is an idempotent `find_or_initialize_by(job:, role:)` upsert, so a retried `pr_open` updates the existing `local` link in place instead of raising on the `(job_id, role)` uniqueness constraint. `ForkReviewApprover` and `PollForkReviewPrJob` (the fork-review staging flow, `fork_review_pr_number`) and the external-PR-ingestion path (`external_pr_number`) are intentionally left untouched — those get their own `role` values from later Epic Jobs. `DeliveryStatus` (below) is the first and, as of this Job, only reader of `JobPrLink` — everything else in this section still just writes `local` links.

```ruby
JobPrLink.record!(
  job: job,
  role: JobPrLink::ROLE_LOCAL,
  source_repository_id: repository.id,
  source_ref: workspace.branch_name,
  target_repository_id: target_repo.id,
  target_ref: pr_base_branch,
  pr_number: pr_number
)
```

## `DeliveryStatus` (apparent delivery status)

`DeliveryStatus` (`app/services/delivery_status.rb`) derives a Job's apparent delivery status — a UI-facing summary — from concrete delivery facts instead of a new `Job` AASM state, per `docs/plans/delivery-tracks-and-promotion.md`'s "Job Lifecycle And Delivery Status" section. `Job#state` remains the actual state machine; `DeliveryStatus` only answers "where does this Job's delivery currently sit" for the Job detail UI.

```ruby
DeliveryStatus.for(job: job)
# => one of:
#   :waiting_for_local_approval     — not yet approved (or approval facts unresolved)
#   :approved_for_local_landing     — approved, landing, or already landed locally
#   :waiting_for_upstream_approval  — a promotion/upstream-export PR link is open
#   :waiting_for_promotion          — landed locally; promotion is configured but hasn't opened its PR yet
#   :syncing_hotfix                 — landed on a non-default track while hotfix-sync is configured
#   :upstream_merged                — the promotion/upstream-export PR link recorded a merge
#   :upstream_closed_without_merge  — the promotion/upstream-export PR link closed without merging
#   :delivery_needs_attention       — the Job failed, or closed with an unsuccessful closure_reason
```

It reads three kinds of facts, in priority order (most specific wins):

1. **The Job's own failure/closure facts** — `job.failed?`, or `job.closed?` with a `closure_reason` outside `Job::SUCCESSFUL_CLOSURE_REASONS` — but only once the promotion/upstream-export link checks below have had a chance to claim a more specific status; an eventual `upstream_pr_merged`-style closure_reason from a later Epic Job should resolve to `:upstream_merged`, not `:delivery_needs_attention`.
2. **The governing `JobPrLink` row** — `DeliveryPolicy#promotion_enabled?` picks the `promotion`-role link, else `DeliveryPolicy#upstream_export_enabled?` picks the `upstream_export`-role link (promotion wins if a repository somehow configures both). The link's `metadata["pr_state"]` (`"open"`/`"merged"`/`"closed"`, reserved for later PR-classification Jobs to write) decides `:waiting_for_upstream_approval` / `:upstream_merged` / `:upstream_closed_without_merge`.
3. **`DeliveryPolicy#hotfix_sync_enabled?` and `#promotion_enabled?` against the resolved track/landing facts** — once a Job has landed locally (`job.closed?` with a successful `closure_reason`), a non-default resolved track (`DeliveryPolicy#job_delivery_track`) under hotfix-sync resolves to `:syncing_hotfix`; a default-track landing under promotion with no promotion link yet resolves to `:waiting_for_promotion`.

**Degrades gracefully today.** Upstream-export ref-movement workflows don't exist yet (a later Epic Job), so no repository has `upstream_export` enabled and no Job ever has an `upstream_export`-role `JobPrLink` row yet. Promotion and hotfix sync both now exist (below), but each writes its `promotion`/`hotfix_sync`-role `JobPrLink` onto its own synthetic anchor Job, not onto the individual dev Jobs that landed the commits being promoted/synced — so `DeliveryStatus.for(job:)` for an ordinary dev Job still can't observe "my track's promotion/sync happened," and resolves to `:waiting_for_promotion`/`:syncing_hotfix` (or one of the other pre-existing buckets) exactly as before. Wiring promotion/hotfix-sync status back onto every constituent Job is left for a later Job in this Epic, same as the upstream-export gap.

## Promotion workflow

`Workflows::Promotion` (`app/services/workflows/promotion.rb`, trigger kind `"promotion"`) implements Story 2's `develop -> main` ref-movement workflow: assemble the delivery track's source branch into the target branch, grade the result, and publish it per `DeliveryPolicy#promotion_mode`. It is not tied to any GitHub issue or to any single dev Job's PR — it moves refs for the repository as a whole.

```
promotion_assemble → prepare → promotion_repair →
  retry_until(repair: promotion_repair, check: grader_fanout/grader_collect) →
  promotion_publish
```

- **`promotion_assemble`** — non-agentic. Fetches the source branch and runs a deterministic `git merge --no-ff origin/<source>` on an integration branch (`syrus/promote-<source>-<target>-<job id>`) that `WorkflowWorkspace` already checked out from the target branch's current tip (the workflow seeds the same `RebaseTarget` artifact keys Rebase workflows use, so no special-cased workspace-checkout logic was needed). Mirrors the merge-commit strategy `.syrus/skills/promote/SKILL.md` documents as this repository's own convention. A clean merge skips the top-level `promotion_repair` occurrence; a conflict aborts the merge (leaving the target's history untouched) and falls through to it.
- **`promotion_repair`** — agentic. Reused for two different reasons the chain reaches it: the top-level occurrence only runs after a merge conflict; the `retry_until` loop's occurrence runs after a `promotion` grade-phase failure. Either way it resolves `DeliveryPolicy#promotion_repair_skill` (`delivery.promotion.repair_skill`) via the same `Skills.for` repo-local-override-else-built-in resolution `Steps::RunSkill` uses, and fails the step outright if no repair skill is configured — this workflow does not guess at conflict resolution.
- **grading** — the `retry_until` loop's `grader_fanout`/`grader_collect` steps are the same generic grader-check machinery every grade loop uses; what makes them grade promotion-specific checks is `LandingGraderPlan` mapping trigger kind `"promotion"` to grader phase `:promotion` (`LandingGraderPlan::PROMOTION_TRIGGER_KINDS`) — a repository opts a grader in with `phases: [promotion]` in its `grade:` block, the newly-accepted fourth `SyrusYml::GRADE_PHASES` value (see above).
- **`promotion_publish`** — non-agentic. Publishes per `DeliveryPolicy#promotion_mode`: `"direct"` pushes straight onto the target branch ref (no PR); `"auto_pr"` opens/updates a PR from the integration branch to the target branch and auto-merges immediately unless `DeliveryPolicy#requires_operator_approval_for_promotion?`; `"manual_pr"` opens/updates the PR but never auto-merges. Either way it persists the resolved refs as a `JobPrLink` (`role: JobPrLink::ROLE_PROMOTION`) on the workflow's anchor Job — `pr_number: nil`/`metadata: {"pr_state" => "merged"}` for a direct push, a real PR number and `"open"`/`"merged"` for the PR-based modes. Only a direct push or an immediate auto-merge closes the anchor Job (`closure_reason: "promotion_landed"`, now in `Job::SUCCESSFUL_CLOSURE_REASONS`); a PR left open for manual/gated merge leaves the Job open so the operator sees it still needs action.

**Trigger.** `PromotionDispatcher.call!(repository:, user: nil, source_branch: nil, target_branch: nil, agent_provider: nil)` is the on-demand entry point for this iteration — no scheduler yet (the plan's own "Later Additions" leave manual-vs-scheduled-vs-automatic triggering an open question). It resolves unset `source_branch`/`target_branch` from `DeliveryPolicy#promotion_source_branch`/`#promotion_target_branch`, creates a synthetic `kind: "direct"` anchor Job with no GitHub issue (the same pattern `MainHealthChangedService`/`MaybeDeployJob` use for repository-level Workflows that aren't about any single issue), and dispatches through `WorkUnits::Launcher.instantiate`/`.start!` — the same path `MaybeDeployJob`/`MainGraderWorkflowJob` use. `WorkDefinitions::Promotion` (`scope: "repository"`) registers the `"promotion"` `WorkUnits`/`WorkDefinitions` kind the launcher needs; it includes `ManagesOwnJobLifecycle` since the anchor Job never goes through the normal `pr_open`/`mark_implemented`/approval pipeline — `promotion_publish` manages the Job's closure directly, as described above.

`App::JobDetailPayload#job_json` exposes it as `delivery_status` on the Job detail API response (`app/frontend/api/jobs.ts`'s `JobRecord#delivery_status`); no UI reads it yet — that lands with the delivery-status UI Jobs later in this Epic.

## Hotfix sync workflow

`Workflows::HotfixSync` (`app/services/workflows/hotfix_sync.rb`, trigger kind `"hotfix_sync"`) implements Stories 5 and 5A's `main -> develop` ref-movement workflow: the mirror image of promotion. When commits land directly on the release branch (a hand-committed hotfix, or a manually merged PR) instead of going through the development track, this workflow syncs them back so `develop` doesn't diverge. Like promotion, it is not tied to any GitHub issue or to any single dev Job's PR — it moves refs for the repository as a whole.

```
hotfix_sync_assemble → prepare → hotfix_sync_repair →
  retry_until(repair: hotfix_sync_repair, check: grader_fanout/grader_collect) →
  hotfix_sync_publish
```

The chain shape, step semantics, and grading machinery are identical to `Workflows::Promotion` with direction reversed (see "Promotion workflow" above for the full explanation of each step's mechanics) — `Steps::HotfixSyncAssemble`/`Steps::HotfixSyncRepair`/`Steps::HotfixSyncPublish` mirror `Steps::PromotionAssemble`/`Steps::PromotionRepair`/`Steps::PromotionPublish` line for line:

- **`hotfix_sync_assemble`** — non-agentic. Fetches `DeliveryPolicy#hotfix_sync_source_branch` (the repository's actual default/release branch) and runs a deterministic `git merge --no-ff origin/<source>` on an integration branch (`syrus/hotfix-sync-<source>-<target>-<job id>`) checked out from `DeliveryPolicy#hotfix_sync_target_branch`'s (the development track's) current tip. A clean merge skips the top-level `hotfix_sync_repair` occurrence; a conflict aborts the merge and falls through to it.
- **`hotfix_sync_repair`** — agentic. Resolves `DeliveryPolicy#hotfix_sync_repair_skill` (`delivery.hotfix_sync.repair_skill`) via `Skills.for`, and fails the step outright if none is configured.
- **grading** — reuses the same `promotion` grade phase promotion does rather than a separate built-in phase name (`LandingGraderPlan::PROMOTION_TRIGGER_KINDS` now includes both `"promotion"` and `"hotfix_sync"` trigger kinds, both mapped to grader phase `:promotion` — see "Grade phase names are free-form here" above).
- **`hotfix_sync_publish`** — non-agentic. Publishes per `DeliveryPolicy#hotfix_sync_mode`: `"auto"` (the default) pushes straight onto the target branch ref, no PR — hotfix sync's equivalent of promotion's `"direct"` mode, named differently because unattended sync-back is the expected default (Story 5A) rather than something requiring opt-in; `"auto_pr"` opens/updates a PR from the integration branch to the target branch and always auto-merges immediately (hotfix sync has no maintainer-approval gate equivalent to `requires_operator_approval_for_promotion?` — the release branch already went through its own stricter landing checks before these commits reached it); `"manual_pr"` opens/updates the PR but never auto-merges. Either way it persists the resolved refs as a `JobPrLink` (`role: JobPrLink::ROLE_HOTFIX_SYNC`) on the workflow's anchor Job. Only a direct push or an immediate auto-merge closes the anchor Job (`closure_reason: "hotfix_sync_landed"`, in `Job::SUCCESSFUL_CLOSURE_REASONS`); a PR left open for manual merge leaves the Job open.

**Trigger.** `HotfixSyncDispatcher.call!(repository:, user: nil, source_branch: nil, target_branch: nil, agent_provider: nil)` is the on-demand entry point, mirroring `PromotionDispatcher`, plus `HotfixSyncDispatcher.pending_for?(repository)` to check whether a sync anchor Job is already open. `WorkDefinitions::HotfixSync` (`scope: "repository"`) registers the `"hotfix_sync"` kind the same way `WorkDefinitions::Promotion` does, including `ManagesOwnJobLifecycle` for the same reason.

**Detection.** Unlike promotion (on-demand only, no scheduler yet), hotfix sync has an automatic polling detector, since direct release-branch commits happen outside Syrus and nothing else would notice them:

- `PollAllHotfixSyncsJob` (`config/recurring.yml`, `poll_hotfix_syncs`, every 5 minutes) fans out to every active repository with `DeliveryPolicy#hotfix_sync_enabled?` — mirroring `PollAllDeploymentStagesJob`'s pattern of reading a `.syrus.yml`-driven policy per repository instead of filtering on a `Repository` boolean column, since hotfix-sync opt-in lives in `.syrus.yml`, not the database.
- `PollHotfixSyncJob` resolves the source/target branches, skips if a sync is already `HotfixSyncDispatcher.pending_for?` this repository (so a slow-to-merge `manual_pr` sync doesn't get re-dispatched every tick), then calls `GithubClient#compare_commits(repo_slug, target, source)` — the same GitHub compare API `App::JobSourcePayload`/`DeploymentStageDetector` already use elsewhere — to check whether the release branch has commits the development branch doesn't. A non-empty commit list dispatches `HotfixSyncDispatcher.call!`; GitHub-transient errors (`Octokit::ServerError`, `Faraday::TimeoutError`, `Faraday::ConnectionFailed`) are logged and skipped for the next tick, the same posture `PollMainBranchHealthJob` uses.

This was evaluated against extending `PollAllMainBranchHealthJob`/`PollMainBranchHealthJob` instead of adding a new poller, per the parent issue's explicit ask. That poller's per-SHA CI/grader health state machine (`ci_health`/`grader_health`/`main_health`, stale-SHA carry-forward, `MainHealthChangedService` repair-job lifecycle) is a materially different concern from "does one branch contain another's tip commit" — bolting hotfix-sync detection onto it would have meant threading unrelated state through an already-intricate job. A dedicated poller following the simpler `PollAllDeploymentStagesJob`/`PollRepositoryDeploymentStagesJob` shape (policy-gated fan-out, stateless per-tick check) was the smaller, clearer diff.
