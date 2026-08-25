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
      return workflow.work_unit.blocked_reason.presence if workflow.work_unit

      artifact_reason if legacy_artifact_fallback?
    end

    def details
      return workflow.work_unit.blocked_details.presence || {} if workflow.work_unit

      legacy_artifact_fallback? ? workflow.artifact("start_blocked_details").presence || {} : {}
    end

    def data
      return work_unit_data if workflow.work_unit&.blocked_reason.present?
      return artifact_data if legacy_artifact_fallback? && artifact_reason.present?

      {}
    end

    def next_check_at
      return workflow.work_unit.blocked_until if workflow.work_unit

      parse_time(workflow.artifact("start_blocked_next_check_at")) if legacy_artifact_fallback?
    end

    def blocked_for?(start_blocked_reason)
      if workflow.work_unit
        workflow.work_unit.blocked_reason == self.class.work_unit_reason_for(start_blocked_reason)
      else
        legacy_artifact_fallback? && artifact_reason == start_blocked_reason
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

    def legacy_artifact_fallback?
      workflow.trigger_kind == WorkUnits::Ownership::LEGACY_REPLAY_TRIGGER_KIND
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
