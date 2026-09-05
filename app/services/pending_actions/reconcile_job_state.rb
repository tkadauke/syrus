module PendingActions
  class ReconcileJobState < Base
    action_key "reconcile_job_state"

    MODES = %w[
      auto
      mark_implemented_from_ready_pr
      mark_failed
      mark_queued
    ].freeze

    def perform
      job = repair_action_job
      mode = payload.fetch("mode").to_s
      progress!("Reconciling #{job.slug} with mode #{mode}...")
      JobStateRepair.reconcile!(job: job, mode: mode, reason: reason).job
    end

    def execution_label
      "Reconciling job state..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "mode is invalid") unless MODES.include?(payload["mode"].to_s)
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, mode: #{payload["mode"]}"
    end

    repairs_job!
  end
end
