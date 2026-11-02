class RepairNonOsPlannedExecutionCapabilities < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Repairing forbidden non-OS planned-execution capabilities" do
      result = Maintenance::RepairNonOsPlannedExecutionCapabilities.call
      say "repaired #{result.job_ids.size} Jobs and #{result.workflow_ids.size} queued Workflows", true
    end
  end

  def down
    # One-time audited data repair; restoring invalid admission constraints is unsafe.
  end
end
