# Epicless Job Bundling

When `epicless_job_bundling` is enabled, the landing queue may combine eligible
approved Jobs that do not belong to an Epic into one atomic merge train. The
feature is off by default.

## Assembly

Syrus considers one priority tier at a time, starting with the highest. Jobs
must share a repository, owner, base branch, and compatible landing policy;
must have no dependencies, active workflow, or existing train; and must be
approved and otherwise ready to land. A bundle contains at least two Jobs and
never crosses owners or priority tiers. The configured maximum size caps each
bundle.

## Dispatch and failure behavior

Members are locked and ordered deterministically, then use the same build,
reconciliation, grader, repair, and atomic land phases as an Epic merge train.
Only one landing unit—Epic train, Job bundle, or solo Job—occupies a repository
landing slot at a time.

A genuine validation failure returns affected Jobs to implemented and clears
approval. Transient infrastructure and stale-base conditions defer members to
approved so they can retry. A 30-minute cooldown prevents deterministic bundle
failures from churning; transient start blockers and stale-base rebuilds may
retry as soon as their condition clears.

Only the final integrated tip is graded. Intermediate rebased member commits
and reconciliation commits may not independently pass.

## Speculative validation and dashboard

Eligible bundles can use speculative landing validation, with cache identity
kept separate from Epic trains. The landing queue visually groups dispatched
bundle members and distinguishes them from consecutive standalone Jobs.

See [Epic Merge Trains](merge_train.md) for the shared phase behavior.
