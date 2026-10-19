# Emergency Land

Emergency land is an incident-response escape hatch for Coding Mode. It can submit the active clean, committed checkout directly, creating its audit Job and immutable pushed branch without dispatching normal automation, or land an eligible existing Job branch.

## Availability

Emergency land is controlled by the `emergency_land` feature flag and is off by default. It is also gated by Coding Mode: the tool is only available from a Coding Mode chat that is linked to a Job currently in the `coding` state.

Simple mode forces the flag off in the same way it disables Coding Mode and Local Mode. Enabling ordinary `coding_mode` is not enough; `Feature.emergency_land_enabled?` must be true.

## Permission

The confirming user must satisfy `EmergencyLand::Permission.granted?(user:, repository:)`, which delegates to `RepositoryPolicy#admin?`.

That means either:

- a global admin user, or
- an admin-tier `RepositoryMembership` for the target repository.

The repository owner gets that membership through the existing owner-membership seeding path. Emergency land does not introduce a new role.

## Confirmation Flow

The `emergency_land` MCP tool never merges code immediately. It creates a `ChatPendingAction` with `action: "emergency_land"` for the operator to confirm or decline in chat. After confirmation, the action remains visibly `confirming` while the chat worker captures and lands the change; only a successful merge marks it `confirmed`, and capture, permission, validation, or GitHub failures durably mark it `failed` with the actionable error.

The pending-action UI renders with warning styling and states the consequence explicitly: Syrus graders, adversarial review, and visual review are skipped, and the PR is about to be merged directly through GitHub. Confirmation re-checks the feature flag, Coding Mode session, branch validity, repository access, and repository-admin permission before landing.

Emergency land is mutually exclusive with the normal `complete_implement_step` handoff for the same Job. Direct submission captures and verifies the checkout HEAD only after confirmation and rejects dirty worktrees, the wrong active branch, empty diffs, or an unverifiable push. Existing Jobs may be in `implemented`, `approved`, `failed`, `queued`, or `coding` when they have a trustworthy recorded branch and no active runtime work.

## What It Skips

Emergency land skips only Syrus's own automation gates:

- CodingHandoff workflow dispatch
- format/generate repair loop
- configured Syrus graders
- adversarial review
- visual review
- summarize/test-plan workflow steps
- landing queue admission and landing graders

It does not skip GitHub or repository mechanics:

- Syrus still opens a normal pull request with `PullRequestOpener` if the Job has no PR yet.
- Syrus merges through GitHub's merge API rather than pushing directly to the default branch.
- GitHub branch protection, mergeability, required checks, repository permissions, and merge conflicts still apply.
- Existing Job branches must already have pushed commits ahead of the repository default branch. Direct checkout submission publishes an immutable emergency branch at the captured HEAD.
- Unsatisfied dependencies, active runtime work, and branches shared by multiple open Jobs are refused.

## Audit Trail

Successful emergency lands close the Job with `closure_reason: "emergency_landed"` and record:

- `emergency_landed_at`
- `emergency_landed_by_user_id`
- `emergency_landed_by_membership_tier`
- `emergency_land_source_sha`
- `emergency_land_skipped_controls` (graders, adversarial review, visual review, admission control, and the normal workflow worker queue)

Operators can audit usage from the Job detail page, which shows the closure reason plus the confirming user, membership tier, and timestamp. Admins can also query the admin Jobs API with:

```text
GET /api/v1/admin/jobs?closure_reason=emergency_landed
```

The dashboard/filter schema includes `closure_reason = emergency_landed`, so shared Job filters can also surface these Jobs.
