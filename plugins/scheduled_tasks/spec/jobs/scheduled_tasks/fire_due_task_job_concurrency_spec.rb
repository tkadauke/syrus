require "rails_helper"

RSpec.describe "scheduled-task occurrence concurrency" do
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name.match?(/mysql|trilogy/i)
    skip "forked worker processes are required" unless Process.respond_to?(:fork)

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

  it "converges overlapping poll cohorts in separate workers for distinct occurrences" do
    first_due_at = Time.current.utc.change(min: 2, sec: 0, usec: 0)
    second_due_at = first_due_at + 1.hour
    exceptions_before = BackendExceptionEvent.where(job_class: ScheduledTasks::FireDueTaskJob.name).count

    freeze_time first_due_at do
      2.times { PollScheduledTasksJob.perform_now }
    end
    expect(enqueued_jobs.count { |entry| entry.fetch(:job) == ScheduledTasks::FireDueTaskJob }).to eq(2)
    expect(run_in_worker_processes(first_due_at, count: 2)).to be_empty

    clear_enqueued_jobs
    freeze_time second_due_at do
      2.times { PollScheduledTasksJob.perform_now }
    end
    expect(enqueued_jobs.count { |entry| entry.fetch(:job) == ScheduledTasks::FireDueTaskJob }).to eq(2)
    expect(run_in_worker_processes(second_due_at, count: 2)).to be_empty

    expect(@task.jobs.count).to eq(2)
    expect(@task.occurrences.order(:due_at).pluck(:due_at)).to eq(
      [ first_due_at.beginning_of_hour, second_due_at.beginning_of_hour ]
    )
    expect(@task.reload.last_fired_at).to eq(second_due_at)
    expect(@task.consecutive_failure_count).to eq(0)
    expect(BackendExceptionEvent.where(job_class: ScheduledTasks::FireDueTaskJob.name).count).to eq(exceptions_before)
  end

  def run_in_worker_processes(due_at, count:)
    workers = count.times.map do
      ready_reader, ready_writer = IO.pipe
      start_reader, start_writer = IO.pipe
      result_reader, result_writer = IO.pipe
      pid = fork do
        ready_reader.close
        start_writer.close
        result_reader.close
        ActiveRecord::Base.connection_handler.clear_all_connections!
        ready_writer.write("ready")
        ready_writer.close
        start_reader.read(1)
        start_reader.close
        error = nil
        begin
          ActiveRecord::Base.connection_pool.with_connection do
            task = ScheduledTasks::Task.find(@task.id)
            ScheduledTasks::FireDueTaskJob.perform_now(task, due_at)
          end
        rescue StandardError => exception
          error = [ exception.class.name, exception.message ]
        ensure
          Marshal.dump(error, result_writer)
          result_writer.close
          ActiveRecord::Base.connection_handler.clear_all_connections!
          exit!(error ? 1 : 0)
        end
      end
      ready_writer.close
      start_reader.close
      result_writer.close
      { pid:, ready_reader:, start_writer:, result_reader: }
    end

    workers.each { |worker| expect(worker.fetch(:ready_reader).read).to eq("ready") }
    workers.each do |worker|
      worker.fetch(:start_writer).write("x")
      worker.fetch(:start_writer).close
    end
    workers.filter_map do |worker|
      error = Marshal.load(worker.fetch(:result_reader)) # rubocop:disable Security/MarshalLoad
      Process.wait(worker.fetch(:pid))
      error
    ensure
      worker.fetch(:ready_reader).close
      worker.fetch(:result_reader).close
    end
  end
end
