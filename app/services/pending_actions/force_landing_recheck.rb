module PendingActions
  class ForceLandingRecheck < Base
    action_key "force_landing_recheck"

    def perform
      job = repair_action_job
      result = LandingQueueRecheck.call(job) { |message| progress!(message) }
      refreshed = result.refreshed_state
      audit!("forced landing recheck; blocker=#{refreshed[:landing_queue_blocked_reason].inspect}", run: job.current_run)
      nil
    end

    def execution_label
      "Refreshing landing state..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    repairs_job!
  end
end
