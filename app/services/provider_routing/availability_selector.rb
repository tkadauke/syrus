module ProviderRouting
  class AvailabilitySelector
    PanelDecision = Data.define(:members, :available_members, :unavailable_members, :consensus, :on_unavailable, :min_members, :disposition, :routing_resolution) do
      def held? = disposition == "hold"
      def failed? = disposition == "fail"
      def dropped? = disposition == "drop"

      def artifact
        {
          "strategy" => "panel",
          "members" => members,
          "available_members" => available_members,
          "unavailable_members" => unavailable_members,
          "consensus" => consensus,
          "on_unavailable" => on_unavailable,
          "min_members" => min_members,
          "disposition" => disposition,
          "routing_resolution" => routing_resolution.explanation
        }
      end
    end

    Decision = Data.define(:candidate, :original_candidate, :reason, :availability, :candidate_availability, :decided_at, :exhausted, :routing_resolution, :provider_account) do
      def initialize(candidate:, original_candidate:, reason:, availability:, candidate_availability:, decided_at:, exhausted:, routing_resolution:, provider_account: nil)
        super
      end
      def selected_provider = candidate&.provider
      def failover?
        return false unless selected_provider.present? && original_candidate&.provider.present?

        selected_provider != original_candidate.provider ||
          (original_candidate.account_id.present? && provider_account&.public_id != original_candidate.account_id)
      end
      def exhausted? = exhausted
      def held? = routing_resolution&.held? || false

      def artifact
        {
          "original_provider" => original_candidate&.provider,
          "original_model" => original_candidate&.model,
          "original_effort_level" => original_candidate&.effort_level,
          "selected_provider" => candidate&.provider,
          "selected_model" => candidate&.model,
          "selected_effort_level" => candidate&.effort_level,
          "selected_account" => provider_account&.safe_reference&.stringify_keys,
          "reason" => reason,
          "availability_state" => availability_state(availability),
          "candidate_availability_state" => availability_state(candidate_availability),
          "evidence_observed_at" => utc_iso8601(evidence_observed_at(availability)),
          "candidate_evidence_observed_at" => utc_iso8601(evidence_observed_at(candidate_availability)),
          "decided_at" => utc_iso8601(decided_at),
          "automatic_failover" => true,
          "manual_override" => false,
          "exhausted" => exhausted?,
          "held" => held?,
          "routing_resolution" => routing_resolution&.explanation,
          "unavailable" => unavailable_summary(unavailable_payload)
        }.compact
      end

      private

      def availability_state(payload)
        payload&.dig(:state) || payload&.dig("state") || "available"
      end

      def evidence_observed_at(payload)
        value =
          payload&.dig(:evidence, :current, :observed_at) ||
          payload&.dig("evidence", "current", "observed_at") ||
          payload&.dig(:usage, :observed_at) ||
          payload&.dig("usage", "observed_at")
        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def unavailable_summary(payload)
        return nil unless payload

        evidence = payload.dig(:evidence, :current) || payload.dig("evidence", "current") || payload.dig(:usage, :evidence) || payload.dig("usage", "evidence") || {}
        usage = payload[:usage] || payload["usage"] || {}
        {
          "provider" => payload[:provider] || payload["provider"] || original_candidate&.provider,
          "label" => payload[:label] || payload["label"],
          "state" => payload[:state] || payload["state"],
          "reason" => payload[:reason] || payload["reason"],
          "retry_after" => payload[:retry_after] || payload["retry_after"],
          "reset_at" => utc_iso8601(reset_at(usage)),
          "observed_at" => utc_iso8601(evidence_observed_at(payload)),
          "evidence" => {
            "status" => evidence[:status] || evidence["status"],
            "source" => evidence[:source] || evidence["source"],
            "observed_at" => evidence[:observed_at] || evidence["observed_at"]
          }.compact
        }.compact
      end

      def unavailable_payload
        availability || (candidate_availability if exhausted?)
      end

      def reset_at(usage)
        ProviderRouting::UsageWindows.earliest_reset_at(usage)
      end

      def utc_iso8601(value)
        value&.utc&.iso8601
      end
    end

    def self.call(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, original_candidate: nil, reason: nil, availability: nil, now: Time.current, released_hold_rule_ids: [], workflow: nil)
      new(
        job: job,
        task_key: task_key,
        trigger: trigger,
        workflow_trigger_kind: workflow_trigger_kind,
        original_candidate: original_candidate,
        reason: reason,
        availability: availability,
        now: now,
        released_hold_rule_ids: released_hold_rule_ids,
        workflow: workflow
      ).call
    end

    def self.candidate(provider:, model: nil, effort_level: nil, reviewer_target: nil, account_id: nil)
      ProviderRouting::Resolver::Candidate.new(provider: provider, model: model, effort_level: effort_level, reviewer_target: reviewer_target, account_id: account_id)
    end

    def self.panel(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, now: Time.current)
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind, now: now).panel
    end

    def initialize(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, original_candidate: nil, reason: nil, availability: nil, now: Time.current, released_hold_rule_ids: [], workflow: nil)
      @job = job
      @task_key = task_key
      @trigger = trigger
      @workflow_trigger_kind = workflow_trigger_kind
      @original_candidate = original_candidate
      @reason = reason
      @availability = availability
      @now = now
      @released_hold_rule_ids = released_hold_rule_ids
      @workflow = workflow
    end

    def call
      if routing_resolution.panel?
        raise Resolver::PanelResolutionRequired, "panel routing must be evaluated with AvailabilitySelector.panel"
      end

      return decision(nil, candidate_availability: nil, exhausted: false) if routing_resolution.held?

      first_unavailable_candidate = nil
      first_unavailable_availability = nil

      candidates.each do |candidate|
        available, account, candidate_availability = select_account(candidate)
        unless available
          first_unavailable_candidate ||= candidate
          first_unavailable_availability ||= candidate_availability
          next
        end

        selected_candidate = candidate.with(account_id: account.public_id)
        return decision(selected_candidate, candidate_availability: candidate_availability, exhausted: false, provider_account: account)
      end

      decision(
        first_unavailable_candidate || candidates.first,
        candidate_availability: first_unavailable_availability,
        exhausted: true
      )
    end

    def panel
      resolution = routing_resolution
      return nil unless resolution.panel?

      members = resolution.members.map do |candidate|
        available, account, unavailable = select_account(candidate)
        candidate.to_h.stringify_keys.merge(
          "account_id" => account&.public_id || candidate.account_id,
          "selected_account" => account&.safe_reference&.stringify_keys,
          "available" => available,
          "availability" => unavailable
        ).compact
      end
      unavailable = members.reject { |member| member["available"] }
      available = members.select { |member| member["available"] }
      disposition = if unavailable.empty?
        "proceed"
      elsif resolution.on_unavailable == "drop"
        "drop"
      else
        resolution.on_unavailable
      end
      PanelDecision.new(
        members: members,
        available_members: available,
        unavailable_members: unavailable,
        consensus: resolution.consensus,
        on_unavailable: resolution.on_unavailable,
        min_members: resolution.min_members,
        disposition: disposition,
        routing_resolution: resolution
      )
    end

    private

    attr_reader :job, :task_key, :trigger, :workflow_trigger_kind, :original_candidate, :reason, :availability, :now, :released_hold_rule_ids, :workflow

    def candidates
      @candidates ||= if routing_resolution.held?
        []
      elsif original_candidate && original_candidate.provider == job.workflow_agent_provider && !ProviderRouting::Resolver.rule_configured?(
        job: job,
        task_key: task_key,
        trigger: trigger,
        workflow_trigger_kind: workflow_trigger_kind
      )
        [ original_candidate ]
      else
        routing_resolution.candidates.presence || ProviderRouting::Resolver::HARDCODED_FALLBACK
      end
    end

    def routing_resolution
      @routing_resolution ||= ProviderRouting::Resolver.resolve(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind, released_hold_rule_ids: released_hold_rule_ids)
    end

    def user = job.owner_user || job.user

    def decision(candidate, candidate_availability:, exhausted:, provider_account: nil)
      Decision.new(
        candidate: candidate,
        original_candidate: original_candidate || candidate,
        reason: reason,
        availability: availability,
        candidate_availability: candidate_availability,
        decided_at: now,
        exhausted: exhausted,
        routing_resolution: routing_resolution,
        provider_account: provider_account
      )
    end

    def select_account(candidate)
      accounts = user.enabled_provider_accounts(candidate.provider)
      accounts = accounts.where(public_id: candidate.account_id) if candidate.account_id.present?
      if workflow&.runs&.exists? && workflow.provider_account_id.present?
        accounts = accounts.where(id: workflow.provider_account_id)
      end
      accounts = accounts.to_a
      known_unavailable_account = if availability && workflow&.provider_account&.provider_key == candidate.provider
        workflow.provider_account
      end
      accounts.reject! { |account| account.id == known_unavailable_account.id } if known_unavailable_account
      if accounts.empty?
        return [ false, nil, availability ] if known_unavailable_account
        return [ false, nil, credential_unavailability(candidate.provider) ] if candidate.account_id.present?

        unavailable = credential_unavailability(candidate.provider)
        return [ false, nil, unavailable ] if unavailable

        refresh_stale_usage(candidate.provider)
        payload = App::ProviderAvailability.for_user(user, candidate.provider, now: now)
        return [ available_enough?(candidate.provider, payload), nil, payload ]
      end
      if accounts.one? && accounts.first.default? && !AgentProviders.for(candidate.provider).configured_for_user?(user)
        return [ false, nil, credential_unavailability(candidate.provider) ]
      end

      payloads = accounts.to_h do |account|
        unless AgentProviders.for(candidate.provider).configured_for_account?(account, user: user)
          next [ account.id, { provider: candidate.provider, state: "auth_error", reason: "provider_credentials_missing" } ]
        end
        refresh_stale_usage(candidate.provider, account)
        payload = if accounts.one? && account.default? && candidate.account_id.blank?
          App::ProviderAvailability.for_user(user, candidate.provider, now: now)
        else
          App::ProviderAvailability.for_user(user, candidate.provider, provider_account: account, now: now)
        end
        [ account.id, payload ]
      end
      eligible = accounts.select { |account| available_enough?(candidate.provider, payloads[account.id], account) }
      return [ false, nil, payloads[accounts.first.id] ] if eligible.empty?

      [ true, reserve_least_pressured_account(eligible, payloads), nil ]
    rescue AgentProviders::ConfigurationError
      [ false, nil, credential_unavailability(candidate.provider) ]
    end

    def reserve_least_pressured_account(accounts, payloads)
      user.with_lock do
        pool = Workflow.where(provider_account_id: accounts.map(&:id))
        pool = pool.where.not(id: workflow.id) if workflow&.persisted?
        active = pool.where(state: %w[queued running]).group(:provider_account_id).count
        assigned = pool.group(:provider_account_id).count
        selected = accounts.min_by do |account|
          weight = account.weight.presence&.to_f || 1.0
          remaining = remaining_percent(payloads[account.id])
          capacity = remaining ? [ remaining / 100.0, 0.01 ].max : 1.0
          [ active.fetch(account.id, 0) / (weight * capacity), assigned.fetch(account.id, 0) / weight, account.position, account.id ]
        end
        pin_account!(selected)
        selected
      end
    end

    def pin_account!(account)
      return unless workflow
      return if workflow.provider_account_id == account.id
      return if workflow.runs.exists?

      workflow.update!(
        agent_provider: account.provider_key,
        provider_account: account,
        artifacts: workflow.artifacts.to_h.merge(
          "provider_account_selection" => account.safe_reference.stringify_keys,
          "provider_account_selected_at" => now.utc.iso8601
        )
      )
    end

    # Basic availability (actively erroring/rate-limited/exhausted/paused)
    # always applies, regardless of whether the user has opted into
    # proactive threshold-based pausing for any candidate provider or
    # configured a ProviderRoutingRule — a candidate that is provably
    # unavailable right now should never be selected. The opt-in
    # `provider_availability_pause_enabled?` setting is reserved for the
    # more aggressive proactive check below (pausing *before* a provider
    # is actually broken, once its remaining usage drops under a
    # configured threshold).
    def available_enough?(provider, payload, account = nil)
      return false if actively_unavailable?(provider, payload, account)

      remaining = remaining_percent(payload)
      threshold = account ? account.effective_proactive_pause_threshold : user.provider_availability_pause_threshold_for(provider)
      remaining.nil? || threshold.zero? || remaining >= threshold
    end

    UNAVAILABLE_STATES = %w[open rate_limited exhausted auth_error model_unsupported].freeze

    def actively_unavailable?(provider, payload, account = nil)
      return true if user.provider_availability_overridden?(provider, provider_account: account, evidence_observed_at: evidence_observed_at(payload))
      return true if payload&.dig(:open) == true || payload&.dig("open") == true
      return true if payload&.dig(:usage_exhausted) == true || payload&.dig("usage_exhausted") == true
      # model_unsupported belongs here with auth_error: both mean this
      # provider will refuse every request until it is reconfigured, so the
      # next candidate is strictly better than retrying this one.
      return true if payload&.dig(:state).to_s.in?(UNAVAILABLE_STATES)
      return true if payload&.dig("state").to_s.in?(UNAVAILABLE_STATES)

      false
    end

    def credential_unavailability(provider)
      provider_class = AgentProviders.for(provider)
      return nil if provider_class.configured_for_user?(user)

      {
        provider: provider,
        state: "auth_error",
        reason: "provider_credentials_missing",
        message: "#{provider_class.display_name} credentials are not configured."
      }
    rescue AgentProviders::ConfigurationError
      {
        provider: provider,
        state: "auth_error",
        reason: "unknown_provider",
        message: "Unknown agent provider: #{provider.inspect}."
      }
    end

    def refresh_stale_usage(provider, account = nil)
      AgentProviders.for(provider).refresh_stale_usage!(user: user, provider_account: account, now: now)
    rescue AgentProviders::ConfigurationError
      nil
    end

    def remaining_percent(payload)
      value = payload&.dig(:usage, :remaining_percent) || payload&.dig("usage", "remaining_percent")
      return if value.blank?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def evidence_observed_at(payload)
      value =
        payload&.dig(:evidence, :current, :observed_at) ||
        payload&.dig("evidence", "current", "observed_at") ||
        payload&.dig(:usage, :observed_at) ||
        payload&.dig("usage", "observed_at")
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
