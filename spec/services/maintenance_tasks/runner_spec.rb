require "rails_helper"

RSpec.describe MaintenanceTasks::Runner do
  class SpecDirtyStepMaintenanceDefinition < MaintenanceTasks::Definitions::Base
    key "spec_dirty_step"
    title "Spec dirty step"
    summary "Exercises dirty step progress handling."
    category "cleanup"
    recurrence "one_off"
    required_role "admin"

    def estimate_total_units = 1

    def perform_batch(task)
      task.current_step_key = "retire"
      task.current_step_title = "Retire stale cards"
      Result.new(done: true, processed: 1, failed: 0, message: "Done.", level: "info")
    end
  end

  it "persists step progress when the definition mutates the task before locking" do
    task = MaintenanceTask.create!(
      definition_key: "spec_dirty_step",
      task_key: "spec:dirty-step",
      state: "running",
      recurrence: "one_off",
      category: "cleanup",
      title: "Spec dirty step",
      summary: "Exercises dirty step progress handling.",
      trigger_kind: "spec",
      trigger_key: "dirty-step",
      required_role: "admin",
      total_units: 1
    )

    allow(MaintenanceTasks::Registry).to receive(:fetch)
      .with("spec_dirty_step")
      .and_return(SpecDirtyStepMaintenanceDefinition.new)

    described_class.new(task).call

    expect(task.reload).to have_attributes(
      state: "succeeded",
      completed_units: 1,
      current_step_key: "retire",
      current_step_title: "Retire stale cards",
      last_error: nil
    )
    expect(task.events.last).to have_attributes(
      level: "info",
      step_key: "retire",
      step_title: "Retire stale cards",
      message: "Done."
    )
  end
end
