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
      workflow.artifact("start_blocked_reason").presence || workflow.work_unit&.blocked_reason
    end

    def details
      workflow.artifact("start_blocked_details").presence || workflow.work_unit&.blocked_details || {}
    end

    def next_check_at
      parse_time(workflow.artifact("start_blocked_next_check_at")) || workflow.work_unit&.blocked_until
    end

    def blocked_for?(start_blocked_reason)
      workflow.artifact("start_blocked_reason") == start_blocked_reason ||
        workflow.work_unit&.blocked_reason == self.class.work_unit_reason_for(start_blocked_reason)
    end

    def landing_start_blocker?
      LandingQueueReentry.landing_start_blocker?(reason)
    end

    private

    attr_reader :workflow

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
