module PendingActions
  class ReconcileJobState < Base
    action_key "reconcile_job_state"

    MODES = %w[
      auto
      mark_implemented_from_ready_pr
      mark_failed
      mark_queued
    ].freeze

    GUARD_METHODS = {
      "mark_queued" => :may_retry_after_failure?
    }.freeze

    def perform
      job = repair_action_job
      mode = payload.fetch("mode").to_s
      job.with_lock do
        job.reload
        eligibility = RepairPreflight.reconcile_job_state(job: job, mode: mode)
        eligibility.ensure_eligible!
        progress!("Reconciling #{job.slug} with mode #{mode} to #{eligibility.target_state}...")
        JobStateRepair.reconcile!(job: job, mode: mode, reason: reason).job
      end
    end

    def execution_label
      "Reconciling job state..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "mode is invalid") unless MODES.include?(payload["mode"].to_s)
      errors.add(:reason, "is required") if reason.blank?
      validate_transition_guard(errors)
      validate_auto_eligibility(errors)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, mode: #{payload["mode"]}"
    end

    def presentation_label
      "Reconcile state for #{presentation_job_slug} (#{payload["mode"]})"
    end

    def presentation_detail
      "Mode: #{payload["mode"]}"
    end

    repairs_job!

    private

    def validate_transition_guard(errors)
      return unless action.new_record?
      return unless payload["job_id"].present? && MODES.include?(payload["mode"].to_s)

      guard = GUARD_METHODS[payload["mode"].to_s]
      return unless guard

      job = repair_action_job_or_nil
      return unless job

      errors.add(:payload, "#{job.slug} cannot apply #{payload["mode"]} from #{job.state}") unless job.public_send(guard)
    end

    def validate_auto_eligibility(errors)
      return unless action.new_record?
      return unless payload["mode"].to_s == "auto" && payload["job_id"].present?

      job = repair_action_job_or_nil
      return unless job
      eligibility = RepairPreflight.reconcile_job_state(job: job, mode: "auto")
      errors.add(:payload, eligibility.blocking_preconditions.join("; ")) unless eligibility.eligible?
    end
  end
end
