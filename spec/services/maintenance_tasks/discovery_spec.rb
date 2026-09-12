require "rails_helper"

RSpec.describe MaintenanceTasks::Discovery do
  let(:definition) { StubMaintenanceDefinition.new }

  before do
    stub_const("StubMaintenanceDefinition", Class.new(MaintenanceTasks::Definitions::Base) do
      key "stub_backfill"
      title "Stub backfill"
      summary "A stub backfill for discovery specs."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "stub_backfill"

      def estimate_total_units = 5
      def pending_reason = "5 rows need backfill."
      def perform_batch(_) = raise NotImplementedError
    end)
    allow(MaintenanceTasks::Registry).to receive(:all).and_return([ definition ])
  end

  it "creates a pending task when a definition reports work" do
    described_class.call

    task = MaintenanceTask.find_by!(definition_key: "stub_backfill")
    expect(task.state).to eq("pending")
    expect(task.task_key).to eq("detector:stub_backfill")
    expect(task.events.last.message).to eq("5 rows need backfill.")
  end

  it "does not create a duplicate detector task when a migration already seeded the one-off" do
    MaintenanceTask.create!(
      definition_key: "stub_backfill",
      task_key: "migration:stub_backfill",
      state: "dismissed",
      recurrence: "one_off",
      category: "backfill",
      title: "Stub backfill",
      summary: "A stub backfill for discovery specs.",
      trigger_kind: "migration",
      trigger_key: "stub_backfill",
      required_role: "admin",
      total_units: 5
    )

    expect { described_class.call }.not_to change(MaintenanceTask, :count)
  end

  it "marks inactive pending tasks not needed when the definition no longer has work" do
    task = MaintenanceTask.create!(
      definition_key: "stub_backfill",
      task_key: "detector:stub_backfill",
      state: "pending",
      recurrence: "one_off",
      category: "backfill",
      title: "Stub backfill",
      summary: "A stub backfill for discovery specs.",
      trigger_kind: "detector",
      trigger_key: "stub_backfill",
      required_role: "admin",
      total_units: 5
    )
    allow(definition).to receive(:pending?).and_return(false)

    described_class.call

    expect(task.reload.state).to eq("not_needed")
  end
end
