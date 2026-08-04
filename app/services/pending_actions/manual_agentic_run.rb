module PendingActions
  class ManualAgenticRun < Base
    action_key "manual_agentic_run"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      result = ::ManualAgenticRun::Enqueuer.call(
        job: repair_action_job,
        base: payload.fetch("base"),
        instructions: payload.fetch("instructions"),
        reason: reason,
        push: payload.fetch("push", true),
        failed_workflow_id: payload["failed_workflow_id"]
      )
      result.workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "base is invalid") unless ::ManualAgenticRun::BaseSelection::VALUES.include?(payload["base"].to_s)
      errors.add(:payload, "instructions are required") if payload["instructions"].to_s.strip.blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, base: #{payload["base"]}, push: #{payload.fetch("push", true)}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]
  end
end
