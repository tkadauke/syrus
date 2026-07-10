module PendingActions
  # Confirmed when the operator accepts handoff from a Coding Mode session.
  # The full execution (push validation, PR open, grader dispatch) is wired
  # by the coding session infrastructure in a sibling Epic Job; this handler
  # records the intent so the pending action lifecycle completes cleanly.
  class CompleteImplementStep < Base
    action_key "complete_implement_step"

    def execute
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
