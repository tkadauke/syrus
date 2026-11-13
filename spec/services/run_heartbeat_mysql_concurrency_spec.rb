require "rails_helper"

RSpec.describe "Run heartbeat MySQL lock contention" do
  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name == "Mysql2"

    @job = Factories.job_record
    @workflow = Workflow.create!(job: @job, trigger_kind: "initial", state: "running")
    @step = Step.create!(workflow: @workflow, kind: "grader", position: 0, state: "running")
    @run = Run.create!(
      job: @job,
      step: @step,
      trigger_kind: "initial",
      agent_provider: "codex",
      state: "running",
      started_at: 1.minute.ago,
      last_heartbeat_at: 1.minute.ago
    )
  end

  after do
    next unless @run

    @job.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "keeps a grader log stream and its primary result alive past the bounded lock wait" do
    lock_acquired = Queue.new
    release_lock = Queue.new
    errors = Queue.new
    locker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Run.transaction do
          Run.lock.find(@run.id)
          lock_acquired << true
          release_lock.pop
        end
      end
    rescue StandardError => e
      errors << e
    end
    lock_acquired.pop

    handler = Class.new(Steps::Base) { def call; end }.new(@run)
    expect { handler.send(:log, "grader output under contention", kind: "grade_log") }.not_to raise_error
    expect(@run.job_logs.where(chunk: "grader output under contention").count).to eq(1)

    release_lock << true
    locker.join
    raise errors.pop unless errors.empty?

    @run.reload
    @run.succeed!
    @run.save!
    expect(@run.reload).to be_succeeded
  ensure
    release_lock << true if locker&.alive?
    locker&.join
  end
end
