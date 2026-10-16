module WorkUnits
  class TerminalLockCleanup
    Result = Data.define(:status, :work_unit, :eligibility, :mutation_count)

    def self.call(work_unit:, dry_run: false) = new(work_unit, dry_run: dry_run).call

    def initialize(work_unit, dry_run:)
      @work_unit = work_unit
      @dry_run = dry_run
    end

    def call
      WorkUnit.transaction do
        work_unit.lock!
        eligibility = RepairPreflight.terminal_work_unit(work_unit: work_unit)
        return Result.new(status: eligibility.status, work_unit: work_unit, eligibility: eligibility, mutation_count: 0) if dry_run || eligibility.noop?
        eligibility.ensure_eligible!

        lock_count = work_unit.work_unit_locks.active.count
        work_unit.update!(preemption_reason: "terminal_workflow_lock_cleanup")
        work_unit.mark_terminal!(:cancelled)
        Result.new(status: "applied", work_unit: work_unit, eligibility: eligibility, mutation_count: lock_count + 1)
      end
    end

    private

    attr_reader :work_unit, :dry_run
  end
end
