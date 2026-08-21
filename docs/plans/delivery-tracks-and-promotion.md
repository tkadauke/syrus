# Delivery Tracks, Promotion, and Branch Policy

Syrus currently treats most work as "job produces a PR, operator approves, landing
queue merges it." That is a good strict model, but it is not the only useful
development model. We want room for faster development branches, branch-level
repair, fork workflows, hotfix sync, and AI-assisted integration without baking
today's guesses into every workflow.

This plan captures the direction. It is intentionally iterative, not a final
spec.

## Goals

- Let repositories choose a delivery model without scattering `if develop branch`
  branches through workflow code.
- Keep `.syrus.yml` shared across all participants. It must not encode one
  developer's personal fork topology.
- Support the common case where a repository has an upstream source and that
  upstream is the canonical project.
- Let work land quickly on a development branch while preserving a stricter
  release/promotion gate.
- Support hotfixes that happen outside Syrus, including direct commits to the
  release branch.
- Make complex integration/backport work AI-assistable through skills or
  workflow steps.
- Keep approval semantics clear: approving a job means "land into my configured
  local track," not "upstream has accepted this change."
- Support teams where local landing requires approval from the job owner and at
  least one additional collaborator.

## Non-Goals For The First Iteration

- A fully generic role-binding matrix for arbitrary remotes.
- Multi-upstream release routing.
- Replacing existing strict landing for repositories that want it.
- Making skills responsible for the whole delivery model.

## Core Concepts

### Delivery Track

A track is a configured branch target plus validation policy. For Syrus itself,
the likely local track is:

- development branch: `develop`
- release branch: `main`

Jobs would normally land into the development branch. Promotion moves validated
development work to the release branch.

Jobs should be able to select a track at creation time. The repository declares
available tracks; a job stores the selected track in durable metadata. The
policy then answers target branch, grader phase, approval behavior, and follow-up
sync behavior from that track.

Common tracks:

- `default` — ordinary repository workflow;
- `development` — fast local development branch;
- `hotfix` — direct release-branch work with stricter checks;
- `upstream` — fork-local work intended for upstream export.

Track selection should be available from:

- direct job form;
- chat-created jobs;
- issue labels or issue frontmatter;
- skills that file jobs;
- API/admin actions.

If no track is selected, policy uses the repository default.

### Canonical Repository

For now, use existing upstream-source data:

- Current repository is the writable working repository.
- `repository.upstream_source`, if present, is canonical.
- If no upstream source is set, the current repository is canonical.

This covers most fork constellations:

- Thomas's main Syrus repo: working repo and canonical repo are both
  `tkadauke/syrus`.
- Pete's fork: working repo is `pete/syrus`; canonical repo is
  `tkadauke/syrus`.

### Promotion

Promotion is an explicit workflow that moves a source ref to a target ref. It is
a named, common ref-movement action, not a separate hardcoded delivery engine.
It should not be an incidental side effect of ordinary job landing.

For same-repo development:

```text
develop -> main
```

For a fork:

```text
pete/syrus:develop -> tkadauke/syrus:develop
```

The promotion workflow can use either a direct push or a PR. A PR is fine even
when no human approval is required, because it still provides GitHub audit,
checks, and a clean integration surface.

### Hotfix Sync

Hotfixes can originate outside Syrus. In this repo, urgent fixes are often
committed straight to `main` because the system itself needs to be deployed
quickly.

The delivery model needs a reverse sync. Like promotion, this is a named,
common ref-movement action:

```text
main -> develop
```

When the release branch advances outside the development branch, Syrus should be
able to create a sync workflow:

1. detect release branch advanced;
2. check whether development contains the release tip;
3. mechanically merge or rebase release into development;
4. use an agent/skill if conflicts occur;
5. run configured sync/promotion graders;
6. push or open a PR depending on policy.

### PR Ingestion

PRs can arrive from any source:

- a human's hand-written branch;
- another Syrus instance;
- another user on the same Syrus instance;
- a fork-local Syrus job exported upstream;
- a whole development branch promoted upstream;
- a release/hotfix branch from outside Syrus.

Syrus should ingest PRs by classifying the PR's source, not by assuming every
external PR is one kind of work.

At a minimum, ingestion should distinguish:

- `external_unknown` — ordinary external PR, no Syrus metadata;
- `syrus_job_export` — one Syrus job exported as an upstream PR;
- `syrus_branch_export` — many jobs or a whole development branch exported as
  one PR;
- `syrus_promotion` — a promotion PR created by this Syrus instance;
- `manual_hotfix` — a PR/merge into the release branch that did not originate
  from a local job.

This classification can come from structured PR metadata when available, and
fall back to heuristics otherwise:

- PR branch/ref naming;
- PR body markers;
- linked job IDs;
- source repository matching a known fork;
- commit trailers;
- branch contains multiple known job checkpoint refs;
- whether the PR head branch is controlled by this Syrus instance.

The classification determines the ingestion behavior:

- one-job export can attach to or create one Job;
- branch export can create an Epic or an umbrella ingestion Job with child Jobs;
- unknown external PR can use today's external PR ingest path;
- promotion PR should be tracked as a promotion workflow, not as ordinary
  feature work;
- hotfix PR/merge should feed hotfix sync.

### Ref Movement Actions

Some movement between refs should be explicit operator action, not only
automatic policy. The same primitive should power intra-repo branch sync,
release promotion, backports, and cross-repo upstream submission.

Useful actions:

- "Send this job PR upstream."
- "Submit my current branch upstream."
- "Submit my development branch upstream."
- "Promote this branch to release."
- "Sync release back into development."
- "Backport this upstream hotfix to my fork."

These actions all resolve to the same lower-level shape:

```text
source ref -> target ref, maybe through an integration branch, maybe via PR
```

Whether an action is cross-repo is a property of the resolved source and target
refs. For example:

- `develop -> main` in the same repository is branch promotion;
- `main -> develop` in the same repository is branch sync;
- `fork/job-branch -> upstream/main` is cross-repo upstream submission;
- `upstream/main -> fork/develop` is cross-repo hotfix sync/backport.

The action decides:

- source scope: job branch, selected jobs, development branch, arbitrary branch,
  release branch;
