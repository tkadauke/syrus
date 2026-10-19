module ProviderRouting
  # Returns an ordered fallback list of provider/model/effort_level
  # candidates for a Job's task, walking specificity from the most
  # concrete override down to a hardcoded last resort. Mirrors the
  # precedence shape of Repository#effective_agent_provider and
  # Job::ProviderSetting::Default#resolve, but returns a list instead of
  # a single value so callers can fail over between candidates.
  class Resolver
    Candidate = Data.define(:provider, :model, :effort_level) do
      def to_h = super.compact
    end
    Resolution = Data.define(:candidates, :source_scope, :source_id, :matched_rule, :match_details, :fallback, :reason) do
      def held? = matched_rule&.hold_action? || false

      def decision
        if held?
          { "status" => "held", "failure" => false, "reason" => matched_rule.serialized_action["reason"] }.compact
        else
          { "status" => "routed", "failure" => false }
        end
      end

      def explanation
        {
          "source_scope" => source_scope,
          "source_id" => source_id,
          "fallback" => fallback,
          "reason" => reason,
          "decision" => decision,
          "matched_rule" => matched_rule_payload,
          "condition_results" => match_details,
          "final_action" => final_action
        }.compact
      end

      private

      def matched_rule_payload
        return nil unless matched_rule

        {
          "id" => matched_rule.id,
          "scope_type" => matched_rule.scope_type,
          "scope_id" => matched_rule.scope_id,
          "position" => matched_rule.position,
          "enabled" => matched_rule.enabled?,
          "trigger" => matched_rule.trigger,
          "conditions" => matched_rule.conditions
        }.compact
      end

      def final_action
        if matched_rule
          matched_rule.serialized_action.merge("candidates" => serialized_candidates).then do |payload|
            held? ? payload.except("candidates") : payload
          end
        else
          { "strategy" => "fallback_order", "candidates" => serialized_candidates }
        end
      end

      def serialized_candidates
        candidates.map { |candidate| candidate.to_h.stringify_keys }
      end
    end

    HARDCODED_FALLBACK = [ Candidate.new(provider: "claude", model: nil, effort_level: nil) ].freeze

    def self.call(job:, task_key:, trigger: nil, workflow_trigger_kind: nil)
      resolve(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind).candidates
    end

    def self.resolve(job:, task_key:, trigger: nil, workflow_trigger_kind: nil)
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind).resolve
    end

    def self.rule_configured?(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, include_default: true)
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind).send(:rule_configured?, include_default: include_default)
    end

    def initialize(job:, task_key:, trigger: nil, workflow_trigger_kind: nil)
      @job = job
      @task_key = task_key.to_s
      @trigger = trigger
      @workflow_trigger_kind = workflow_trigger_kind
    end

    def call
      resolve.candidates
    end

    def resolve
      job_override_resolution ||
        rule_resolution(scope_type: "job", scope_id: job.id) ||
        rule_resolution(scope_type: "repository", scope_id: repository_id) ||
        repository_and_user_resolution ||
        hardcoded_fallback_resolution
    end

    private

    attr_reader :job, :task_key, :trigger, :workflow_trigger_kind

    def job_override_candidates
      return nil if job.job_provider_setting_default?

      # Use workflow_agent_provider so the candidate is derived from the pinned
      # job_provider_setting rather than duplicating ProviderSetting resolution
      # here. switch_job_provider_setting! keeps agent_provider in sync for
      # presentation and legacy callers, but the setting remains the source of
      # truth for explicit pins.
      [ Candidate.new(provider: job.workflow_agent_provider, model: job.model, effort_level: job.effort_level) ]
    end

    def job_override_resolution
      candidates = job_override_candidates
      return nil if candidates.blank?

      Resolution.new(
        candidates: candidates,
        source_scope: "job_provider_setting",
        source_id: job.id,
        matched_rule: nil,
        match_details: nil,
        fallback: true,
        reason: "explicit_job_provider_setting"
      )
    end

    # No explicit job pin and no repository-scoped routing rule matched (a
    # repo rule -- task-specific or default-task -- is authored repo-level
    # configuration and stays authoritative on its own, handled above). From
    # here, an explicit repository/membership provider is still repo-level
    # configuration and must outrank user-scoped routing rules -- a repo
    # pinned to Muse must not be quietly routed to Claude just because the
    # user has a personal default-routing rule. But it must not foreclose
    # failover: if the repo's provider becomes unavailable, user-scoped rules
    # (and the user's own default provider) still act as the fallback chain,
    # so we concatenate rather than short-circuit. #uniq dedupes when the same
    # provider shows up in both the repo and user layers.
    def repository_and_user_resolution
      repository_candidates = repository_explicit_candidates || []
      user_resolution = user_scoped_resolution
      candidates = (repository_candidates + Array(user_resolution&.candidates)).uniq(&:provider)
      return nil if candidates.blank?

      if repository_candidates.present?
        Resolution.new(
          candidates: candidates,
          source_scope: "repository_explicit_provider",
          source_id: repository_id,
          matched_rule: user_resolution&.matched_rule,
          match_details: user_resolution&.match_details,
          fallback: true,
          reason: user_resolution ? "repository_provider_with_user_rule_failover" : "repository_explicit_provider"
        )
      else
        user_resolution
      end
    end

    def repository_explicit_candidates
      provider = job.repository&.explicit_agent_provider(user: effective_user)
      return nil if provider.blank?

      [ Candidate.new(provider: provider, model: job.model, effort_level: job.effort_level) ]
    end

    def user_scoped_resolution
      rule_resolution(scope_type: "user", scope_id: effective_user&.id) ||
        default_provider_resolution
    end

    # No routing rule at any scope, and no explicit repository/membership
    # provider either. Fall back to the user's own default provider (the
    # pre-routing-rule single-value default, via User#agent_provider) before
    # the last-resort hardcoded candidate.
    def default_provider_candidates
      provider = effective_user&.agent_provider
      return nil if provider.blank?

      [ Candidate.new(provider: provider, model: job.model, effort_level: job.effort_level) ]
    end

    def default_provider_resolution
      candidates = default_provider_candidates
      return nil if candidates.blank?

      Resolution.new(
        candidates: candidates,
        source_scope: "user_default_provider",
        source_id: effective_user&.id,
        matched_rule: nil,
        match_details: nil,
        fallback: true,
        reason: "user_default_provider"
      )
    end

    def rule_resolution(scope_type:, scope_id:)
      return nil if scope_id.blank?

      match = ProviderRoutingRule
        .where(scope_type: scope_type, scope_id: scope_id)
        .order(:position, :id)
        .then { |rules| matching_rule_from(rules) }
      return nil if match.nil?

      rule = match.fetch(:rule)
      return nil if rule.action_candidates.blank? && !rule.hold_action?

      candidates = rule.action_candidates.map { |candidate| candidate_from_hash(candidate) }
      Resolution.new(
        candidates: candidates,
        source_scope: scope_type,
        source_id: scope_id,
        matched_rule: rule,
        match_details: match.fetch(:details),
        fallback: false,
        reason: rule.hold_action? ? "matched_hold" : "matched_rule"
      )
    end

    def hardcoded_fallback_resolution
      Resolution.new(
        candidates: HARDCODED_FALLBACK,
        source_scope: "hardcoded",
        source_id: nil,
        matched_rule: nil,
        match_details: nil,
        fallback: true,
        reason: "no_rule_or_provider_default_matched"
      )
    end

    def candidate_from_hash(hash)
      hash = hash.stringify_keys
      Candidate.new(provider: hash["provider"], model: hash["model"], effort_level: hash["effort_level"])
    end

    def repository_id
      job.repository_id
    end

    def effective_user
      job.owner_user || job.user
    end

    def rule_configured?(include_default:)
      scopes = [
        [ "job", job.id ],
        [ "repository", repository_id ],
        [ "user", effective_user&.id ]
      ].select { |_scope_type, scope_id| scope_id.present? }

      scopes.any? do |scope_type, scope_id|
        ProviderRoutingRule
          .where(scope_type: scope_type, scope_id: scope_id, enabled: true)
          .any? do |rule|
            next false if !include_default && rule.trigger.to_h["type"] == "default"

            invocations(include_default: include_default).any? { |candidate_invocation| rule.matches?(invocation: candidate_invocation, job: job, workflow_trigger_kind: workflow_trigger_kind) }
          end
      end
    end

    def invocation
      @invocation ||= (trigger.presence || inferred_invocation).stringify_keys
    end

    def matching_rule_from(rules)
      rules.each do |rule|
        next unless rule.enabled?

        invocations(include_default: true).each do |candidate_invocation|
          details = rule.match_details(invocation: candidate_invocation, job: job, workflow_trigger_kind: workflow_trigger_kind)
          return { rule: rule, details: details } if details["matched"]
        end
      end
      nil
    end

    def invocations(include_default:)
      values = [
        invocation,
        { "type" => "default" }
      ]
      values.pop unless include_default
      values.uniq
    end

    def inferred_invocation
      return { type: "step", kind: task_key } if Step::Kind.agentic_values.include?(task_key)
      return { type: "chat_role", role: task_key } if AgentRole::CHAT_ROLES.include?(task_key)

      { type: "legacy_task", task_key: task_key, kind: task_key }
    end
  end
end
