module PendingActions
  class ForceStateTransition < Base
    action_key "force_state_transition"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      JobStateRepair.force_transition!(job: job, event: payload.fetch("event"), reason: reason).job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "event is invalid") unless JobStateRepair::ForceTransition::ALLOWED_EVENTS.include?(payload["event"].to_s)
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, event: #{payload["event"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]
  end
end
