# Coworker review

The dedicated coworker review gate adds organizational judgment to automated
code review without treating an automated verdict as human approval. It is
off unless a repository explicitly enables it:

```yaml
coworker_review:
  enabled: true
  rounds: 2
  required: true
  criteria:
    - Check that the change fits the repository's operating model
    - Identify rollout or support risks not covered by technical checks
```

This top-level key is retained as a compatibility alias for the Coworkers
plugin's versioned repository-configuration contribution. When Coworkers is
disabled or unavailable, the generic configuration contract diagnoses the
owner without materializing live plugin behavior.

For an enabled gate, `rounds` is bounded from 1 through 10. An explicitly
disabled gate may use `rounds: 0`. `required` defaults to `false` and uses
the same unavailable-review semantics as the other automated gates: an
optional gate may record a skip for an eligible transient review failure,
while a required gate fails. Configuration and routing errors fail
deterministically in either mode.

Provider-routing rules for the `coworker_review` step select one or more actual
coworkers. Every selected panel member must have a valid coworker target; Syrus
never substitutes an ordinary provider reviewer when no coworker rule matches.
The rule may still choose the provider, model, effort, and panel consensus used
to run those coworkers.

The Job routing panel deliberately presents these as two independent layers:
effective `.syrus.yml` configuration says whether the repository gate runs and
which criteria apply, while installation-local rules say which named coworker
and provider/model execute it. Workflow evidence identifies both identities and
shows reviewed SHAs, the canonical diff hash, safe context-manifest metadata,
verdict or typed failure, stale state, Run cost, and the durable-memory receipt.
Owners and admins may follow the restricted-evidence action; every access is
audited, and the normal payload never includes raw protected context or
unrelated coworker memory.

The gate runs after adversarial and security review and before visual review
and graders. A `needs_work` verdict feeds concrete findings into the existing
repair loop. `approved` ends the loop. Each opinion is bound to immutable
review evidence, and a coworker must successfully persist its reviewer memory
before its review can succeed. Panel collection applies the configured
consensus after every member finishes.

The evidence panel also pairs a `needs_work` opinion with the following repair
Run's response and cost. Its journal and restricted-context links are supplied
only for the coworker's owner or an instance admin; the client does not derive
plugin URLs or show an action that will predictably be forbidden. The journal
endpoint returns only that review's durable entry. Restricted-context reads are
separate, explicitly labelled, and recorded as administrative actions.

Concurrent memory updates use the coworker's normal workspace conflict
recovery: Syrus rebases the isolated update and retries a compatible merge.
Conflicts that cannot be reconciled produce the typed
`coworker_memory_persistence_failed` failure and keep the review Step from
succeeding. Retrying the Step starts from the durable workspace state rather
than accepting an unpersisted verdict.

Pausing prevents new work without discarding already recorded evidence. A retry
reauthorizes the coworker target and creates fresh SHA-bound evidence when the
diff changed; stale evidence cannot satisfy the gate. Retention tombstones the
encrypted protected context and its temporary workspace according to the
configured coworker-review retention period while leaving the safe audit
record and durable journal receipt intelligible.

Root criteria apply repository-wide. A nested project's criteria are included
only when the reviewed changes affect that project. Coworker review remains an
automated quality gate: neither an individual approval nor panel consensus
satisfies repository human-approval policy.

## Data ownership and storage

The Coworkers plugin owns the review-context table (`coworker_review_contexts`),
its retention, the isolated home-workspace checkout, journal updates, and the
persistence receipt. Core's review evidence holds only opaque envelopes: an
immutable safe snapshot of the reviewer target, a write-once safe context
manifest (hashes and sizes, never prompt text), and a write-once persistence
receipt. There is no database foreign key between the two, so evidence can be
purged, or the plugin removed or disabled between iterations, without breaking
either side. Historical reviews keep rendering from the evidence snapshot;
operator links simply disappear while the plugin is unavailable.

Preparation and persistence are idempotent: a retried Step reuses the existing
context (unique per evidence) and the evidence's recorded receipt prevents a
second journal update. Concurrent writers are detected with optimistic locking;
a context that another writer already persisted counts as success, and any other
conflict surfaces as the typed `coworker_memory_persistence_failed` failure.
New evidence writes only the target envelope. Rows from before the envelope
existed are read through the legacy reviewer reference until the plugin's
ownership migration backfills their envelopes.
