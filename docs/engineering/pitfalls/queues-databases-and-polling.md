# Queue, database, and polling pitfalls

## Enqueuing RunJob directly

**Symptom:** duplicate execution or a Run that disagrees with Step/Workflow
state. **Cause:** a poller or service bypassed `StepDispatcher` and the Run
creation callback. **Prevention:** create/advance domain state and let the
dispatcher plus `Run#after_create_commit` enqueue execution.

## Declaring an unconsumed queue

**Symptom:** a job remains queued although workers are healthy. **Cause:** its
`queue_as` has no deployed consumer. **Prevention:** use a configured queue and
keep the architecture queue specs passing. An explicit declaration and a
deliberately inherited `ApplicationJob` queue are both valid; an unreviewed
inheritance assumption is not.

## Reading guarantees from a historical foreign key declaration

**Symptom:** cleanup or query code assumes the database rejects orphaned rows.
**Cause:** an old migration contains foreign-key syntax even though current
schema statements and dumps suppress database foreign keys. **Prevention:**
treat `config/initializers/foreign_keys.rb` as policy, use associations plus
ordered cleanup and repair paths, and test deletion behavior at the application
boundary.

## Treating a SQLite partial index as a MySQL invariant

**Symptom:** duplicate rows appear in production despite a local uniqueness
test. **Cause:** the SQLite schema dump contains a predicate-backed unique index
without a MySQL-native equivalent. **Prevention:** do not publish cross-adapter
uniqueness until the MySQL design and adapter tests enforce it.

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

## Retrying an entire Run after a lifecycle lock wait

**Symptom:** an agent, push, review, grader, or merge side effect runs twice
after MySQL reports a lock-wait timeout. **Cause:** retry was attached to the
whole `RunJob` instead of the persistence operation following the side effect.
**Prevention:** retry only the idempotent lifecycle transaction. Execution
acquisition locks the `runs` row and then advances its Workflow, Step, Run, and
Job timestamps; completion atomically advances the Run and Step and invokes
their propagation callbacks. Concurrent lifecycle propagation and operator
actions can therefore contend on those rows on both the `runs` and `merges`
queues. `RunJob#with_lifecycle_lock_retry` is the bounded boundary for those
writes. Its MySQL concurrency spec holds the Run row from another connection
to reproduce the contention. Never replace it with `retry_on` around
`perform`, because handlers contain external and expensive side effects.

Dashboard bulk mutations deliberately return the stable
`bulk_jobs_lock_conflict` response when a lock conflict escapes their
per-Job operation. The client may retry the request; actions must remain
idempotent or skip Jobs already moved to the requested state.
