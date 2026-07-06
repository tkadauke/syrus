module PendingActions
  class ReopenEpicAndAttachJob < Base
    action_key "reopen_epic_and_attach_job"

    def execute
      epic = repository.epics.where(user: user).find(payload.fetch("epic_id"))
      job = action_job

      epic.in_progress! if epic.done?
      job.update!(epic: epic, pending_epic_reference: {})
      job.advance_after_triage! if job.may_advance_after_triage?
      job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
    end

    def action_detail
      "epic_id: #{payload["epic_id"]}, job_id: #{payload["job_id"]}"
    end
  end
end