- target: current repo, upstream source, release branch, development branch;
- transport: direct push, auto PR, manual PR;
- validation phase: minimal, branch_health, promotion, hotfix_sync;
- repair handler: no repair, mechanical only, agent/skill repair.

The policy decides what is allowed and what defaults apply.

Example policy config:

```yaml
delivery:
  ref_movement_actions:
    send_job_upstream:
      enabled: true
      source: { kind: job_branch }
      target: { kind: upstream_intake }
      mode: manual_pr
      grade_phases: [promotion]

    submit_branch_upstream:
      enabled: true
      source: { kind: selected_branch }
      target: { kind: upstream_intake }
      mode: manual_pr
      grade_phases: [promotion]

    promote_development:
      enabled: true
      source: { kind: track, name: default }
      target: { kind: branch, name: main }
      mode: auto_pr
      grade_phases: [promotion]

    sync_release_to_development:
      enabled: true
      source: { kind: branch, name: main }
      target: { kind: track, name: default }
      mode: auto
      grade_phases: [hotfix_sync]
```

This can be mostly sugar over existing blocks:

- `send_job_upstream` maps to `upstream_export.mode: per_job_pr`;
- `submit_branch_upstream` maps to branch export;
- `promote_development` maps to promotion;
- `sync_release_to_development` maps to hotfix sync.

Promotion and hotfix sync should therefore be implemented internally as
first-class ref-movement workflows with named product affordances, not as
bespoke two-branch code paths. The implementation should store the resolved
source and target refs on the workflow/action record so future policy changes
do not rewrite history.

The UI should present these as actions, but the backend should create explicit
workflows with durable provenance:

```ruby
RefMovementAction.dispatch!(
  repository: repository,
  actor: user,
  action: "send_job_upstream",
  source: job,
  target: :upstream_intake
)
```

The action record/workflow should say:

- who requested it;
- what source ref was used;
- what target ref was used;
- whether the target was inferred from upstream source;
- what validation policy applied;
- what PR was opened/updated.

This matters because ref movement can otherwise become invisible magic:
operators need to know whether they are approving local landing, exporting
upstream, promoting release, or syncing a hotfix.

### Versioned Release Branches

Large projects can have more complicated release topologies than
`develop -> main`. For example, Ruby, Linux, or another long-lived project may
have a trunk branch plus many versioned release branches. A release branch may
be created from trunk, then later become both the source and target of selected
hotfixes and backports:

```text
trunk -> ruby_3_4
trunk -> ruby_3_3
ruby_3_4 hotfix -> trunk
trunk fix -> ruby_3_4 and ruby_3_3, but not ruby_3_2
```

The first iteration does not need to automate all of that policy. It does need
to avoid blocking it later. The core abstraction should remain:

```text
named source ref -> named target ref, with configured validation and repair
```

That means the core app should model tracks, source/target refs, PR links,
queueing, retries, graders, audit, and permissions. It should not bake in rules
like "there is exactly one development branch" or "hotfix sync always means
`main -> develop`."

Repository-specific release judgment belongs in skills or interactive chat
sessions. A skill can decide whether a patch belongs on `ruby_3_4`,
`ruby_3_3`, both, or neither; adapt the patch; resolve conflicts; update
release notes; and then dispatch the appropriate ref-movement workflow. Syrus
should make that workflow durable and auditable once the source and target have
been selected.

Agents doing that work should have good read access to GitHub state. Syrus MCP
tools should remain preferred for auditable Syrus mutations, but `gh` access is
valuable for inspection-heavy release work: labels, milestones, PR discussions,
CI, merge bases, branch listings, and upstream metadata. Mutation through `gh`
should be constrained by permissions and ideally routed through explicit Syrus
actions when the result should be tracked.

This keeps the model flexible enough for versioned release branches without
making the first iteration responsible for every possible release process.

## Approval Semantics

Approval must be scoped.

For the main Syrus instance:

1. Job creates a PR against `develop`.
2. Thomas approves the job.
3. Syrus lands it into `develop`.
4. Promotion workflow later moves `develop` to `main`.
5. Promotion may auto-merge if the repository policy allows it.

For Pete's fork:

1. Job creates a PR against `pete/syrus:develop`.
2. Pete approves the job.
3. Syrus lands it into Pete's development branch.
4. Pete later promotes either the whole branch or selected jobs upstream.
5. Upstream review/promotion is separate from Pete's local approval.

Pete approving local work must not imply canonical acceptance.

## Job Lifecycle And Delivery Status

Delivery status should not immediately explode the `Job` AASM state machine.
Most of these states are delivery posture, not implementation state. A job can
be implemented while waiting for local approval, waiting for upstream approval,
waiting for promotion, or waiting for a release-train cherry-pick.

Prefer storing concrete delivery facts and deriving an apparent state:

- selected `job.delivery_track`;
- delivery target resolved from policy;
- PR links for local review, upstream export, promotion, external ingest, and
  future transports;
- ref-movement action/workflow status;
- needs-attention reasons for closed/unmerged upstream PRs, failed promotion,
  or blocked sync.

Examples of derived apparent states:

- `waiting_for_local_approval`;
- `approved_for_local_landing`;
- `waiting_for_upstream_approval`;
- `waiting_for_promotion`;
- `syncing_hotfix`;
- `upstream_merged`;
- `upstream_closed_without_merge`;
- `delivery_needs_attention`.

The important rule is that terminal success is policy-defined. Opening an
upstream PR is not necessarily completion. Local landing is not necessarily
completion. For example:

- local-only repository: close when the local PR lands;
- fork with per-job upstream export: keep the job open after local approval and
  close only when the upstream PR merges;
- branch-export workflow: close included jobs when the upstream branch-export
  PR is accepted, if the policy says that branch acceptance completes those
  jobs;
- upstream PR closed without merge: keep the job open with delivery attention,
  unless the operator explicitly closes/cancels it.

This may eventually justify a new persisted state, but the first pass should
derive the UI state from delivery facts. That keeps the core state machine
small while still making "waiting for local approval" and "waiting for upstream
approval" visibly different.

## UI Surfaces

The UI needs to expose delivery scope directly.

Repository UI should show:

- delivery tracks: name, branch/ref, grade phases, health, queue length, last
  promotion/sync;
