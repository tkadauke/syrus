module PendingActions
  class OverrideJobPlannedExecution < Base
    action_key "override_job_planned_execution"
    admin_only!
    repairs_job!

    def perform
      result = PlannedExecutionOverrides::Operation.new(
        job: repair_action_job,
        profile: payload.fetch("profile"),
        actor: user,
        reason: reason,
        provenance: "syrus_chat",
        expected_revision: payload.fetch("observed_entity_revision")
      ).apply!
      progress!("Placement updated for #{result.job.slug}.")
      result.job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "profile is required") unless payload["profile"].present?
      errors.add(:payload, "observed_entity_revision is required") unless payload["observed_entity_revision"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail = "job_id: #{payload['job_id']}, profile: #{payload['profile']}"
    def presentation_label = "Override placement for #{presentation_job_slug}"
    def presentation_detail = "Profile: #{payload['profile']}"
  end
end
