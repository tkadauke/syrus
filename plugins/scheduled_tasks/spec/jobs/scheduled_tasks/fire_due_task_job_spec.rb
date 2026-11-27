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

  it "retries safely through the job boundary after failure before Job creation" do
    now = Time.current.change(min: 2, sec: 0, usec: 0)
    calls = 0
    handler = Class.new(ScheduledTasks::FireHandlers::Base) do
      define_method(:fire!) do |now:|
        calls += 1
        raise "before create" if calls == 1

        Job.create!(
          user: task.user, repository: task.repository, kind: "direct",
          scheduled_task_id: task.id, origin: "scheduled_tasks", origin_id: task.id.to_s,
          issue_title: "Retryable scheduled work", issue_body: now.iso8601, issue_number: nil
        )
      end
    end
    teardown = ScheduledTasks::FireHandlers.register(target: :test, handler:) { |candidate| candidate.id == task.id }
    exceptions_before = BackendExceptionEvent.where(job_class: described_class.name).count

    expect { described_class.perform_now(task, now) }.not_to change { task.jobs.count }
    expect(task.reload.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)

    expect { described_class.perform_now(task.reload, now) }.to change { task.jobs.count }.by(1)

    expect(task.reload.last_fired_at).to eq(now)
    expect(task.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)
    expect(task.occurrences.sole.job).to eq(task.jobs.sole)
  ensure
    teardown&.call
  end

  it "retries safely through the job boundary after Job creation rolls back" do
    now = Time.current.change(min: 2, sec: 0, usec: 0)
    original_record_fire = task.method(:record_fire!)
    calls = 0
    allow(task).to receive(:record_fire!) do |**args|
      calls += 1
      raise "after create" if calls == 1

      original_record_fire.call(**args)
    end
    exceptions_before = BackendExceptionEvent.where(job_class: described_class.name).count

    expect { described_class.perform_now(task, now) }.not_to change { task.jobs.count }
    expect(task.occurrences.reload).to be_empty
    expect(task.reload.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)

    expect { described_class.perform_now(task, now) }.to change { task.jobs.count }.by(1)
    expect(task.reload.last_fired_at).to eq(now)
    expect(task.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)
    expect(task.occurrences.sole.job).to eq(task.jobs.sole)
  end
end
