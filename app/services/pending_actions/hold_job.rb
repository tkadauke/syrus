module PendingActions
  class HoldJob < Base
    action_key "hold_job"

    # Owners may hold their own Jobs and admins any Job (repair_action_job
    # scopes the lookup); this is not an admin-only repair.
    def execute
      perform
    end

    def perform
      job = repair_action_job
      progress!("Holding #{job.slug}...")
      result = ApplicationRecord.transaction do
        apply_dependency_edit!(job) if dependency_edit
        JobHold.call(
          job: job,
          reason: reason,
          to_backlog: to_backlog?,
          control_path: "pending_action#hold_job",
          source: { "pending_action_id" => @action&.id }
        )
      end
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
      [ "job_id: #{payload["job_id"]}, to_backlog: #{to_backlog?}",
        ("dependency_edit: #{dependency_edit["tool"]} #{dependency_edit["arguments"].to_json}" if dependency_edit) ].compact.join(", ")
    end

    def presentation_label
      I18n.t("server.mcp.hold_job_confirmation.label", job: presentation_job_slug)
    end

    def presentation_detail
      key = to_backlog? ? "detail_backlog" : "detail_waiting"
      detail = I18n.t("server.mcp.hold_job_confirmation.#{key}")
      return detail unless dependency_edit

      [ detail, I18n.t("server.mcp.hold_job_confirmation.detail_dependency_edit", tool: dependency_edit["tool"]) ].join(" ")
    end

    repairs_job!

    private

    def to_backlog? = payload["to_backlog"] == true

    def dependency_edit
      edit = payload["dependency_edit"]
      edit.is_a?(Hash) && edit.present? ? edit : nil
    end

    # Applies the dependency edit the hold was requested with. The guard lets
    # it through although the Job is still running; JobHold then cancels the
    # running work in the same transaction, and a failed edit rolls both back.
    def apply_dependency_edit!(job)
      JobDependencyEditGuard.deferring_to_hold(job) do
        JobDependencyEdits.apply!(job:, user:, tool: dependency_edit["tool"], arguments: dependency_edit["arguments"])
      end
    rescue ActiveRecord::RecordInvalid => e
      raise ArgumentError, e.record.errors.full_messages.to_sentence
    end

    def validate_eligibility(errors)
      return unless action.new_record? && payload["job_id"].present?
      job = repair_action_job_or_nil
      return unless job

      if dependency_edit && !JobDependencyEdits::TOOLS.include?(dependency_edit["tool"])
        errors.add(:payload, "dependency_edit tool is not supported")
      end
      JobHold.blockers(job, to_backlog: to_backlog?, pending_dependency_edit: dependency_edit.present?)
        .each { |blocker| errors.add(:payload, blocker) }
    end
  end
end
