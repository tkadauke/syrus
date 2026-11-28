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
    expect(task.occurrences.sole).to have_attributes(completed_at: nil, failed_at: now)
    expect(task.reload.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)

    expect { described_class.perform_now(task, now) }.to change { task.jobs.count }.by(1)
    expect(task.reload.last_fired_at).to eq(now)
    expect(task.consecutive_failure_count).to eq(1)
    expect(BackendExceptionEvent.where(job_class: described_class.name).count).to eq(exceptions_before + 1)
    expect(task.occurrences.sole.job).to eq(task.jobs.sole)
  end

  it "retries the exact failed occurrence for a system schedule without defeating its poll backoff" do
    now = Time.at(Time.utc(2026, 11, 4, 3, 15).to_i, 123_456, :microsecond).utc
    definition = Class.new(ScheduledTasks::SystemSchedules::Definition) do
      def prompt(task:, target_date:) = "System work for #{target_date || task.id}"
      def failure_date(task:, now:) = now.to_date
    end
    allow(ScheduledTasks::SystemSchedules).to receive(:fetch).with("test_retry").and_return(definition)
    system_task = ScheduledTasks::Task.create!(
      user: user, repository: repository,
      name: "System work", kind: "cron", system_key: "test_retry",
      cron_expression: "0 * * * *", minute_offset: 1, pr_pileup_policy: "skip"
    )
    calls = 0
    handler = Class.new(ScheduledTasks::FireHandlers::Base) do
      define_method(:fire!) do |now:|
        calls += 1
        raise "system failure" if calls == 1

        Job.create!(
          user: task.user, repository: task.repository, kind: "direct",
          scheduled_task_id: task.id, origin: "scheduled_tasks", origin_id: task.id.to_s,
          issue_title: "Retryable system work", issue_body: now.iso8601, issue_number: nil
        )
      end
    end
    teardown = ScheduledTasks::FireHandlers.register(target: :test, handler:) do |candidate|
      candidate.id == system_task.id
    end

    expect { described_class.perform_now(system_task, now) }.not_to change { system_task.jobs.count }
    expect(system_task.reload).to have_attributes(last_fired_at: now, consecutive_failure_count: 1)
    expect(system_task.occurrences.sole).to have_attributes(completed_at: nil, failed_at: now)

    expect { described_class.perform_now(system_task, now + 1.minute) }.not_to change { system_task.jobs.count }
    expect(calls).to eq(1)

    expect { described_class.perform_now(system_task, now) }.to change { system_task.jobs.count }.by(1)
    expect(calls).to eq(2)
    expect(system_task.reload).to have_attributes(last_fired_at: now, consecutive_failure_count: 1)
    expect(system_task.occurrences.sole).to have_attributes(completed_at: be_present, failed_at: nil)
    expect(system_task.occurrences.sole.job).to eq(system_task.jobs.sole)
  ensure
    teardown&.call
  end

  it "keeps a system schedule's failure accounting when its failure callback raises" do
    now = Time.utc(2026, 11, 4, 3, 15)
    definition = Class.new(ScheduledTasks::SystemSchedules::Definition) do
      def prompt(task:, target_date:) = "System work for #{target_date || task.id}"
      def failure_date(task:, now:) = now.to_date
      def failure_recorded(task:, date:, reason:) = raise("alert channel missing")
    end
    allow(ScheduledTasks::SystemSchedules).to receive(:fetch).with("test_alert").and_return(definition)
    system_task = ScheduledTasks::Task.create!(
      user: user, repository: repository,
      name: "System alert work", kind: "cron", system_key: "test_alert",
      cron_expression: "0 * * * *", minute_offset: 1, pr_pileup_policy: "skip"
    )
    handler = Class.new(ScheduledTasks::FireHandlers::Base) do
      define_method(:fire!) { |now:| raise "system failure" }
    end
    teardown = ScheduledTasks::FireHandlers.register(target: :test, handler:) do |candidate|
      candidate.id == system_task.id
    end

    described_class.perform_now(system_task, now)

    # Rolling the accounting back leaves the task due again on the next
    # minute's poll, so a broken alert path turned backoff into a retry loop.
    expect(system_task.reload).to have_attributes(last_fired_at: now, consecutive_failure_count: 1,
                                                  last_system_result: "failed")
    expect(system_task.occurrences.sole).to have_attributes(completed_at: nil, failed_at: now)
  ensure
    teardown&.call
  end
end
