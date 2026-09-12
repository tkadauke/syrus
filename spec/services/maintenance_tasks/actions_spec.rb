require "rails_helper"

RSpec.describe MaintenanceTasks::Actions do
  let(:admin) { User.create!(email_address: "admin@example.test", password: "password", password_confirmation: "password", global_role: "admin") }
  let(:definition) { instance_double(MaintenanceTasks::Definitions::AgentsBackfill, estimate_total_units: 3) }
  let(:task) do
    MaintenanceTask.create!(
      definition_key: "agents_backfill",
      task_key: "spec:agents_backfill",
      state: "pending",
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill agent records",
      summary: "Backfill missing Agent rows.",
      trigger_kind: "spec",
      trigger_key: "actions",
      required_role: "admin",
      total_units: 3
    )
  end

  before do
    admin
    allow(MaintenanceTasks::Registry).to receive(:fetch).with("agents_backfill").and_return(definition)
  end

  it "starts a pending task and records an audit event" do
    expect { described_class.start!(task, user: admin) }
      .to have_enqueued_job(MaintenanceTaskRunJob).with(task.id)

    expect(task.reload.state).to eq("running")
    expect(task.started_at).to be_present
    expect(task.requested_by_user).to eq(admin)
    expect(task.events.last.message).to eq("Started by #{admin.display_name}.")
  end

  it "keeps dismissed one-off tasks resumable" do
    described_class.dismiss!(task, user: admin)

    expect(task.reload.state).to eq("dismissed")

    expect { described_class.start!(task, user: admin) }
      .to have_enqueued_job(MaintenanceTaskRunJob).with(task.id)

    expect(task.reload.state).to eq("running")
    expect(task.dismissed_at).to be_nil
  end

  it "pauses and resumes a running task" do
    described_class.start!(task, user: admin)
    described_class.pause!(task, user: admin)

    expect(task.reload.state).to eq("paused")
    expect(task.paused_at).to be_present

    expect { described_class.resume!(task, user: admin) }
      .to have_enqueued_job(MaintenanceTaskRunJob).with(task.id)

    expect(task.reload.state).to eq("running")
  end
end
