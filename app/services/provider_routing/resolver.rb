module ProviderRouting
  # Returns an ordered fallback list of provider/model/effort_level
  # candidates for a Job's task, walking specificity from the most
  # concrete override down to a hardcoded last resort: job pin, repository
  # rules, user rules, the user's default provider (User#agent_provider),
  # then a hardcoded fallback. Returns a list so callers can fail over.
  class Resolver
    PanelResolutionRequired = Class.new(StandardError)
    CoworkerReviewTargetRequired = Class.new(ReviewerTargets::ResolutionError)

    Candidate = Data.define(:provider, :model, :effort_level, :reviewer_target) do
      def initialize(provider:, model:, effort_level:, reviewer_target: nil)
        super
      end

      def to_h = super.compact
    end
    PanelResolution = Data.define(:members, :consensus, :on_unavailable, :min_members, :source_scope, :source_id, :matched_rule, :match_details) do
      def candidates = members
      def held? = false
      def panel? = true
      def fallback = false
      def reason = "matched_panel_rule"
      def decision = { "status" => "panel", "failure" => false }

      def explanation
        {
          "source_scope" => source_scope,
          "source_id" => source_id,
          "fallback" => false,
          "reason" => reason,
          "decision" => decision,
          "matched_rule" => {
            "id" => matched_rule.id,
            "scope_type" => matched_rule.scope_type,
            "scope_id" => matched_rule.scope_id,
            "position" => matched_rule.position,
            "enabled" => matched_rule.enabled?,
            "trigger" => matched_rule.trigger,
            "conditions" => matched_rule.conditions
          },
          "condition_results" => match_details,
          "final_action" => matched_rule.serialized_action.merge("candidates" => members.map { |member| member.to_h.stringify_keys })
        }
      end
    end
    Resolution = Data.define(:candidates, :source_scope, :source_id, :matched_rule, :match_details, :fallback, :reason) do
      def held? = matched_rule&.hold_action? || false
      def panel? = false

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

    HARDCODED_FALLBACK = [ Candidate.new(provider: "claude", model: nil, effort_level: nil, reviewer_target: nil) ].freeze

    def self.call(job:, task_key:, trigger: nil, workflow_trigger_kind: nil)
      resolution = resolve(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind)
      raise PanelResolutionRequired, "panel routing must be consumed through the panel resolution path" if resolution.panel?

      resolution.candidates
    end

    def self.resolve(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, released_hold_rule_ids: [])
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind, released_hold_rule_ids: released_hold_rule_ids).resolve
    end

    # The provider an `implement` step on this repository would try first for
    # `user` (default: the repository owner), through the same resolution a real
    # Job gets. For display and health checks where no Job exists yet.
    def self.preview_provider(repository:, user: nil, task_key: "implement")
      acting_user = user || repository.user
      job = Job.new(repository: repository, user: acting_user, owner_user: acting_user)
      resolve(job: job, task_key: task_key).candidates.first&.provider.presence || acting_user&.agent_provider
    end

    def self.rule_configured?(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, include_default: true)
      new(job: job, task_key: task_key, trigger: trigger, workflow_trigger_kind: workflow_trigger_kind).send(:rule_configured?, include_default: include_default)
    end

    def initialize(job:, task_key:, trigger: nil, workflow_trigger_kind: nil, released_hold_rule_ids: [])
      @job = job
      @task_key = task_key.to_s
      @trigger = trigger
      @workflow_trigger_kind = workflow_trigger_kind
      @released_hold_rule_ids = Array(released_hold_rule_ids).map(&:to_i)
    end

    def call
      resolve.candidates
    end

    def resolve
      resolution = job_override_resolution ||
        rule_resolution(scope_type: "job", scope_id: job.id) ||
        rule_resolution(scope_type: "repository", scope_id: repository_id) ||
        user_scoped_resolution ||
        hardcoded_fallback_resolution
      if reviewer_target_required? && (resolution.held? || resolution.matched_rule.nil? || resolution.candidates.any? { |candidate| candidate.reviewer_target.blank? })
        raise CoworkerReviewTargetRequired, "coworker_review requires a matching valid coworker routing rule"
      end
      resolution
    end

    private

    attr_reader :job, :task_key, :trigger, :workflow_trigger_kind, :released_hold_rule_ids

    def job_override_candidates
      return nil if job.job_provider_setting_default?

      # Use workflow_agent_provider so the candidate is derived from the pinned
      # job_provider_setting rather than duplicating ProviderSetting resolution
      # here. switch_job_provider_setting! keeps agent_provider in sync for
      # presentation and legacy callers, but the setting remains the source of
      # truth for explicit pins.
      [ Candidate.new(provider: job.workflow_agent_provider, model: job.model, effort_level: job.effort_level, reviewer_target: nil) ]
    end

    def job_override_resolution
      return nil if reviewer_target_required?

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

    def user_scoped_resolution
      rule_resolution(scope_type: "user", scope_id: effective_user&.id) ||
        default_provider_resolution
    end

    # No routing rule at any scope. Fall back to the user's own default
    # provider (User#agent_provider) before the last-resort hardcoded candidate.
    def default_provider_candidates
      provider = effective_user&.agent_provider
      return nil if provider.blank?

      [ Candidate.new(provider: provider, model: job.model, effort_level: job.effort_level, reviewer_target: nil) ]
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
      if rule.panel_action?
        action = rule.serialized_action
        return PanelResolution.new(
          members: candidates,
          consensus: action["consensus"],
          on_unavailable: action["on_unavailable"],
          min_members: action["min_members"],
          source_scope: scope_type,
          source_id: scope_id,
          matched_rule: rule,
          match_details: match.fetch(:details)
        )
      end
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
      target = hash["reviewer_target"]&.then do |payload|
        ReviewerTargets.snapshot(payload, owner: effective_user, repository: job.repository)
      end
      Candidate.new(provider: hash["provider"], model: hash["model"], effort_level: hash["effort_level"], reviewer_target: target)
    end

    def repository_id
      job.repository_id
    end

    def effective_user
      job.owner_user || job.user
    end

    def invocation_kind
      trigger.to_h.deep_stringify_keys["kind"].presence || task_key
    end

    def reviewer_target_required?
      Step::Kind.by_kind[invocation_kind]&.reviewer_target_required || false
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
        next if rule.hold_action? && released_hold_rule_ids.include?(rule.id)

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
