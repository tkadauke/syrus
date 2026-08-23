module WorkUnits
  class WorkflowBlockProjection
    REASON_MAP = {
      "manual_pause" => "manual_pause",
      "provider_availability" => "provider_availability",
      "workflow_admission_budget" => "admission_control",
      "landing start blocked: workflow admission budget" => "admission_control",
      "resource_safety" => "resource_safety",
      "main_branch_broken" => "main_branch_health",
      "dependency_failed" => "dependency_failed",
      "stack_dependencies_not_ready" => "stack_dependencies_not_ready",
      "stack_fan_in_base_unavailable" => "stack_fan_in_base_unavailable",
      "job_not_ready_for_execution" => "job_not_ready_for_execution",
      "urgent_job_active" => "urgent_job_active",
      "epic_wide_workflow_active" => "epic_wide_workflow_active"
    }.freeze

    def self.record!(workflow, start_blocked_reason:, blocked_until:, details: nil)
      new(workflow).record!(
        start_blocked_reason: start_blocked_reason,
        blocked_until: blocked_until,
        details: details
      )
    end

    def self.clear!(workflow, start_blocked_reason:)
      new(workflow).clear!(start_blocked_reason: start_blocked_reason)
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def record!(start_blocked_reason:, blocked_until:, details: nil)
      return unless unit&.active?

      unit.block!(
        reason: blocked_reason_for(start_blocked_reason),
        blocked_until: blocked_until,
        details: blocked_details_for(start_blocked_reason, details)
      )
    end

    def clear!(start_blocked_reason:)
      return unless unit&.blocked?
      return unless unit.blocked_details.to_h["start_blocked_reason"] == start_blocked_reason

      unit.unblock!
    end

    private

    attr_reader :workflow

    def unit
      workflow.work_unit
    end

    def blocked_reason_for(start_blocked_reason)
      REASON_MAP.fetch(start_blocked_reason.to_s, "preempted")
    end

    def blocked_details_for(start_blocked_reason, details)
      payload = details.is_a?(Hash) ? details : {}
      payload.merge("start_blocked_reason" => start_blocked_reason)
    end
  end
end
