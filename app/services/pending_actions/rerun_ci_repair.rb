module PendingActions
  class RerunCiRepair < Base
    action_key "rerun_ci_repair"

    def perform
      job = repair_action_job
      result = nil
      job.with_lock do
        job.reload
        RepairPreflight.ci_repair(job: job).ensure_eligible!
        progress!("Creating CI repair rerun...")
        result = CiRepair::ManualRerun.call(
          job: job,
          reason: reason,
          clear_handled_sha: payload.fetch("clear_handled_sha", true),
          instructions: payload["instructions"],
          override_repeated_sha: payload["override_repeated_sha"] == true,
          agent_provider: payload["agent_provider"]
        )
      end
      progress!("Recording repair audit...")
      audit!(
        "reran CI repair for #{result.refresh.head_sha}; cleared_handled_sha=#{result.cleared_handled_sha}",
        run: result.run
      )
      result.workflow
    end

    def execution_label
      "Starting CI repair rerun..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      return unless action.new_record? && payload["job_id"].present?

      job = repair_action_job_or_nil
      return unless job
      eligibility = RepairPreflight.ci_repair(job: job)
      errors.add(:payload, eligibility.blocking_preconditions.join("; ")) unless eligibility.eligible?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Re-run CI repair for #{presentation_job_slug}"
    end

    def presentation_detail
      payload["instructions"].presence
    end

    repairs_job!
  end
end
