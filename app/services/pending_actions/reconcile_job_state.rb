module PendingActions
  class ReconcileJobState < Base
    action_key "reconcile_job_state"

    MODES = %w[
      auto
      mark_implemented_from_ready_pr
      mark_failed
      mark_queued
    ].freeze

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      mode = payload.fetch("mode").to_s
      JobStateRepair.reconcile!(job: job, mode: mode, reason: reason).job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "mode is invalid") unless MODES.include?(payload["mode"].to_s)
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, mode: #{payload["mode"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]
  end
end