- repository/track ref-movement actions: promote, sync release to development,
  submit branch upstream, release-train cherry-pick later;
- action availability with explicit blocked reasons;
- recent ref-movement workflows and their source/target refs;
- PR ingestion classifications for recent imported PRs.

Job UI should show:

- selected delivery track and target ref;
- local PR, upstream PR, promotion PR, and external PR links by role;
- current derived delivery status;
- job-specific ref-movement actions such as `send_job_upstream`;
- clear copy for each posture: "Waiting for local approval", "Approved
  locally", "Sent upstream: PR #123 waiting for review", "Upstream merged",
  "Upstream closed without merge".

Dashboard/smart-folder UI should make these states discoverable:

- waiting for local approval;
- waiting for upstream;
- promotion pending/running;
- delivery needs attention;
- track-specific landing queues when a repository has more than one landing
  target.

## `.syrus.yml` Shape

The shared config should declare project-level conventions, not personal fork
bindings.

Possible initial shape:

```yaml
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review_minimal
        landing: landing_minimal

    hotfix:
      branch: main
      grade_phases:
        review: review_minimal
        landing: promotion
      after_landing:
        sync_to: default

  job_approval:
    lands_to: selected_track

  promotion:
    enabled: true
    mode: auto_pr # direct, auto_pr, manual_pr
    approval_required: false
    grade_phases: [promotion]
    repair_skill: integrate_release_branch

  hotfix_sync:
    enabled: true
    direction: release_to_development
    mode: auto
    grade_phases: [promotion]
    repair_skill: backport_release_hotfix
```

This config can be shared. It does not name `tkadauke/syrus`, `pete/syrus`, or
an upstream owner.

## Backward Compatibility And Defaults

`delivery:` must be optional. Existing repositories with no delivery config must
continue to behave the way they do today.

When `.syrus.yml` has no `delivery:` section, Syrus should normalize it to an
implicit config:

```yaml
delivery:
  tracks:
    default:
      branch: <repository default branch>
      grade_phases:
        review: review
        landing: landing
        ci_failure: ci
        branch_health: ci

  job_approval:
    lands_to: selected_track

  promotion:
    enabled: false

  hotfix_sync:
    enabled: false

  upstream_export:
    enabled: false

  ref_movement_actions: {}
```

Other default rules:

- If `delivery.tracks.default.branch` is omitted, use the repository default
  branch.
- If a track omits `grade_phases.review`, use `review`.
- If a track omits `grade_phases.landing`, use `landing`.
- If `delivery.grade_phases.branch_health` is omitted, use `ci`.
- If `delivery.grade_phases.hotfix_sync` is omitted, use `promotion` when that
  phase exists, else `landing`.
- If no `approval:` section exists, use the current approval behavior.
- If no `external_prs:` section exists, use the current external PR ingest
  setting/path.
- If no `upstream_source` is set, `upstream_*` targets are unavailable and
  should produce a clear UI/API error rather than silently targeting the current
  repository.

Existing `grade:` config remains valid:

```yaml
grade:
  - name: rspec
    run: bin/rspec-fast
    phases: [landing]
```

The current built-in phases stay valid:

- `review`
- `landing`
- `ci`

New phase names are opt-in. A repository only needs names like
`review_minimal`, `branch_health`, or `promotion` if its delivery config refers
to them.

The parser should store both:

- the raw config, for display/debugging; and
- a normalized delivery config, so runtime code never has to handle "missing
  delivery block" branches.

## Interaction With `grade:`

`grade:` should remain the project-owned check catalog. Delivery policy should
only select phase names.

Example:

```yaml
grade:
  failures: strict
  steps:
    - name: eager-load
      run: bin/check-eager-load
      phases: [review_minimal, landing_minimal, branch_health, promotion]
      failures: strict

    - name: rspec
      run: bin/rspec-fast
      phases: [branch_health, promotion]
      junit_output: .syrus/grade-output/rspec-junit.xml
      failures: allow_inherited
```

Delivery policy maps lifecycle moments to those phase names:

```yaml
delivery:
  grade_phases:
    review: review_minimal
    landing: landing_minimal
    branch_health: branch_health
    promotion: promotion
```

Important boundary:

- `grade.steps[].failures` says what a grader failure means.
- `delivery` says what the workflow does with that failure.

Policy should never rewrite commands. If CI needs a CI-only command, define a
separate grader in `grade.steps` and select it by phase.

## Policy Objects

Workflow code should ask policy objects questions instead of checking delivery
mode names directly.

Potential interface:

```ruby
policy = DeliveryPolicy.for(repository:, job:)

policy.job_landing_branch(job)
policy.job_delivery_track(job)
policy.review_grade_phase(job)
policy.landing_grade_phase(job)
policy.branch_health_grade_phase(branch)
policy.after_landing_actions(job)
policy.promotion_grade_phases
policy.ci_failure_behavior(job)
policy.can_land_while_branch_unhealthy?(job)
policy.requires_operator_approval_for_promotion?
policy.promotion_mode
policy.hotfix_sync_enabled?
policy.hotfix_sync_mode
```

The workflow owns mechanics. The policy owns decisions.

## Skills And AI Integration

Skills should be optional handlers for hard integration steps:

- `integrate_release_branch`
- `backport_release_hotfix`
- `repair_development_branch`
- `classify_branch_failure`
- `prepare_release_notes`

Core Syrus should still own the lifecycle:

- which branch jobs target;
- whether approval lands locally or promotes upstream;
- whether promotion uses PR/direct/manual mode;
- whether hotfix sync exists;
- which grade phases run.

Skills should not be required for every repo to get a development branch model.

## Topology Stories

These examples are the test cases for the model. If the model cannot explain
one of these cleanly, the model is either too narrow or too abstract.

### Story 1: Alice Owns `alice/foo` And Ships From `main`

Alice is the sole maintainer of `alice/foo`. She wants the current Syrus
behavior: every job opens a PR against `main`, she reviews/approves the job, and
Syrus lands it only after the normal landing checks pass. There is no separate
development branch and no upstream fork relationship.

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: main

  grade_phases:
    review: review
    landing: landing
    ci_failure: ci
    branch_health: ci

