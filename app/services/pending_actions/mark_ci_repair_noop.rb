module PendingActions
  class MarkCiRepairNoop < Base
    action_key "mark_ci_repair_noop"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      workflow = job.workflows.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow is not a ci_failure repair." unless workflow.trigger_kind == "ci_failure"

      marker = {
        "reason" => reason,
        "marked_at" => Time.current.iso8601,
        "observed_head_sha" => payload["observed_head_sha"],
        "observed_pr_checks_state" => payload["observed_pr_checks_state"],
        "observed_failed_checks" => payload["observed_failed_checks"]
      }.compact
      workflow.set_artifact!("ci_repair_noop", marker)
      job.update!(landing_failure_reason: landing_failure_reason(job, workflow))
      audit!(workflow)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}; workflow_id: #{payload["workflow_id"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def landing_failure_reason(job, workflow)
      prefix = "ci_repair_noop: #{job.slug} #{workflow.slug}"
      text = "#{prefix} made no effective branch/check progress; #{reason}"
      text.first(1_000)
    end

    def audit!(workflow)
      run = workflow.runs.order(created_at: :desc, id: :desc).first || workflow.job.current_run
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] marked #{workflow.slug} as CI repair no-op; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
