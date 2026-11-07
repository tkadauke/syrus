# Architecture details (compatibility pointer)

Current architecture documentation now lives under
[`docs/engineering/architecture/`](../../docs/engineering/architecture/README.md).
Use [ARCHITECTURE.md](../../ARCHITECTURE.md) for the system-wide overview.

## Coworker review evidence and audit surfaces

Automated review keeps three identities separate: the review kind, an optional
named persistent coworker, and the provider/model executing the read-only Run.
The dedicated coworker gate is enabled by effective repository `.syrus.yml`;
installation-local provider rules choose its coworker or panel. Neither a
provider verdict nor coworker consensus satisfies human approval policy.

`ReviewEvidence` binds each opinion to immutable base/head SHAs and a canonical
diff hash. Job-detail serialization projects this evidence with safe context
manifest metadata, typed terminal state, Run cost, the following repair Run's
response, and the coworker's persistence receipt. Reviewer implementations may
contribute authorization-aware operator links; core UI never constructs plugin
routes. Coworker owners and admins can inspect the single durable journal entry
or the separately labelled restricted context, and both reads are audited.
Stale evidence cannot advance a gate. A coworker verdict succeeds only after
its isolated memory update is durably merged; retry reauthorizes the target and
recaptures evidence, while retention tombstones protected context without
removing the safe audit record.
