module WorkUnits
  class StartBlock
    def self.for(workflow) = new(workflow)
    def self.work_unit_reason_for(start_blocked_reason)
      WorkflowBlockProjection::REASON_MAP.fetch(start_blocked_reason.to_s, "preempted")
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def reason
      workflow.work_unit&.blocked_reason.presence ||
        eligible_artifact_reason
    end

    def details
      workflow.work_unit&.blocked_details.presence ||
        eligible_artifact_details ||
        {}
    end

    def data
      return work_unit_data if workflow.work_unit&.blocked_reason.present?
      return artifact_data if eligible_artifact_reason.present?

      {}
    end

    def next_check_at
      workflow.work_unit&.blocked_until || parse_time(eligible_artifact_next_check_at)
    end

    def blocked_for?(start_blocked_reason)
      unit = workflow.work_unit
      if unit
        return true if unit.blocked_reason == self.class.work_unit_reason_for(start_blocked_reason)
        return true if unit.blocked_reason == start_blocked_reason.to_s
        return true if unit.blocked_details.to_h["start_blocked_reason"] == start_blocked_reason.to_s
      end

      eligible_artifact_reason == start_blocked_reason.to_s
    end

    def landing_start_blocker?
      LandingQueueReentry.landing_start_blocker?(reason) ||
        LandingQueueReentry.landing_start_blocker?(details.to_h["start_blocked_reason"])
    end

    private

    attr_reader :workflow

    def artifact_reason
      workflow.artifacts.to_h["start_blocked_reason"].presence
    end

    def eligible_artifact_reason
      return unless artifact_eligible?

      artifact_reason
    end

    def eligible_artifact_details
      return unless artifact_eligible?

      workflow.artifacts.to_h["start_blocked_details"].presence
    end

    def eligible_artifact_next_check_at
      return unless artifact_eligible?

      workflow.artifacts.to_h["start_blocked_next_check_at"]
    end

    def artifact_eligible?
      return false if workflow.work_unit&.blocked_reason.present?
      return true if workflow.state.in?(%w[succeeded failed cancelled])

      artifact_reason == StepDispatcher::MAIN_HEALTH_BLOCK_REASON &&
        StepDispatcher.main_health_blocking?(workflow)
    end

    def artifact_data
      artifacts = workflow.artifacts.to_h
      {
        reason: eligible_artifact_reason,
        at: artifacts["start_blocked_at"],
        next_check_at: artifacts["start_blocked_next_check_at"],
        count: artifacts["start_blocked_count"],
        details: artifacts["start_blocked_details"].presence || {}
      }
    end

    def parse_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def work_unit_data
      unit = workflow.work_unit
      details = unit.blocked_details.presence
      {
        reason: details.to_h["start_blocked_reason"].presence || unit.blocked_reason,
        at: unit.updated_at&.iso8601,
        next_check_at: unit.blocked_until&.iso8601,
        count: nil,
        details: details
      }
    end
  end
end
