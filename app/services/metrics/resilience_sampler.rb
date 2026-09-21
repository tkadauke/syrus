module Metrics
  # The "Resilience" metric group: three failure modes named in CLAUDE.md as
  # already having happened in production and staying invisible outside a
  # Rails console until someone went looking by hand -- provider-wide outages
  # (ProviderCircuitBreaker), GitHub API rate-limit exhaustion, and an
  # instance-wide main-branch-broken stall (StepDispatcher::MAIN_HEALTH_BLOCK_REASON).
  #
  # All three are plain GLOBAL gauges sampled on a timer into the cache, the
  # same shape Metrics::QueueSampler/FleetSampler use -- no cursor bookkeeping
  # needed, since none of them is a monotonic count. `ProviderCircuitBreaker.call`
  # runs an aggregate query per provider over the recent Runs table, which is
  # exactly the kind of query that must not run on the scrape path.
  class ResilienceSampler
    CACHE_KEY = "syrus:metrics:resilience_sample".freeze
    CACHE_TTL = 5.minutes

    # ProviderCircuitBreaker only distinguishes closed/open, with "open" split
    # into ordinary transient failures and a usage-limit exhaustion (a
    # different, longer-lived condition -- see ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR).
    # There is no half-open retry-probe state in this codebase to report, so
    # the gauge's three values are closed/open/open-for-usage-limit rather
    # than the classic circuit-breaker triad.
    STATE_VALUES = { closed: 0, open: 1, usage_limit: 2 }.freeze

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :provider_circuit_state, tags: %i[provider],
              comment: "Circuit state per configured agent provider: 0=closed, 1=open, " \
                       "2=open (usage limit exhausted) (GLOBAL -- aggregate with max by, never sum)"
        gauge :github_rate_limit_remaining, tags: %i[credential_mode],
              comment: "Lowest observed GitHub API rate-limit remaining, by credential mode " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        gauge :github_app_rate_limit_remaining_percent,
              comment: "Lowest observed GitHub App installation rate-limit remaining percentage " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        gauge :github_app_api_blocked_count,
              comment: "Active GitHub App installations currently marked API-blocked " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        gauge :repositories_main_branch_broken_count,
              comment: "Repositories whose default branch health is currently broken -- StepDispatcher " \
                       "pauses every workflow instance-wide, including landing, while this is nonzero " \
                       "(GLOBAL -- aggregate with max by, never sum)"
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: ResilienceSource.new)
      @source = source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Writes the
    # sample to the cache; does not touch the gauges -- see
    # Metrics::QueueSampler for why.
    def sample!
      payload = {
        provider_circuit_state: guard("provider circuit state", {}) { source.provider_circuit_states },
        github_rate_limit_remaining: guard("github rate limit remaining", {}) { source.github_rate_limit_remaining },
        github_app_rate_limit_remaining_percent: guard("github app rate limit remaining percent", nil) do
          source.github_app_rate_limit_remaining_percent
        end,
        github_app_api_blocked_count: guard("github app api blocked count", 0) { source.github_app_api_blocked_count },
        main_branch_broken_count: guard("main branch broken count", 0) { source.main_branch_broken_repository_count }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      return false if payload.blank?

      circuit_gauge = Syrus::Metrics.gauge(:syrus_provider_circuit_state)
      Hash(payload[:provider_circuit_state]).each do |provider, state|
        circuit_gauge.set(STATE_VALUES.fetch(state.to_sym, STATE_VALUES[:closed]), tags: { provider: provider })
      end

      set_each(:syrus_github_rate_limit_remaining, payload[:github_rate_limit_remaining], :credential_mode)
      app_percent_gauge = Syrus::Metrics.gauge(:syrus_github_app_rate_limit_remaining_percent)
      if payload.key?(:github_app_rate_limit_remaining_percent) && payload[:github_app_rate_limit_remaining_percent].present?
        app_percent_gauge.set(payload[:github_app_rate_limit_remaining_percent].to_f)
      else
        app_percent_gauge.clear
      end

      Syrus::Metrics.gauge(:syrus_github_app_api_blocked_count).set(payload[:github_app_api_blocked_count].to_i)

      Syrus::Metrics.gauge(:syrus_repositories_main_branch_broken_count).set(payload[:main_branch_broken_count].to_i)

      true
    end

    private

    attr_reader :source

    def set_each(metric, values, tag)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |label, value| gauge.set(value, tags: { tag => label }) }
    end

    # One unreachable source costs its own gauge, not the whole sample.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::ResilienceSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
