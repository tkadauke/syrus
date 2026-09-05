module PendingActions
  class ForceStateTransition < Base
    action_key "force_state_transition"

    def perform
      job = repair_action_job
      progress!("Forcing #{payload.fetch("event")} on #{job.slug}...")
      JobStateRepair.force_transition!(job: job, event: payload.fetch("event"), reason: reason).job
    end

    def execution_label
      "Forcing job state transition..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "event is invalid") unless JobStateRepair::ForceTransition::ALLOWED_EVENTS.include?(payload["event"].to_s)
      errors.add(:reason, "is required") if reason.blank?
      validate_transition_guard(errors)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, event: #{payload["event"]}"
    end

    repairs_job!

    private

    def validate_transition_guard(errors)
      return unless action.new_record?

      event = payload["event"].to_s
      return unless payload["job_id"].present? && JobStateRepair::ForceTransition::ALLOWED_EVENTS.include?(event)

      job = repair_action_job_or_nil
      return unless job

      errors.add(:payload, "#{job.slug} cannot apply #{event} from #{job.state}") unless job.public_send("may_#{event}?")
    end
  end
end
