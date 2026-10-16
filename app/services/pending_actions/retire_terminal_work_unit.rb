module PendingActions
  class RetireTerminalWorkUnit < Base
    action_key "retire_terminal_work_unit"
    admin_only!

    def perform
      unit = WorkUnit.find(payload.fetch("work_unit_id"))
      plan = WorkUnits::TerminalLockCleanup.call!(unit)
      action.update!(payload: payload.merge("repair_outcome" => "applied", "mutation_counts" => plan.expected_mutations))
      unit.reload
    end

    def validate_payload(errors)
      errors.add(:payload, "work_unit_id is required") unless payload["work_unit_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      return unless action.new_record? && payload["work_unit_id"].present?

      unit = WorkUnit.find_by(id: payload["work_unit_id"])
      errors.add(:payload, "work unit not found") and return unless unit
      plan = WorkUnits::TerminalLockCleanup.preflight(unit)
      errors.add(:payload, plan.rejection_message) unless plan.eligible?
    end

    def repair_action? = true
    def repair_snapshot_targets = [ WorkUnit.find_by(id: payload["work_unit_id"])&.workflow&.job ].compact
    def presentation_label = "Retire stale terminal Workflow ownership"
    def presentation_detail = "WorkUnit: WU-#{payload['work_unit_id']}"
  end
end