grade:
  steps:
    - name: smoke
      run: bin/smoke
      phases: [review, landing, ci]
      failures: strict

    - name: rspec
      run: bin/rspec-fast
      phases: [landing, ci]
      junit_output: .syrus/grade-output/rspec-junit.xml
      failures: allow_inherited
```

Repository settings:

```yaml
default_branch: main
upstream_source: null
```

What happens:

- Job approval means "land this PR into `alice/foo:main`."
- CI failures remain job-scoped unless repository settings say otherwise.
- Promotion/hotfix sync do not exist for this repo.

This is the baseline. The new model must not make this workflow harder.

### Story 2: Alice Owns `alice/foo`, Develops On `develop`, Releases From `main`

Alice wants faster iteration. Jobs should land into `develop` after lightweight
checks. `main` is the release branch. Promotion from `develop` to `main` should
run full checks and can use a PR for audit, but Alice does not want to manually
approve that PR every time.

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review_minimal
        landing: landing_minimal

    hotfix:
      branch: main
      grade_phases:
        review: review_minimal
        landing: promotion
      after_landing:
        sync_to: default

  job_approval:
    lands_to: selected_track

  grade_phases:
    review: review_minimal
    landing: landing_minimal
    branch_health: branch_health
    promotion: promotion
    hotfix_sync: promotion

  ci_failures:
    behavior: branch_repair

  promotion:
    enabled: true
    mode: auto_pr
    approval_required: false
    repair_skill: integrate_release_branch

  hotfix_sync:
    enabled: true
    direction: release_to_development
    mode: auto
    repair_skill: backport_release_hotfix

grade:
  steps:
    - name: syntax
      run: bin/smoke
      phases: [review_minimal, landing_minimal, branch_health, promotion]
      failures: strict

    - name: rspec
      run: bin/rspec-fast
      phases: [branch_health, promotion]
      junit_output: .syrus/grade-output/rspec-junit.xml
      failures: allow_inherited
```

Repository settings:

```yaml
default_branch: main
upstream_source: null
delivery_policy_enabled: true
```

What happens:

- Job PRs target `develop`.
- Alice approves jobs into `develop`.
- Branch-health workflows validate `develop` and create branch-repair jobs when
  it breaks.
- Promotion creates or updates a PR from an integration branch to `main`, runs
  promotion graders, and auto-merges when green.
- If Alice pushes a hotfix directly to `main`, hotfix sync moves `main` back
  into `develop`.

The PR used for promotion is an implementation detail of the promotion workflow.
It is not another human approval gate unless policy says it is.

### Story 3: Bob Forks Alice's Repo And Works Locally First

Alice owns `alice/foo`. Bob has `bob/foo` as a fork. Bob wants Syrus to help him
build features and test locally. Bob is allowed to approve work into his own
development branch, but Bob's approval must not imply that Alice accepts the
change upstream.

Bob's repository settings:

```yaml
repository: bob/foo
default_branch: main
upstream_source: alice/foo
delivery_policy_enabled: true
```

Shared `.syrus.yml` is the same as Story 2. It does not mention Bob.

What happens:

- Bob's jobs target `bob/foo:develop`.
- Bob's approval lands work into Bob's `develop`.
- Bob can run branch-health and repair in his fork.
- When Bob is ready, promotion opens a PR from Bob's writable repo to Alice's
  canonical repo.

There are two promotion modes worth supporting:

```yaml
delivery:
  promotion:
    upstream_mode: branch_pr
```

This opens one PR:

```text
bob/foo:develop -> alice/foo:develop
```

or:

```yaml
delivery:
  promotion:
    upstream_mode: selected_jobs
```

This promotes selected jobs/branches individually:

```text
bob/foo:syrus/job-123 -> alice/foo:develop
```

The first iteration can support `branch_pr` only. The policy interface should
leave room for `selected_jobs` without requiring a different approval model.

### Story 4: Carol Maintains A Company Repo With `develop`, `staging`, And `main`

Carol's company uses:

```text
develop -> staging -> main
```

Syrus does not need to support all of this in the first iteration, but the model
should not make it impossible. The important requirement is that promotion is
source-track to target-branch, not hardcoded `develop -> main`.

Future shared `.syrus.yml` shape:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    staging:
      branch: staging
    release:
      branch: main

  promotions:
    staging:
      from: default
      to: staging
      mode: auto_pr
      grade_phases: [promotion]

    production:
      from: staging
      to: release
      mode: manual_pr
      grade_phases: [promotion]
```

The first iteration can expose only one `promotion` block. Internally, though,
the promotion workflow should be shaped as `source_ref -> target_ref` so this
extension is natural later.

### Story 5: Dan Mostly Uses Direct Hotfixes

Dan operates a small production service. Most changes can go through a
development branch, but outages are fixed by direct commits or manually merged
PRs to `main`. Dan still wants Syrus's development branch to stay current.

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    release:
      branch: main

  hotfix_sync:
    enabled: true
    direction: release_to_development
    mode: auto_pr
    repair_skill: backport_release_hotfix
```

What happens:

- A direct `main` commit is not treated as suspicious just because Syrus did not
  create it.
- Syrus detects that `develop` lacks commits from `main`.
- A hotfix-sync workflow backports or merges those commits into `develop`.
- If conflict resolution is hard, Syrus invokes the configured skill or files
  an operator-visible pending action.

This story matters for Syrus itself: urgent performance/deploy fixes often go
straight to `main`.

### Story 5A: Alice Files A Hotfix Straight To `main`

Alice normally lands work into `develop`, but production is slow and she needs a
performance fix deployed immediately. She files a job and marks it as `hotfix`.
That job should target `main` directly and run the stricter promotion-grade
checks before landing. After it lands, Syrus should sync `main` back into
`develop`.

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
      grade_phases:
        review: review_minimal
        landing: landing_minimal

    hotfix:
      branch: main
      grade_phases:
        review: review_minimal
        landing: promotion
      approval:
        required:
          owner: true
      after_landing:
        sync_to: default

  hotfix_sync:
    enabled: true
    mode: auto
    grade_phases: [promotion]
