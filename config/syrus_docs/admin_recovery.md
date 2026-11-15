# Admin Recovery

Admin Job and Epic payloads expose `proposer` as either `null` or an object
with `type`, `id`, `label`, and `handle`. Filter list endpoints with a bare
handle such as `proposer=adrian`; an unknown handle returns an empty list. The
CLI exposes the same filter through `--proposer` on Job and Epic lists.

Syrus exposes narrow admin-only recovery actions for open Jobs stuck outside
normal workflow state propagation:

- `force_fail_job(job_id:, reason:)` force-fails the
  active execution records after confirmation. Use it only when normal
  cancellation or failure propagation cannot finish.
- `close_job_successfully(job_id:, closure_reason:, comment:)` closes an
  implemented Job without landing a PR. The usual recovery reason is
  `no_changes`.
- `explain_stuck_job(job_id:)` is read-only. It reports the blocking layer and
  recommended repair before an operator chooses a mutation.
- `repair_queue_affinity` repairs eligible unclaimed queued Runs assigned to a
  dead explicit worker or resume queue. It accepts one `run_id`, up to 100
  `run_ids`, or `detector_scope: true`, and revalidates every Run at
  confirmation time.
- `override_job_planned_execution(job_id:, profile:, reason:)` replaces an
  eligible Job's mutable implementation-workspace placement profile and retries placement.
  It does not change immutable grader-target capability requirements.

The stale-Run reaper handles Runs whose worker lease disappeared and asks the
normal state machines and work engine to fail or repair the affected work.
Recovery actions write durable audit records with actor, target, reason, and
outcome. Solid Queue execution remains asynchronous; a successful recovery
request means the repair was accepted, not that every downstream transition
has already completed.

Restart mechanics and deployed recovery procedures live in [admin recovery
operations](../../docs/engineering/operations/admin-recovery.md). Admin React
mutation-feedback internals live in [admin recovery
architecture](../../docs/engineering/architecture/admin-recovery.md).
