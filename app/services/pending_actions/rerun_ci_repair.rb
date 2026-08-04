module PendingActions
  class RerunCiRepair < Base
    action_key "rerun_ci_repair"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      result = CiRepair::ManualRerun.call(
        job: repair_action_job,
        reason: reason,
        clear_handled_sha: payload.fetch("clear_handled_sha", true),
        instructions: payload["instructions"],
        override_repeated_sha: payload["override_repeated_sha"] == true,
        agent_provider: payload["agent_provider"]
      )
      audit!(result)
      result.workflow
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

    def audit!(result)
      JobLog.append!(
        run: result.run,
        chunk: "[operator repair] reran CI repair for #{result.refresh.head_sha}; cleared_handled_sha=#{result.cleared_handled_sha}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
