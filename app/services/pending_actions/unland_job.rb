module PendingActions
  class UnlandJob < Base
    action_key "unland_job"
    repairs_job!

    def execute
      progress!("Creating linked rollback for #{action_job.slug}...")
      Unlanding::Create.call!(original: action_job, user: user)
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def presentation_label = "Unland #{presentation_job_slug}"
  end
end
