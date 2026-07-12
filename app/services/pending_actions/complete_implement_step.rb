module PendingActions
  # Confirmed when the operator accepts handoff from a Coding Mode session.
  # Transitions the job out of :coding and fires a CodingHandoff workflow so
  # graders, summarize, and PR automation run.
  class CompleteImplementStep < Base
    action_key "complete_implement_step"

    def execute
      job = action_user_job
      raise ArgumentError, "job is not in coding state" unless job.coding?

      workflow = job.start_coding_handoff!
      raise ArgumentError, "could not start coding handoff" unless workflow

      workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
