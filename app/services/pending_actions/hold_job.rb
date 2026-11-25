module PendingActions
  class HoldJob < Base
    action_key "hold_job"

    def perform
      job = repair_action_job
      progress!("Holding #{job.slug}...")
      result = JobHold.call(
        job: job,
        reason: reason,
        to_backlog: to_backlog?,
        control_path: "pending_action#hold_job",
        source: { "pending_action_id" => @action&.id }
      )
      progress!("Recording repair audit...")
      audit!(
        "held job state=#{result.state} workflows=#{result.cancelled_workflow_ids.inspect} runs=#{result.cancelled_run_ids.inspect}",
        run: job.runs.reorder(created_at: :desc, id: :desc).first
      )
      job.reload
    end

    def execution_label
      "Holding Job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      validate_eligibility(errors)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, to_backlog: #{to_backlog?}"
    end

    def presentation_label
      I18n.t("server.mcp.hold_job_confirmation.label", job: presentation_job_slug)
    end

    def presentation_detail
      key = to_backlog? ? "detail_backlog" : "detail_waiting"
      I18n.t("server.mcp.hold_job_confirmation.#{key}")
    end

    repairs_job!

    private

    def to_backlog? = payload["to_backlog"] == true

    def validate_eligibility(errors)
      return unless action.new_record? && payload["job_id"].present?
      job = repair_action_job_or_nil
      return unless job

      JobHold.blockers(job, to_backlog: to_backlog?).each { |blocker| errors.add(:payload, blocker) }
    end
  end
end
