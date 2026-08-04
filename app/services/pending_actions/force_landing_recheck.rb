module PendingActions
  class ForceLandingRecheck < Base
    action_key "force_landing_recheck"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      result = LandingQueueRecheck.call(job)
      audit!(job, result)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def audit!(job, result)
      run = job.current_run
      return unless run

      refreshed = result.refreshed_state
      JobLog.append!(
        run: run,
        chunk: "[operator repair] forced landing recheck; blocker=#{refreshed[:landing_queue_blocked_reason].inspect}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
