module PendingActions
  class RebaseJob < Base
    action_key "rebase_job"

    def execute
      job = repair_action_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to rebase."
      end
      if RebaseWorkflowSelector.active_for_stack?(job)
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end

      workflow = RebaseWorkflowSelector.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def repair_action?
      true
    end

    def repair_snapshot_targets
      [ repair_action_job_or_nil ]
    end
  end
end
