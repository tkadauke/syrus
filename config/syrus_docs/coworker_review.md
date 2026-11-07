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

`rounds` is bounded from 1 through 10. `required` defaults to `false` and uses
the same unavailable-review semantics as the other automated gates: an
optional gate may record a skip for an eligible transient review failure,
while a required gate fails. Configuration and routing errors fail
deterministically in either mode.

Provider-routing rules for the `coworker_review` step select one or more actual
coworkers. Every selected panel member must have a valid coworker target; Syrus
never substitutes an ordinary provider reviewer when no coworker rule matches.
The rule may still choose the provider, model, effort, and panel consensus used
to run those coworkers.

The gate runs after adversarial and security review and before visual review
and graders. A `needs_work` verdict feeds concrete findings into the existing
repair loop. `approved` ends the loop. Each opinion is bound to immutable
review evidence, and a coworker must successfully persist its reviewer memory
before its review can succeed. Panel collection applies the configured
consensus after every member finishes.

Root criteria apply repository-wide. A nested project's criteria are included
only when the reviewed changes affect that project. Coworker review remains an
automated quality gate: neither an individual approval nor panel consensus
satisfies repository human-approval policy.
