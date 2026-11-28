module Coworkers
  class JobAutonomy
    CAPABILITIES = {
      "propose_job" => "coworker.jobs.propose",
      "approve_job" => "coworker.jobs.approve",
      "submit_chat_feedback" => "coworker.jobs.feedback",
      "cancel_job" => "coworker.jobs.cancel",
      "retry_job" => "coworker.jobs.retry"
    }.freeze
    DEFAULTS = { "max_open_jobs" => 3, "max_self_approvals_per_day" => 5,
      "max_feedback_rounds_per_job" => 3, "allow_sensitive_changes" => false, "mode" => "shadow" }.freeze
    MODES = %w[shadow enabled].freeze
    OPEN_STATES = %w[triaging backlog queued running implemented approved landing].freeze

    Decision = Data.define(:allowed, :rule, :reason, :mode, :predicted_decision, :guardrail_outcomes, :evidence) do
      def allowed? = allowed
      def shadow? = mode == "shadow"
    end

    def initialize(coworker)
      @coworker = coworker
    end

    def authorize(tool_name:, repository:, job: nil)
      name = tool_name.to_s
      return refused("This action is not eligible for coworker autonomy.") unless CAPABILITIES.key?(name)
      return refused("Only Jobs filed by this coworker can be handled autonomously.") if job && job.filed_by_coworker_id != coworker.id

      rule = coworker.permission_rules.rules.where(policy: "allow").find do |candidate|
        unversioned(candidate.capability) == CAPABILITIES.fetch(name) &&
          repository_ids(candidate).include?(repository.id)
      end
      return refused("Operator confirmation is required by the repository permission rule.") unless rule

      limits = constraints(rule)
      outcomes = guardrail_outcomes(name, repository, job, limits)
      reason = outcomes.values.find { |outcome| !outcome.fetch("passed") }&.fetch("reason")
      mode = limits.fetch("mode")
      if mode == "shadow"
        return Decision.new(false, rule, reason, mode, reason ? "abstain" : "act", outcomes, evidence(name, repository, job, rule))
      end
      return refused(reason, rule, outcomes:) if reason

      Decision.new(true, rule, nil, mode, "act", outcomes, evidence(name, repository, job, rule))
    end

    private

    attr_reader :coworker

    def guardrail_outcomes(name, repository, job, limits)
      outcomes = {
        "repository_scope" => { "passed" => true, "repository_id" => repository.id },
        "own_job" => { "passed" => job.nil? || job.filed_by_coworker_id == coworker.id }
      }
      if name == "propose_job"
        count = Syrus::Host::Jobs.where(filed_by_coworker_id: coworker.id, repository_id: repository.id, state: OPEN_STATES).count
        add_outcome(outcomes, "open_job_budget", count < limits.fetch("max_open_jobs"),
          "Open self-filed Job budget reached (#{limits.fetch('max_open_jobs')}).", count:, limit: limits.fetch("max_open_jobs"))
      elsif name == "approve_job"
        count = Permissions::CoworkerAudit.events_for(coworker, since: Time.current.beginning_of_day).count do |event|
          event.params["repository_id"] == repository.id &&
            event.params["autonomous_action"] == "approve_job"
        end
        add_outcome(outcomes, "self_approval_budget", count < limits.fetch("max_self_approvals_per_day"),
          "Daily self-approval budget reached (#{limits.fetch('max_self_approvals_per_day')}).", count:, limit: limits.fetch("max_self_approvals_per_day"))
      elsif name == "submit_chat_feedback"
        count = job.workflows.where(trigger_kind: ::Workflow::TriggerKind.feedback_values).count
        add_outcome(outcomes, "feedback_round_budget", count < limits.fetch("max_feedback_rounds_per_job"),
          "Feedback-round budget reached for this Job (#{limits.fetch('max_feedback_rounds_per_job')}).", count:, limit: limits.fetch("max_feedback_rounds_per_job"))
      end
      approval_outcomes(job, limits, outcomes) if name == "approve_job"
      outcomes
    end

    def approval_outcomes(job, limits, outcomes)
      workflow = job&.latest_workflow
      add_outcome(outcomes, "implementation_workflow", workflow.present?, "The Job has no implementation Workflow to approve.")
      reviews_passed = workflow.present? && Syrus::Host::ImmutableReviewHeadBarrier.required_reviews_satisfied?(workflow)
      add_outcome(outcomes, "required_reviews", reviews_passed, "Required reviews have not approved the current implementation HEAD.")
      classification = Coworkers::SensitiveChangeClassifier.call(job)
      carve_out_passed = limits.fetch("allow_sensitive_changes") || !classification.sensitive?
      add_outcome(outcomes, "sensitive_change_carve_out", carve_out_passed,
        "Sensitive change requires operator approval: #{classification.reasons.join(', ')}.", reasons: classification.reasons)
      proof = !job&.bug_fix? || Coworkers::RegressionProof.call(job).proven?
      add_outcome(outcomes, "regression_proof", proof,
        "Bug-fix self-approval requires a new regression spec that fails on the base revision and passes on the branch.")
    end

    def add_outcome(outcomes, key, passed, reason, **details)
      outcomes[key] = { "passed" => passed, "reason" => (reason unless passed) }.compact.merge(details.stringify_keys)
    end

    def evidence(name, repository, job, rule)
      { "action" => name, "coworker_id" => coworker.id, "repository_id" => repository.id,
        "job_id" => job&.id, "implementation_head" => (Syrus::Host::ImmutableReviewHeadBarrier.reviewed_head_sha(job.latest_workflow) if job&.latest_workflow),
        "permission_rule_id" => rule.id }.compact
    end

    def constraints(rule)
      DEFAULTS.merge(rule.constraints.to_h.slice(*DEFAULTS.keys)).tap do |value|
        %w[max_open_jobs max_self_approvals_per_day max_feedback_rounds_per_job].each { |key| value[key] = value[key].to_i }
        value["allow_sensitive_changes"] = ActiveModel::Type::Boolean.new.cast(value["allow_sensitive_changes"])
        value["mode"] = value["mode"].to_s.in?(MODES) ? value["mode"].to_s : "shadow"
      end
    end

    def refused(reason, rule = nil, outcomes: {}) = Decision.new(false, rule, reason, nil, nil, outcomes, {})

    def repository_ids(rule)
      scope = rule.provenance["coworker_scope"]
      scope = rule.resource_scope["repository_id"] if scope.nil?
      Array(scope).filter_map { |value| Integer(value, exception: false) }
    end

    def unversioned(value) = value.to_s.sub(/@v\d+\z/, "")
  end
end