```

Job creation payload:

```yaml
title: "Fix slow repository show query"
delivery_track: hotfix
```

What happens:

- The PR targets `main`, not `develop`.
- Landing uses the `promotion` grade phase, including the expensive checks.
- The job can still require normal job approval before landing.
- After landing, Syrus schedules hotfix sync from `main` back to `develop`.
- The UI should badge this clearly as `Hotfix -> main` so it is not confused
  with ordinary development work.

This is the explicit, Syrus-native version of the direct hotfix commits we have
often made by hand.

### Story 6: Erin Wants Fast Local Landing But Strict Upstream PRs

Erin has a fork of a large open-source project. She wants Syrus to land many
small jobs into her fork quickly, but every upstream PR should be reviewed by
humans and should run full promotion graders.

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    release:
      branch: main

  job_approval:
    lands_to: selected_track

  promotion:
    enabled: true
    mode: manual_pr
    approval_required: true
    grade_phases: [promotion]
```

Repository settings:

```yaml
repository: erin/project
upstream_source: upstream/project
```

What happens:

- Erin approves local jobs into `erin/project:develop`.
- Promotion creates a PR to `upstream/project`.
- Syrus does not auto-merge or auto-approve that PR.
- Promotion graders and release notes can still be AI-assisted.

This is the open-source fork-safe variant.

### Story 7: Five Collaborators Require Owner Plus Peer Approval

Five people collaborate directly on `team/foo`. They all have write access, but
the team's rule is that no job lands just because its owner likes it. Landing
requires:

- the job owner approving the result; and
- at least one other collaborator approving it.

This should work with strict `main` landing and with development-branch landing.
It is an approval policy, not a delivery topology.

Shared `.syrus.yml` for strict `main`:

```yaml
delivery:
  tracks:
    default:
      branch: main

approval:
  job:
    required:
      owner: true
      peer_count: 1
```

Shared `.syrus.yml` for a development branch:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    release:
      branch: main

  job_approval:
    lands_to: selected_track

approval:
  job:
    required:
      owner: true
      peer_count: 1

  promotion:
    required:
      maintainer_count: 1
```

What happens:

- A job implemented for Alice does not land when Alice alone approves it.
- A job implemented for Alice can land after Alice and Bob approve it.
- Bob's approval is a peer approval only if Bob has access to the repository in
  this Syrus instance.
- Promotion can have its own approval rule. A team may choose to auto-promote
  after branch health is green, or require a maintainer approval for releases.

The owner-plus-peer rule must stay separate from GitHub PR review mechanics.
Syrus can mirror approvals to GitHub where useful, but Syrus needs its own
approval state so direct jobs, generated PRs, fork-local landing, and auto-PR
promotion all behave consistently.

### Story 8: A And B Share One Syrus Instance, B Forks A, Each Job Exports A PR

A owns the canonical repository `a/foo`. B has a fork `b/foo`. Both A and B use
the same Syrus instance. They work independently: A's jobs target A's repo, B's
jobs target B's repo.

B's desired model is:

1. B implements a job in `b/foo`.
2. B approves the job locally.
3. Syrus opens a PR to A for that specific approved job.

This is different from branch promotion. B is not necessarily promoting an
entire `develop` branch. B wants one upstream PR per approved job.

This should work whether either side uses a development branch:

- If B has no development branch, B's job branch can open directly against A's
  configured intake branch.
- If B uses `develop`, B can still export the specific job branch rather than
  the whole `develop` branch.
- If A uses `develop`, the PR target should be A's development branch.
- If A uses strict `main`, the PR target should be A's main branch.

B's repository settings:

```yaml
repository: b/foo
upstream_source: a/foo
delivery_policy_enabled: true
```

Shared `.syrus.yml` shape:

```yaml
delivery:
  tracks:
    default:
      branch: main

  upstream_export:
    enabled: true
    mode: per_job_pr
    after_local_approval: true
    target: upstream_intake
```

If B uses a development branch locally:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    release:
      branch: main

  job_approval:
    lands_to: selected_track

  upstream_export:
    enabled: true
    mode: per_job_pr
    after_local_approval: true
    target: upstream_intake
```

What happens:

- B approving a job means the job is acceptable in B's context.
- Syrus then opens or updates a PR from B's job branch to A's intake branch.
- A reviews/approves/lands that PR according to A's own policy.
- B's local approval does not imply A's approval.
- This can run side by side with branch promotion. A repo can choose per-job
  export, branch promotion, both, or neither.

The policy object needs a distinct question for this:

```ruby
policy.export_upstream_after_local_approval?(job)
policy.upstream_export_mode(job) # per_job_pr, branch_pr, none
policy.upstream_export_target_branch(job)
```

This keeps "B approved job, open PR to A" separate from "promote my development
branch toward canonical." They are related, but not the same operation.

### Story 9: Casual Open Source Contributor Sends One Upstream PR

Casey is a casual open-source contributor. Casey does not own `upstream/foo` and
does not share a Syrus instance with the maintainers. Casey adds their fork
`casey/foo` to Syrus, asks Syrus to implement one thing, tests it, and wants to
send a clean PR upstream.

This is the simplest fork workflow:

1. Casey adds `casey/foo`.
2. Syrus detects or Casey configures `upstream/foo` as upstream source.
3. A job runs in Casey's fork.
4. Casey reviews the result locally.
5. Syrus opens a PR from Casey's job branch to upstream.

There is no requirement that Casey maintain a long-lived development branch.
There is no branch promotion. There is no expectation that upstream runs Syrus.

Repository settings:

```yaml
repository: casey/foo
upstream_source: upstream/foo
```

Shared `.syrus.yml` can stay strict:

```yaml
delivery:
  tracks:
    default:
      branch: main

  upstream_export:
    enabled: true
    mode: per_job_pr
    after_local_approval: true
    target: upstream_default
```

What happens:

- Syrus creates a branch in `casey/foo`.
- Local approval means Casey is satisfied enough to submit upstream.
- Syrus opens or updates one PR:

```text
casey/foo:syrus/job-123 -> upstream/foo:main
```

- Upstream maintainers review using their normal process.
- If upstream asks for changes, Casey can let Syrus process PR feedback on the
  same job branch and update the same upstream PR.

This story is intentionally lighter than the collaborator/fork model. It needs
only the current repository, upstream source, and per-job upstream export.

### Story 10: A Maintainer Ingests Three Different Upstream PR Shapes

Morgan maintains `morgan/foo`. Three PRs arrive:

