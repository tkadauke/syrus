module WorkUnits
  class TerminalLockCleanup
    def self.preflight(work_unit)
      workflow = work_unit.workflow
      blockers = []
      blockers << "WorkUnit is already terminal" unless work_unit.active?
      blockers << "WorkUnit has no Workflow" unless workflow
      blockers << "Workflow is not terminal" unless workflow&.terminal?
      blockers << "Workflow still has queued or running Runs" if workflow&.runs&.active&.exists?
      locks = work_unit.work_unit_locks.active.pluck(:id, :lock_key)
      blockers << "WorkUnit owns no active locks" if locks.empty?
      RepairPreflight::Result.new(eligible: blockers.empty?, operation: "retire_terminal_work_unit", target: { work_unit_id: work_unit.id, workflow_id: workflow&.id, workflow_state: workflow&.state, lock_ids: locks.map(&:first), lock_keys: locks.map(&:last) }, blockers: blockers, expected_mutations: blockers.empty? ? { work_units: 1, locks: locks.size } : {})
    end

    def self.call!(work_unit)
      work_unit.with_lock do
        work_unit.reload
        plan = preflight(work_unit)
        raise ArgumentError, plan.rejection_message unless plan.eligible?

        work_unit.mark_terminal!("cancelled")
        plan
      end
    end
  end
end
