module PendingActions
  class RerunCiRepair < Base
    action_key "rerun_ci_repair"

    def perform
      job = repair_action_job
      preflight = RepairPreflight.job_locks(job: job, operation: "rerun_ci_repair")
      raise ArgumentError, preflight.rejection_message unless preflight.eligible?
      progress!("Creating CI repair rerun...")
      result = CiRepair::ManualRerun.call(
        job: job,
        reason: reason,
        clear_handled_sha: payload.fetch("clear_handled_sha", true),
        instructions: payload["instructions"],
        override_repeated_sha: payload["override_repeated_sha"] == true,
        agent_provider: payload["agent_provider"]
      )
      progress!("Recording repair audit...")
      audit!(
        "reran CI repair for #{result.refresh.head_sha}; cleared_handled_sha=#{result.cleared_handled_sha}",
        run: result.run
      )
      action.update!(payload: payload.merge("repair_outcome" => "applied", "mutation_counts" => { "workflows" => 1, "work_units" => 1 }))
      result.workflow
    end

    def execution_label
      "Starting CI repair rerun..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      return unless action.new_record? && payload["job_id"].present? && (job = repair_action_job_or_nil)

      preflight = RepairPreflight.job_locks(job: job, operation: "rerun_ci_repair")
      errors.add(:payload, preflight.rejection_message) unless preflight.eligible?
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
