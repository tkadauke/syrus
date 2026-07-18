module PendingActions
  # Enqueues a background job to capture and submit committed coding-mode
  # changes as a new direct Job with a CodingHandoff workflow. The actual
  # filesystem work (CodingHandoffCapture) runs on the worker pod, which
  # mounts the data PVC where coding checkouts live. Web pods do not mount
  # that volume, so running capture! inline here would always fail.
  class SubmitCodingChanges < Base
    action_key "submit_coding_changes"

    def execute
      user.repositories.active.find(payload.fetch("repository_id"))
      CodingHandoffConfirmJob.perform_later(action.id)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "branch is required") unless payload["branch"].present?
      errors.add(:payload, "title is required") unless payload["title"].present?
      errors.add(:payload, "description is required") unless payload["description"].present?
    end

    def action_detail
      "branch: #{payload["branch"]}, repository_id: #{payload["repository_id"]}"
    end
  end
end
