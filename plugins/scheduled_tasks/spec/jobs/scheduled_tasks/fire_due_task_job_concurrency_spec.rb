require "rails_helper"

RSpec.describe "scheduled-task occurrence concurrency" do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name.match?(/mysql|trilogy/i)

    clear_enqueued_jobs
    @user = Factories.user
    @repository = Factories.repository(user: @user)
    @task = ScheduledTasks::Task.create!(
      user: @user, repository: @repository,
      name: "Concurrent schedule", prompt: "Do the work",
      kind: "cron", cron_expression: "0 * * * *", minute_offset: 1,
      pr_pileup_policy: "skip"
    )
  end

  after do
    next unless @task

    @task.jobs.find_each(&:destroy!)
    @task.destroy!
    @repository.destroy!
    @user.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "converges overlapping poll cohorts running on separate worker connections" do
    due_at = Time.current.utc.change(min: 2, sec: 0, usec: 0)
    exceptions_before = BackendExceptionEvent.where(job_class: ScheduledTasks::FireDueTaskJob.name).count

    freeze_time due_at do
      2.times { PollScheduledTasksJob.perform_now }
    end
    expect(enqueued_jobs.count { |entry| entry.fetch(:job) == ScheduledTasks::FireDueTaskJob }).to eq(2)

    ready = Queue.new
    start = Queue.new
    results = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          ScheduledTasks::FireDueTaskJob.perform_now(ScheduledTasks::Task.find(@task.id), due_at)
        end
      rescue StandardError => error
        results << error
      end
    end
    workers.size.times { ready.pop }
    workers.size.times { start << true }
    workers.each(&:join)

    errors = []
    errors << results.pop until results.empty?
    expect(errors).to be_empty
    expect(@task.jobs.count).to eq(1)
    expect(@task.occurrences.where(due_at: due_at.beginning_of_hour).count).to eq(1)
    expect(@task.reload.last_fired_at).to eq(due_at)
    expect(@task.consecutive_failure_count).to eq(0)
    expect(BackendExceptionEvent.where(job_class: ScheduledTasks::FireDueTaskJob.name).count).to eq(exceptions_before)
  end
end
