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
      workflow.work_unit&.blocked_reason.presence || workflow.artifact("start_blocked_reason")
    end

    def details
      workflow.work_unit&.blocked_details.presence || workflow.artifact("start_blocked_details").presence || {}
    end

    def data
      return work_unit_data if workflow.work_unit&.blocked_reason.present?
      return artifact_data if artifact_reason.present?

      {}
    end

    def next_check_at
      workflow.work_unit&.blocked_until || parse_time(workflow.artifact("start_blocked_next_check_at"))
    end

    def blocked_for?(start_blocked_reason)
      if workflow.work_unit&.blocked_reason.present?
        workflow.work_unit.blocked_reason == self.class.work_unit_reason_for(start_blocked_reason)
      else
        artifact_reason == start_blocked_reason
      end
    end

    def landing_start_blocker?
      LandingQueueReentry.landing_start_blocker?(reason)
    end

    private

    attr_reader :workflow

    def artifact_reason
      workflow.artifact("start_blocked_reason")
    end

    def artifact_data
      {
        reason: artifact_reason,
        at: workflow.artifact("start_blocked_at"),
        next_check_at: workflow.artifact("start_blocked_next_check_at"),
        count: workflow.artifact("start_blocked_count"),
        details: workflow.artifact("start_blocked_details")
      }
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

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
