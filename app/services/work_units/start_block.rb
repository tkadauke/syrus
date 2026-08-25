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
      workflow.work_unit&.blocked_reason.presence
    end

    def details
      workflow.work_unit&.blocked_details.presence || {}
    end

    def data
      return work_unit_data if workflow.work_unit&.blocked_reason.present?

      {}
    end

    def next_check_at
      workflow.work_unit&.blocked_until
    end

    def blocked_for?(start_blocked_reason)
      unit = workflow.work_unit
      return false unless unit

      unit.blocked_reason == self.class.work_unit_reason_for(start_blocked_reason) ||
        unit.blocked_reason == start_blocked_reason.to_s ||
        unit.blocked_details.to_h["start_blocked_reason"] == start_blocked_reason.to_s
    end

    def landing_start_blocker?
      LandingQueueReentry.landing_start_blocker?(reason)
    end

    private

    attr_reader :workflow

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
