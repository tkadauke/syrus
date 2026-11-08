module PendingActions
  class RerunCiRepair < Base
    action_key "rerun_ci_repair"

    def perform
      job = repair_action_job
      result = nil
      # Announced before the lock, not inside it: a progress write is a write
      # to the pending action, and a write made inside another record's
      # transaction is undone if that transaction rolls back.
      progress!("Creating CI repair rerun...")
      job.with_lock do
        job.reload
        RepairPreflight.ci_repair(job: job).ensure_eligible!
        result = CiRepair::ManualRerun.call(
          job: job,
          reason: reason,
          clear_handled_sha: payload.fetch("clear_handled_sha", true),
          instructions: payload["instructions"],
          override_repeated_sha: payload["override_repeated_sha"] == true,
          agent_provider: payload["agent_provider"],
          expected_head_sha: payload["observed_head_sha"]
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
