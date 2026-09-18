# Provider Routing

`ProviderRoutingRule` (`app/models/provider_routing_rule.rb`) and
`ProviderRouting::Resolver` (`app/services/provider_routing/resolver.rb`)
replace the old single-value provider defaulting
(`Repository#effective_agent_provider`, `Job::ProviderSetting::Default`) with
an ordered, user-authored fallback chain of `{provider, model,
effort_level}` candidates, scoped to a user or repository and keyed by task
(normally a Workflow's `trigger_kind`, e.g. `initial`, `pr_comment`,
`ci_failure`).

## Resolution order

`ProviderRouting::Resolver.call(job:, task_key:)` returns an ordered
candidate list, walking:

1. **Job override** — when the Job has switched away from the `default`
   provider setting (`Job#job_provider_setting_default?` is false), the
   Job's own `workflow_agent_provider`/`model`/`effort_level` is the single
   candidate. This is the deepest scope: no rule or availability failover
   ever overrides an explicit Job-level pin.
2. **Repository rule, exact `task_key`**
3. **Repository rule, `task_key: "default"`**
4. **User rule, exact `task_key`**
5. **User rule, `task_key: "default"`**
6. **Hardcoded fallback** — a single `claude` candidate, when nothing above
   applies. A freshly onboarded operator with no configured
   `ProviderRoutingRule` gets this fallback rather than whatever
   `User#agent_provider` happens to be set to; configure a `default`-task
   `ProviderRoutingRule` to restore a personal/repo-wide default.

## Availability-aware selection

`ProviderRouting::AvailableCandidate` (`app/services/provider_routing/available_candidate.rb`)
wraps the resolver with the same "is this provider usable right now" check
`ProviderFailoverSelector` used (extracted into
`ProviderRouting::AvailabilityCheck` so both share one definition): it walks
the resolver's candidate list and returns the first candidate that isn't
paused, circuit-open, or usage-exhausted per `App::ProviderAvailability`
(which itself folds in `ProviderCircuitBreaker`). When every candidate is
unavailable, it returns the top (most preferred) candidate anyway so the
normal provider-availability pause-and-backoff (`ProviderAvailabilityPause`,
`StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON`) still applies against
it.

This selection runs at three points:

- **`Workflows::Base.instantiate`** — resolves the Workflow's initial
  `agent_provider`/`model`/`effort_level` when the caller didn't pass an
  explicit `agent_provider:` (an explicit argument, e.g. an operator-chosen
  retry provider, always wins outright and skips resolution).
- **`StepDispatcher.refresh_default_workflow_agent_provider!`** — re-derives
  the workflow's `agent_provider` before its first Run, for a Job still on
  the `default` provider setting. Only `agent_provider` is re-derived here;
  `model`/`effort_level` are set once at instantiate time and left alone
  afterward even if the resolver's pick has since changed.
- **`StepDispatcher.apply_provider_failover!`** — when
  `ProviderAvailabilityPause` is about to pause the workflow because its
  current provider is unavailable, this re-walks the resolver's candidate
  list for an alternate that's available now, instead of trusting the
  legacy `ProviderFailoverSelector`-derived pick.

Both `StepDispatcher` methods share the same "pinned once a Run starts"
invariant as before: once any agentic Run exists on the workflow, its
`agent_provider` is frozen for the rest of the workflow.

## Step-level overrides

A handful of step kinds can be routed independently of the workflow's own
provider — for example, always running `adversarial_review` through a
specific provider regardless of what `implement`/`respond` use.
`ProviderRouting::StepTaskKey` (`app/services/provider_routing/step_task_key.rb`)
lists which step kinds support this (`adversarial_review` today) and only
activates it when a `ProviderRoutingRule` actually exists for that step's
own task_key (its `kind`, e.g. `"adversarial_review"`) at repository or user
scope — a rule at the `default` task_key tier does not count as a
step-level override. When one exists, `StepDispatcher.create_run_and_enqueue`
resolves that step's own availability-aware candidate and uses it for the
Run being created, leaving the Workflow's own `agent_provider`/`model`/
`effort_level` columns untouched so every other step keeps using the
workflow-kind default. This only applies to a step's own first Run — a
retried Run on the same Step keeps whatever provider its earlier Run
already used.
