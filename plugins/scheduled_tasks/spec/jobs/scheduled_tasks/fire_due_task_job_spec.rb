require "rails_helper"

RSpec.describe ScheduledTasks::FireDueTaskJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:task) do
    ScheduledTasks::Task.create!(
      user: user,
      repository: repository,
      name: "Scheduled work",
      prompt: "Do the work",
      kind: "cron",
      cron_expression: "0 * * * *",
      minute_offset: 1,
      pr_pileup_policy: "skip"
    )
  end

  it "uses a consumed queue" do
    expect(described_class.new.queue_name).to eq("polling")
  end

  it "fires against the poll timestamp and requires the task to be due" do
    now = Time.current.change(min: 2, sec: 0, usec: 0)
    result = ScheduledTasks::Fire::Result.new(job: nil, skipped: true, reason: "not_due")

    expect(ScheduledTasks::Fire).to receive(:new)
      .with(task, now: now, require_due: true)
      .and_return(instance_double(ScheduledTasks::Fire, call: result))

    described_class.perform_now(task, now)
  end
end
