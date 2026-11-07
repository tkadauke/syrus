# Queue, database, and polling pitfalls

## Enqueuing RunJob directly

**Symptom:** duplicate execution or a Run that disagrees with Step/Workflow
state. **Cause:** a poller or service bypassed `StepDispatcher` and the Run
creation callback. **Prevention:** create/advance domain state and let the
dispatcher plus `Run#after_create_commit` enqueue execution.

## Declaring an unconsumed queue

**Symptom:** a job remains queued although workers are healthy. **Cause:** its
`queue_as` has no deployed consumer. **Prevention:** use a configured queue and
keep the architecture queue specs passing.

## Treating unavailable content as absent

**Symptom:** an outage is cached or displayed as “file not found.” **Cause:** a
`RepositoryContent::Unavailable` result was collapsed into `NotFound`.
**Prevention:** preserve provider result semantics and allow only eligible
failures to fall through.

## Assuming SQLite equals MySQL

**Symptom:** a migration or query passes locally and fails during production
rollout. **Cause:** database-specific defaults, indexes, locking, or SQL.
**Prevention:** follow migration checks, avoid JSON column defaults on MySQL,
and design idempotent, rollout-compatible changes.

## Ignoring polling watermarks

**Symptom:** repeated feedback Workflows or missed follow-up events. **Cause:**
a poller updated state without its durable seen/handled watermark, or compared
only one timestamp. **Prevention:** make discovery idempotent and update the
owning watermark atomically with accepted work.
