require "rails_helper"

RSpec.describe RecurringTaskTickJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def recurring_task(**overrides)
    RecurringTask.create!({
      user: user,
      repository: repository,
      label: "Hourly review",
      prompt: "Look for useful maintenance work.",
      cron_expression: "0 * * * *"
    }.merge(overrides))
  end

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "fires due tasks as ad hoc Jobs and advances the schedule from now" do
    travel_to Time.utc(2026, 5, 13, 12, 0, 0) do
      task = recurring_task
      task.update!(next_fire_at: 1.minute.ago)

      expect {
        described_class.perform_now
      }.to change { Job.adhoc_kind.count }.by(1)

      job = Job.adhoc_kind.last
      expect(job).to have_attributes(
        user: user,
        repository: repository,
        issue_title: "Recurring task: Hourly review",
        issue_body: "Look for useful maintenance work."
      )
      expect(StepDispatcher).to have_received(:start_workflow) do |workflow, prompt:|
        expect(workflow.job).to eq(job)
        expect(prompt).to include("Look for useful maintenance work.")
      end
      expect(task.reload.next_fire_at).to eq(Time.utc(2026, 5, 13, 13, 0, 0))
    end
  end

  it "skips disabled tasks" do
    task = recurring_task(enabled: false)
    task.update_columns(next_fire_at: 1.minute.ago)

    expect {
      described_class.perform_now
    }.not_to change { Job.count }
  end

  it "skips tasks for users with scheduling paused" do
    task = recurring_task
    task.update_columns(next_fire_at: 1.minute.ago)
    user.update!(scheduling_paused: true)

    expect {
      described_class.perform_now
    }.not_to change { Job.count }
  end
end
