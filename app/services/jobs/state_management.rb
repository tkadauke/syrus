module Jobs
  class StateManagement
    Result = Data.define(:job, :transition)
    ACTIONS = %w[close cancel].freeze

    class Invalid < StandardError
      attr_reader :job

      def initialize(message, job:)
        @job = job
        super(message)
      end
    end

    def initialize(job:, action:, reason:, canonical_job:, actor:, chat_session:)
      @job = job
      @action = action.to_s
      @reason = reason.to_s.strip
      @canonical_job = canonical_job
      @actor = actor
      @chat_session = chat_session
    end

    def call
      validate!

      Job.transaction do
        job.lock!
        validate_mutable_state!
        job.cancel_active_execution!
        job.canonical_job = canonical_job
        job.closure_reason = closure_reason
        StateTransition.with_source("operator", user: chat_session.user, reason: closure_reason, metadata: audit_metadata) do
          job.close!
        end
        Result.new(job.reload, StateTransition.for_subject(job).recent.first)
      end
    end

    private

    attr_reader :job, :action, :reason, :canonical_job, :actor, :chat_session

    def validate!
      raise Invalid.new("action must be one of: #{ACTIONS.join(', ')}", job:) unless ACTIONS.include?(action)
      raise Invalid.new("reason is required", job:) if reason.blank?
      raise Invalid.new("reason is too long (maximum is 1000 characters)", job:) if reason.length > 1_000
      if canonical_job && (canonical_job == job || canonical_job.repository_id != job.repository_id)
        raise Invalid.new("canonical_job_id must reference another accessible Job in the same repository", job:)
      end
      validate_mutable_state!
    end

    def validate_mutable_state!
      raise Invalid.new("#{job.slug} is already closed", job:) if job.closed?
      if job.landed_sha.present? || job.deployment_stage_statuses.exists?
        raise Invalid.new("#{job.slug} has landing or deployment evidence and cannot be closed this way", job:)
      end
      raise Invalid.new("#{job.slug} cannot be closed from #{job.state}", job:) unless job.may_close?
    end

    def closure_reason
      return "duplicate" if canonical_job

      action == "cancel" ? "cancelled" : "obsolete"
    end

    def audit_metadata
      {
        "actor_type" => actor.class.polymorphic_name,
        "actor_id" => actor.id,
        "actor_label" => actor.respond_to?(:handle) ? actor.handle : actor.to_s,
        "chat_session_id" => chat_session.id,
        "human_reason" => reason,
        "canonical_job_id" => canonical_job&.id,
        "requested_action" => action
      }.compact
    end
  end
end