1. Robin manually wrote a PR from `robin/foo:fix-login`.
2. Casey used Syrus to export one job from `casey/foo:syrus/job-123`.
3. Bob used Syrus to export his whole `develop` branch from `bob/foo:develop`.

All three are upstream PRs, but they should not be treated identically.

Repository settings:

```yaml
external_pr_ingest_enabled: true
```

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: main

external_prs:
  ingest:
    enabled: true
    unknown: review_and_grade
    syrus_job_export: attach_or_create_job
    syrus_branch_export: create_epic
```

What happens:

- Robin's manual PR becomes an external PR ingest Job. Syrus grades it and can
  ask an agent to summarize/test/repair, but it cannot assume prior Syrus
  context.
- Casey's PR is recognized as a one-job Syrus export. If the referenced Job is
  visible on the same instance, Syrus links to it; otherwise it creates a local
  imported Job with provenance.
- Bob's branch PR is recognized as a branch export. Syrus creates or updates an
  Epic-like review surface so the maintainer can review the batch coherently
  instead of seeing it as one opaque blob.

The first iteration can keep branch export coarse: one umbrella Job or Epic with
the PR diff. Later, if exported PRs carry structured job manifests, Syrus can
split them into child Jobs.

### Story 11: Bob Explicitly Sends One Job Or One Branch Upstream

Bob has a fork `bob/foo` with upstream source `alice/foo`. Bob does not want
every locally approved job to automatically open an upstream PR. Sometimes he
wants to experiment locally, and sometimes he wants to send work upstream.

Bob wants two explicit actions:

1. "Send this job PR upstream."
2. "Submit my `develop` branch upstream."

Repository settings:

```yaml
repository: bob/foo
upstream_source: alice/foo
```

Shared `.syrus.yml`:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    release:
      branch: main

  upstream_export:
    enabled: true
    after_local_approval: false

  ref_movement_actions:
    send_job_upstream:
      enabled: true
      source: { kind: job_branch }
      target: { kind: upstream_intake }
      mode: manual_pr
      grade_phases: [promotion]

    submit_branch_upstream:
      enabled: true
      source: { kind: track, name: default }
      target: { kind: upstream_intake }
      mode: manual_pr
      grade_phases: [promotion]
```

What happens:

- Local approval lands jobs into Bob's development branch.
- Nothing is sent upstream automatically.
- If Bob chooses "Send this job PR upstream," Syrus opens a PR from that job's
  branch to Alice's intake branch.
- If Bob chooses "Submit development branch upstream," Syrus opens a branch PR
  from `bob/foo:develop` to Alice's intake branch.
- Both actions are durable workflows and can run promotion graders first.

This story proves automatic upstream export should be optional. The cross-repo
case is just one resolved form of the broader ref-movement action mechanism.

## Cross-Check Against The Stories

The examples suggest a simpler first model than a fully generic role system.

Required now:

- no `delivery:` section remains fully backward compatible through normalized
  defaults.
- explicit `tracks` config, with a `default` track that preserves current
  behavior when it targets the repository default branch.
- local development/release split expressed as separate tracks, not as a preset.
- job-level delivery-track selection, with a `hotfix` track that can land
  straight to the release branch.
- current repository as the writable working repo.
- existing `upstream_source` as canonical when present.
- one promotion block, shaped internally as source ref to target ref.
- one hotfix-sync block, initially release-to-development.
- grade phase selection by policy, with commands staying in `grade.steps`.
- a job approval policy that can require owner approval plus N peer approvals.
- an upstream export policy that can open one PR to canonical per locally
  approved job.
- a PR ingestion classifier that distinguishes unknown external PRs, one-job
  Syrus exports, branch exports, promotion PRs, and hotfixes.
- explicit ref-movement actions that reuse upstream export, branch export,
  promotion, hotfix-sync, and cross-repo submission primitives.

Not required yet:

- named remote roles in `.syrus.yml`;
- arbitrary remote mappings;
- multiple promotion stages in the first UI/API;
- per-user fork names in config;
- skill-per-repository delivery implementations;
- complex approval roles beyond owner/peer/maintainer counts;
- arbitrary export targets beyond current repository and existing upstream
  source;
- fully reconstructing child Jobs from branch-export PRs without explicit
  metadata.

## Later Additions

These topologies are interesting enough to preserve design space, but they
should not drive the first implementation.

### Release Trains And Versioned Release Branches

Projects may cut versioned release branches from trunk and then selectively
cherry-pick jobs, epics, or individual fixes into one or more release branches.
This should be a simple extension of ref movement:

```text
job or epic -> release/2.3
job or epic -> release/2.4
```

The later addition is mostly target selection and cherry-pick support. The
first-iteration requirement is only that ref movement does not assume exactly
one release branch or exactly one hotfix target.

### Manually Or Agentically Triggered Environment Promotion

Environment branches like `develop -> staging -> production` are mostly outside
Syrus's core scope when they represent deployment environments rather than code
integration policy. They can still fit as explicit ref-movement actions if an
operator or skill triggers them manually.

This reinforces the need for actions to be callable by MCP tools, not only from
hardcoded UI buttons.

### Monorepos And Component Boundaries

Syrus is already a small monorepo: Rails web app, Go CLI, and future mobile
shells are separate components with different tooling. Large monorepos need
grader and test selection beyond "changed files under this directory."

Future policy may need component/language-aware detection supplied by plugins:

- changed files;
- lockfiles and build manifests;
- language runtime boundaries;
- package/workspace ownership;
- binary or deployable component ownership;
- repository-specific component detectors.

The first iteration should keep grader phase selection separate from grader
applicability. `grade.steps[].when_files_changed` is useful but should not be
the only mechanism forever.

### Downstream Fork Sync

There is already a narrow fork-sync primitive:

- `Repository#fork_auto_sync_enabled`;
- `SyncEnabledForksJob` every 15 minutes;
- `SyncForkJob`;
- `ForkSyncService`, which uses GitHub's merge-upstream API.

That keeps a fork's default branch fresh from an in-instance upstream. It is
not a full downstream-fork delivery model. Future downstream support should
model periodic pulls as explicit or scheduled ref-movement actions so they can
have source/target refs, audit, conflict repair, graders, and optional PRs.

### Patch-Queue Transports

