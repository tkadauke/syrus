require "rails_helper"

RSpec.describe ScheduledTasks::Filters::ScheduledTaskId do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  it "uses readable labels and filters by the exact task id" do
    task = ScheduledTasks::Task.create!(user: owner, repository: repository, name: "Morning briefing",
      prompt: "Brief me", kind: "cron", cron_expression: "0 9 * * *")
    matching = Factories.job_record(user: owner, repository: repository, kind: "cron", issue_number: nil, scheduled_task_id: task.id)
    other = Factories.job_record(user: owner, repository: repository, kind: "cron", issue_number: nil, scheduled_task_id: task.id + 1)

    expect(described_class.schema_values(owner)).to include("value" => task.id.to_s, "label" => "Morning briefing")
    expect(described_class.new(scope: Job.all, op: :is, value: task.id, user: owner).apply).to contain_exactly(matching)
    expect(described_class.new(scope: Job.all, op: :is, value: task.id, user: owner).apply).not_to include(other)
  end

  it "does not expose another user's schedules as selectable values" do
    other_user = Factories.user(email_address: "private-schedule@example.com")
    other_repository = Factories.repository(user: other_user, owner: "private", name: "repo")
    hidden = ScheduledTasks::Task.create!(user: other_user, repository: other_repository, name: "Private schedule",
      prompt: "Secret", kind: "cron", cron_expression: "0 9 * * *")

    expect(described_class.schema_values(owner).pluck("value")).not_to include(hidden.id.to_s)
  end
end
