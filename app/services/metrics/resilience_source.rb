module Metrics
  # The only place that touches ProviderCircuitBreaker/Installation/User/
  # Repository for the "Resilience" metric group: three failure modes that are
  # each documented in CLAUDE.md as having already happened in production and
  # being invisible outside a Rails console -- the same "everything looks fine
  # except the one number that matters" shape as the queue-backlog incident
  # that motivated the whole metrics plan (see docs/plans/complete/prometheus-dashboard.md).
  class ResilienceSource
    # Every registered agent provider, not just the ones a User has actually
    # configured -- the same "publish a known key even when it has nothing to
    # report" instinct as Metrics::ProductUsage.preset_all!, so a provider
    # that is closed reads as an explicit 0 rather than an absent series.
    def provider_circuit_states(now: Time.current)
      User.agent_providers.index_with do |provider|
        decision = ProviderCircuitBreaker.call(provider, now: now, include_logs: false)
        next :closed unless decision.open?

        decision.usage_limit? ? :usage_limit : :open
      end
    end

    # The lowest observed `gh_rate_limit_remaining` per credential mode --
    # worst case is the informative one, since a single exhausted
    # installation or user token can stall polling for everything it
    # authenticates just as effectively as an instance-wide exhaustion would.
    # `app` reads from Installation (GitHub App auth), `pat` from User
    # (personal access token auth) -- see GithubClient#rate_limit_subject.
    # Subjects that have never made a tracked GitHub call yet have a nil
    # column and are excluded rather than reported as 0, the same
    # "unobserved is not zero" instinct QueueSampler's guard uses.
    def github_rate_limit_remaining
      {
        "app" => Installation.active.where.not(gh_rate_limit_remaining: nil).minimum(:gh_rate_limit_remaining),
        "pat" => User.where.not(gh_rate_limit_remaining: nil).minimum(:gh_rate_limit_remaining)
      }.compact
    end

    # Repositories whose default branch is currently graded broken --
    # StepDispatcher pauses every workflow on the instance, including
    # landing, while any of these exist (see CLAUDE.md "Main-branch health &
    # repair"). Reuses Repository#main_health_broken? itself, selecting only
    # the columns that predicate reads, rather than re-deriving the
    # ci_health/grader_health/enabled logic here where it could drift from
    # the real definition.
    def main_branch_broken_repository_count
      Repository.select(:id, :main_branch_health_enabled, :ci_health, :grader_health)
                .count(&:main_health_broken?)
    end
  end
end
