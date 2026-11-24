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
      "Hold #{presentation_job_slug}"
    end

    def presentation_detail
      return nil unless payload["job_id"].present? && user

      job = repair_action_job_or_nil
      return nil unless job

      runs = JobHold.active_runs(job).map(&:slug)
      workflows = JobHold.active_workflows(job).map(&:slug)
      [
        runs.presence&.then { |slugs| "Cancels Runs: #{slugs.join(", ")}" },
        workflows.presence&.then { |slugs| "Cancels Workflows: #{slugs.join(", ")}" },
        to_backlog? ? "Moves to backlog" : "Returns to waiting on dependencies",
        "Keeps the Job open, its PR and its branch"
      ].compact.join("\n")
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
