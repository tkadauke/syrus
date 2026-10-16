module PendingActions
  class RetireTerminalWorkUnit < Base
    action_key "retire_terminal_work_unit"

    def perform
      result = WorkUnits::TerminalLockCleanup.call(work_unit: target_work_unit, dry_run: payload["dry_run"] == true)
      result.eligibility.ensure_eligible! if result.status == "rejected"
      result.work_unit
    end

    def validate_payload(errors)
      errors.add(:payload, "work_unit_id is required") unless payload["work_unit_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      return unless action.new_record? && payload["work_unit_id"].present?

      eligibility = RepairPreflight.terminal_work_unit(work_unit: target_work_unit)
      errors.add(:payload, eligibility.blocking_preconditions.join("; ")) unless eligibility.eligible?
    rescue ActiveRecord::RecordNotFound
      errors.add(:payload, "work_unit not found")
    end

    def execution_label = "Retiring terminal WorkUnit and releasing locks..."
    def presentation_label = "Retire terminal WorkUnit #{payload['work_unit_id']}"
    def presentation_detail = "Only the stale WorkUnit and its active locks are changed."

    def repair_action? = true
    def repair_snapshot_targets = target_work_unit.work_unit_members.includes(:job).map(&:job)

    private

    def target_work_unit = WorkUnit.find(payload.fetch("work_unit_id"))
  end
end
