module WorkUnits
  class AutoRetryBackoff
    SAME_ATTEMPT_RETRY_KINDS = %w[failed_step resume_failed_step].freeze

    def self.record!(attempt) = new(attempt).record!
    def self.clear!(attempt, terminal_state: "failed") = new(attempt).clear!(terminal_state: terminal_state)

    def initialize(attempt)
      @attempt = attempt
    end

    def record!
      return unless same_attempt_retry?
      return unless unit
      return unless workflow&.work_unit&.id == unit.id
      return if unit.succeeded? || unit.cancelled?
      return unless ensure_locks!

      unit.block!(
        reason: "auto_retry_backoff",
        blocked_until: attempt.scheduled_at,
        details: {
          "auto_retry_attempt_id" => attempt.id,
          "retry_kind" => attempt.retry_kind,
          "failure_classification" => attempt.failure_classification,
          "agent_provider" => attempt.agent_provider
        }.compact
      )
    end

    def clear!(terminal_state: "failed")
      return unless same_attempt_retry?
      return unless unit&.blocked?
      return unless unit.blocked_reason == "auto_retry_backoff"
      return unless unit.blocked_details.to_h["auto_retry_attempt_id"].to_i == attempt.id

      if terminal_state
        unit.mark_terminal!(terminal_state)
      else
        unit.unblock!
      end
    end

    private

    attr_reader :attempt

    def same_attempt_retry?
      attempt.retry_kind.in?(SAME_ATTEMPT_RETRY_KINDS)
    end

    def workflow
      attempt.workflow
    end

    def unit
      @unit ||= workflow&.work_unit
    end

    def ensure_locks!
      return true if unit.work_unit_locks.active.exists?

      primary_job = primary_member_job
      return false unless primary_job

      lock_keys.each do |lock_key|
        owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
        return false if owner && owner.id != unit.id
      end

      WorkUnit.transaction do
        lock_keys.each do |lock_key|
          next if unit.work_unit_locks.active.exists?(lock_key: lock_key)

          unit.work_unit_locks.create!(lock_key: lock_key)
        end
      end
      true
    end

    def lock_keys
      @lock_keys ||= unit.definition.lock_keys_for(
        job: primary_member_job,
        member_jobs: member_jobs,
        artifacts: workflow&.artifacts || {}
      )
    end

    def primary_member_job
      @primary_member_job ||= unit.work_unit_members.includes(:job).find_by(role: "primary")&.job || attempt.job
    end

    def member_jobs
      @member_jobs ||= unit.work_unit_members.includes(:job).order(:id).map(&:job).compact.presence || [ primary_member_job ].compact
    end
  end
end