The interesting part of patch-queue workflows is not email. It is the
decoupling of "review artifact" from "GitHub PR." The durable primitive should
still be source ref or patch set -> validation -> target ref or review artifact.
GitHub PR should be one transport, not the only possible one.

## MCP And Agent Tooling

The delivery model should be operable from chat sessions and skills. UI actions
are not enough, especially for repo-specific release judgment.

Useful MCP tools to add:

- `list_delivery_tracks(repository)` — show normalized tracks, grade phases,
  and current branch health.
- `resolve_delivery_policy(repository, job_id: nil)` — explain what policy
  applies, including selected track, target ref, approval requirements, and
  enabled actions.
- `select_job_delivery_track(job, track)` — set or change a job's intended
  delivery track before approval/landing.
- `list_ref_movement_actions(repository, job_id: nil)` — show allowed actions
  and why unavailable actions are blocked.
- `dispatch_ref_movement_action(action, source, target, options)` — create the
  durable workflow for upstream export, branch export, promotion, hotfix sync,
  backport, or future release-train cherry-pick.
- `read_ref_movement_status(workflow_or_action_id)` — inspect source/target
  refs, current step, validation results, opened PRs, and blockers.
- `classify_pull_request(repository, pr_number)` — return Syrus's PR
  classification and supporting evidence.
- `ingest_pull_request(repository, pr_number, classification: nil)` — manually
  ingest or reclassify a PR when automatic heuristics are insufficient.
- `list_component_detectors(repository)` — show component/language detectors
  contributed by plugins.
- `explain_grader_selection(job_or_ref, phase)` — explain which graders would
  run and why each grader was included or skipped.
- `list_release_targets(repository)` — list configured and recently observed
  release branches that can be selected for backport/release-train actions.

For GitHub inspection-heavy skills, agents should also have `gh` available when
the operator permits it. `gh` is useful for reading labels, milestones,
discussions, CI, merge bases, and branch metadata. Mutations that should be
tracked by Syrus should still go through Syrus MCP tools or explicit
ref-movement actions whenever possible.

The minimal shared config remains:

```yaml
delivery:
  tracks:
    default:
      branch: main
```

Owner-plus-peer approval is an optional overlay:

```yaml
approval:
  job:
    required:
      owner: true
      peer_count: 1
```

A development-branch repo can combine both:

```yaml
delivery:
  tracks:
    default:
      branch: develop
    hotfix:
      branch: main
      grade_phases:
        landing: promotion
      after_landing:
        sync_to: default

  job_approval:
    lands_to: selected_track

  promotion:
    enabled: true
    mode: auto_pr
    approval_required: false
    grade_phases: [promotion]

  hotfix_sync:
    enabled: true
    mode: auto
    grade_phases: [promotion]

  upstream_export:
    enabled: true
    mode: per_job_pr
    after_local_approval: true

  ref_movement_actions:
    send_job_upstream:
      enabled: true
      source: { kind: job_branch }
      target: { kind: upstream_intake }
      mode: manual_pr
    submit_branch_upstream:
      enabled: true
      source: { kind: track, name: default }
      target: { kind: upstream_intake }
      mode: manual_pr

external_prs:
  ingest:
    enabled: true
    unknown: review_and_grade
    syrus_job_export: attach_or_create_job
    syrus_branch_export: create_epic

approval:
  job:
    required:
      owner: true
      peer_count: 1
```

Everything else can be defaulted.

The key simplification is that `.syrus.yml` names tracks, branches, and abstract
actions. Repository settings and existing upstream-source data resolve where
those branches live. Approval config names relationships to the job and
repository, not concrete users, so it remains shared across collaborators and
forks.

## Current Implementation Debt

Several pieces already exist, but they encode delivery policy implicitly in
models, pollers, and workflow steps. The delivery-track work should keep the
useful primitives and replace the hidden policy.

Useful foundations:

- `Repository#upstream_repository` and upstream-source metadata are useful as
  the default canonical target signal.
- `PullRequestOpener` already supports cross-repository PRs through a separate
  head repository.
- Review policies (`self`, `two_person`, `final_say`) are useful foundations
  for owner-plus-peer approval.
- `grade.phases` plus grader-level `failures: strict|allow_inherited` is the
  right shape for branch-health and inherited-failure decisions.
- External PR ingestion is a useful primitive, but it needs classification.

Replace or remove:

- Fork review mode is the biggest half-built policy. Today
  `target_repository_id`, `pr_repository_id`, `fork_review_pr_number`,
  `PollForkReviewPrJob`, and `ForkReviewApprover` approximate "approve locally,
  then send upstream" with a staging PR. New work should stop creating this
  path and replace it with explicit upstream-export workflows/actions.
- `Job#target_branch` is only a low-level branch override. It should not be the
  delivery model. Jobs should carry a selected `delivery_track`, and policy
  resolution should produce the concrete target branch/ref.
- Fork base selection currently happens implicitly through `JobStackBase`:
  fork-syncable jobs tend to base on upstream default unless fork-review mode
  says otherwise. Base and target refs should instead come from the resolved
  delivery policy.
- Main-branch health and repair are hardcoded around the repository default
  branch. This should become branch/track health. Default-branch repair remains
  useful, but blocking, repair creation, priority, and grader phase should be
  policy driven.
- `LandingGraderPlan` maps trigger kinds directly to `review`, `landing`, or
  `ci`. That should be replaced with policy-backed phase resolution, including
  custom phases such as `review_minimal`, `promotion`, and `hotfix_sync`.
- `AppSetting.merge_train_enabled` is a hidden global gate. Merge train should
  either be always available or controlled by repository/delivery policy.

Significant schema and runtime changes:

- Add first-class workflow trigger kinds for promotion, hotfix sync, and
  upstream export. These should not be disguised as auto-merge,
  external-PR ingest, or fork-review flows.
- Add a durable PR-link model. The current single-purpose columns
  (`pr_number`, `external_pr_number`, `fork_review_pr_number`,
  `pr_repository_id`) are overloaded once a job can have local PRs, upstream
  export PRs, promotion PRs, and ingested external PRs. A PR link should carry
  role, source repository/ref, target repository/ref, provider number, and
  classification metadata.
