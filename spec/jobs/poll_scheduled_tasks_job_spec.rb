require "rails_helper"

RSpec.describe PollScheduledTasksJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def cron_task(**overrides)
    ScheduledTask.create!({
      user: user, repository: repository,
      name: "T", prompt: "p",
      kind: "cron", cron_expression: "0 * * * *",
      minute_offset: 0,
      pr_pileup_policy: "skip"
    }.merge(overrides))
  end

  it "fires due tasks via ScheduledTaskFire" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)

    expect_any_instance_of(ScheduledTaskFire).to receive(:call)
      .and_return(ScheduledTaskFire::Result.new(job: nil, skipped: false, reason: nil))

    described_class.perform_now
  end

  it "leaves not-yet-due tasks alone" do
    freeze_time do
      task = cron_task
      now = Time.current
      task.update_columns(minute_offset: (now.min + 1) % 60, last_fired_at: 1.minute.ago)

      expect_any_instance_of(ScheduledTaskFire).not_to receive(:call)
      described_class.perform_now
    end
  end

  it "skips paused tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.pause!

    expect_any_instance_of(ScheduledTaskFire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips archived tasks" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    task.soft_delete!

    expect_any_instance_of(ScheduledTaskFire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips tasks for archived repositories" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    repository.archive!

    expect_any_instance_of(ScheduledTaskFire).not_to receive(:call)
    described_class.perform_now
  end

  it "skips tasks belonging to a user with scheduling paused" do
    task = cron_task
    task.update_columns(last_fired_at: 2.hours.ago)
    user.update!(scheduling_paused: true)

    expect_any_instance_of(ScheduledTaskFire).not_to receive(:call)
    described_class.perform_now
  end

  it "still fires tasks for other users when one user has scheduling paused" do
    paused_user = Factories.user(scheduling_paused: true)
    paused_repo = Factories.repository(user: paused_user)
    paused_task = ScheduledTask.create!(
      user: paused_user, repository: paused_repo,
      name: "Paused", prompt: "p",
      kind: "cron", cron_expression: "0 * * * *",
      pr_pileup_policy: "skip"
    )
    paused_task.update_columns(last_fired_at: 2.hours.ago)

    active_task = cron_task
    active_task.update_columns(last_fired_at: 2.hours.ago)

    fired_tasks = []
    allow_any_instance_of(ScheduledTaskFire).to receive(:call) do |svc|
      fired_tasks << svc.instance_variable_get(:@task)
      ScheduledTaskFire::Result.new(job: nil, skipped: false, reason: nil)
    end

    described_class.perform_now

    expect(fired_tasks).to contain_exactly(active_task)
  end

  it "isolates one bad task's failure from the rest of the pass" do
    bad  = cron_task(name: "bad")
    good = cron_task(name: "good")
    bad.update_columns(last_fired_at: 2.hours.ago)
    good.update_columns(last_fired_at: 2.hours.ago)

    call_count = 0
    allow_any_instance_of(ScheduledTaskFire).to receive(:call) do
      call_count += 1
      raise "boom" if call_count == 1
      ScheduledTaskFire::Result.new(job: nil, skipped: false, reason: nil)
    end

    expect { described_class.perform_now }.not_to raise_error
    expect(call_count).to eq(2)  # both tasks attempted
  end
end
