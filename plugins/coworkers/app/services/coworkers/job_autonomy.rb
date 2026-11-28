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
      "max_feedback_rounds_per_job" => 3, "allow_sensitive_changes" => false }.freeze
    OPEN_STATES = %w[triaging backlog queued running implemented approved landing].freeze

    Decision = Data.define(:allowed, :rule, :reason) do
      def allowed? = allowed
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
      reason = budget_refusal(name, repository, job, limits)
      reason ||= approval_refusal(job, limits) if name == "approve_job"
      reason ? refused(reason, rule) : Decision.new(true, rule, nil)
    end

    private

    attr_reader :coworker

    def budget_refusal(name, repository, job, limits)
      if name == "propose_job"
        count = Syrus::Host::Jobs.where(filed_by_coworker_id: coworker.id, repository_id: repository.id, state: OPEN_STATES).count
        return "Open self-filed Job budget reached (#{limits.fetch('max_open_jobs')})." if count >= limits.fetch("max_open_jobs")
      elsif name == "approve_job"
        count = Permissions::CoworkerAudit.events_for(coworker).count do |event|
          event.performed_at >= Time.current.beginning_of_day && event.params["repository_id"] == repository.id &&
            event.params["autonomous_action"] == "approve_job"
        end
        return "Daily self-approval budget reached (#{limits.fetch('max_self_approvals_per_day')})." if count >= limits.fetch("max_self_approvals_per_day")
      elsif name == "submit_chat_feedback"
        count = job.workflows.where(trigger_kind: ::Workflow::TriggerKind.feedback_values).count
        return "Feedback-round budget reached for this Job (#{limits.fetch('max_feedback_rounds_per_job')})." if count >= limits.fetch("max_feedback_rounds_per_job")
      end
    end

    def approval_refusal(job, limits)
      return "The Job has no implementation Workflow to approve." unless job&.latest_workflow
      return "Required reviews have not approved the current implementation HEAD." unless
        Syrus::Host::ImmutableReviewHeadBarrier.required_reviews_satisfied?(job.latest_workflow)
      unless limits.fetch("allow_sensitive_changes")
        classification = Coworkers::SensitiveChangeClassifier.call(job)
        return "Sensitive change requires operator approval: #{classification.reasons.join(', ')}." if classification.sensitive?
      end
      if job.bug_fix? && !Coworkers::RegressionProof.call(job).proven?
        return "Bug-fix self-approval requires a new regression spec that fails on the base revision and passes on the branch."
      end
    end

    def constraints(rule)
      DEFAULTS.merge(rule.constraints.to_h.slice(*DEFAULTS.keys)).tap do |value|
        %w[max_open_jobs max_self_approvals_per_day max_feedback_rounds_per_job].each { |key| value[key] = value[key].to_i }
        value["allow_sensitive_changes"] = ActiveModel::Type::Boolean.new.cast(value["allow_sensitive_changes"])
      end
    end

    def refused(reason, rule = nil) = Decision.new(false, rule, reason)

    def repository_ids(rule)
      scope = rule.provenance["coworker_scope"]
      scope = rule.resource_scope["repository_id"] if scope.nil?
      Array(scope).filter_map { |value| Integer(value, exception: false) }
    end

    def unversioned(value) = value.to_s.sub(/@v\d+\z/, "")
  end
end