- Add a normalized `DeliveryPolicy` layer. Runtime code should ask policy
  questions like `job_delivery_track(job)`, `landing_target(job)`,
  `review_grade_phase(job)`, `landing_grade_phase(job)`,
  `promotion_enabled?`, and `upstream_export_mode(job)` instead of reading raw
  `.syrus.yml` or repository columns directly.
- Generalize landing queues by target ref/track. Current landing is effectively
  repository/default-branch oriented; delivery tracks require the queue key to
  come from the resolved target.
- Rework approval semantics so approval has explicit scope: local track
  approval, upstream-export approval, promotion approval, or hotfix approval.
  Existing review-policy implementations can power this, but they should not
  define delivery side effects directly.
- Classify external PRs as unknown manual PRs, Syrus one-job exports, branch
  exports, promotion PRs, or hotfixes. Use structured Syrus metadata first and
  heuristics only as fallback.
- Add a ref-movement action dispatcher for actions such as "send this job
  upstream," "submit this branch upstream," "promote development to release,"
  and "sync release hotfixes back to development." Each action should be a
  durable workflow with source/target refs, audit, retry behavior, and optional
  configured graders.

Migration posture:

- Do not remove external PR ingest yet. Refactor it after PR links and PR
  classification exist.
- Do not remove `target_branch` immediately. Route new behavior through
  delivery-track selection and keep `target_branch` as legacy storage or an
  explicit escape hatch until existing jobs are migrated.
- Do not delete fork-review columns in the first pass. Stop creating new
  fork-review flows, add upstream export, then migrate or retire legacy rows.

## First Iteration Proposal

1. Add a delivery config parser that understands:
   - `tracks`;
   - `promotion`;
   - `hotfix_sync`;
   - `upstream_export`;
   - `ref_movement_actions`.
   It should always return a normalized delivery object, even when the raw
   `.syrus.yml` has no `delivery:` section.

2. Add an approval policy parser that understands owner-plus-peer local
   approval:
   - owner approval required or optional;
   - peer approval count;
   - separate promotion approval count.

3. Keep current behavior as the implicit default when no delivery block exists:
   one `default` track targeting the repository default branch, current review
   and landing phases, and no promotion/hotfix/export actions.

4. Teach job PR opening and landing to use `policy.job_landing_branch(job)`.

5. Add job-level delivery-track selection:
   - persist selected track on Job;
   - expose it in direct job/chat job/API creation;
   - default to the delivery config's `default` track;
   - support `hotfix` as release-branch target with promotion-grade landing.

6. Teach approval checks to ask policy whether the job has enough local
   approvals before entering landing.

7. Add derived delivery status:
   - distinguish waiting for local approval from waiting for upstream approval;
   - keep jobs open until the policy-defined terminal target is satisfied;
   - surface delivery-needs-attention when an upstream/export/promotion PR is
     closed or blocked.

8. Add upstream export workflow:
   - after local approval, open/update a PR from the approved job branch to the
     canonical repository's intake branch;
   - default canonical to existing `upstream_source`;
   - target A's configured development branch when A uses one, else A's default
     branch.

9. Add PR ingestion classification:
   - classify unknown external PRs, one-job Syrus exports, branch exports,
     promotion PRs, and hotfixes;
   - use structured metadata first, heuristics second;
   - attach one-job exports to visible Jobs when possible;
   - treat branch exports as an umbrella review unit initially.

10. Add ref-movement action dispatcher:
   - support `send_job_upstream`;
   - support `submit_branch_upstream`;
   - use existing upstream-source data for canonical target;
   - persist source/target refs and opened PRs for audit.

11. Add promotion workflow as a named ref-movement workflow:
   - assemble source branch into target branch;
   - run promotion graders;
   - push directly or open/update an auto-merge PR;
   - use repair skill on conflicts/failures if configured;
   - persist resolved source/target refs.

12. Add hotfix sync workflow as a named ref-movement workflow:
   - detect release branch commits missing from development branch;
   - sync release into development;
   - use repair skill if needed;
   - persist resolved source/target refs.

13. Keep upstream-source support narrow:
   - current repository is working repo;
   - upstream source is canonical;
   - promotion to upstream uses PR from current repository.

14. Add repository UI surfaces:
   - tracks table with branch/ref, grade phases, health, queue length, and last
     promotion/sync;
   - repository/track ref-movement actions and blocked reasons;
   - recent ref-movement workflows;
   - PR ingestion classifications.

15. Add job UI surfaces:
   - selected track and target ref;
   - PR links grouped by role;
   - job-specific actions such as `send_job_upstream`;
   - delivery status copy such as "Waiting for local approval", "Sent
     upstream: PR #123 waiting for review", and "Upstream merged".

16. Add dashboard discoverability:
   - waiting for upstream;
   - delivery needs attention;
   - promotion pending/running;
   - track-specific landing queues when needed.

## Open Questions

- Should promotion be manually triggered, scheduled, or automatic after branch
  health is green for some window?
- Should a fork default to branch-level promotion or per-job promotion?
- Should development-branch landing allow broken branch health if failures are
  inherited, or should that be a separate policy option?
- How should branch repair jobs be prioritized relative to ordinary jobs?
- Should hotfix sync be direct-push when working repo is canonical, but PR-based
  when working repo is a fork?
- How should release notes be generated: from jobs, commits, promotion PR body,
  or a skill?
- Should owner-plus-peer approval live in `.syrus.yml`, repository settings, or
  both with repository settings allowed to be stricter?
- If canonical A and fork B both have different delivery policies on the same
  Syrus instance, where should B's upstream export discover A's intake branch:
  A's stored repository settings, A's `.syrus.yml`, or a small explicit
  repository setting?
- What structured metadata should Syrus include in exported PR bodies so
  upstream ingestion can classify them without brittle branch-name heuristics?
- Should `send_job_upstream` be allowed before local landing, or only after the
  job is locally approved/landed?
- Should `hotfix` always imply promotion-grade landing, or should each track
  explicitly declare its landing grade phase with no special-case defaults?

## Design Principle

Keep approval local, promotion explicit, and policy extensible.

The safest mental model is:

```text
Job approval lands into my configured working track.
Promotion moves a track toward canonical/release.
Hotfix sync keeps development from diverging after urgent release fixes.
```
