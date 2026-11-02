require "rails_helper"

RSpec.describe "Job definition update concurrency" do
  self.use_transactional_tests = false

  before do
    skip "SQLite does not implement row-level SELECT FOR UPDATE locking" unless mysql?

    @user = Factories.user
    @repository = Factories.repository(user: @user)
    @job = Factories.job_with_run(
      user: @user,
      repository: @repository,
      state: "queued",
      issue_title: "Original title",
      issue_body: "Original description"
    )
  end

  after do
    next unless mysql?

    @job&.destroy!
    @repository&.destroy!
    @user&.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "serializes a definition edit behind a concurrent execution start" do
    start_persisted = Queue.new
    release_start = Queue.new
    updater_entered = Queue.new
    results = Queue.new

    starter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Workflow.transaction do
          workflow = Workflow.find(@job.workflows.first.id)
          workflow.start!
          start_persisted << true
          release_start.pop
        end
      end
    rescue StandardError => e
      results << e
    end

    start_persisted.pop
    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        updater_entered << true
        JobDefinitionUpdater.new(Job.find(@job.id)).update!(title: "Late title")
      end
    rescue StandardError => e
      results << e
    end

    updater_entered.pop
    expect(updater.join(0.1)).to be_nil

    release_start << true
    starter.join
    updater.join

    errors = []
    errors << results.pop until results.empty?
    expect(errors).to contain_exactly(an_instance_of(JobDefinitionUpdater::Immutable))
    expect(@job.reload).to have_attributes(
      issue_title: "Original title",
      issue_body: "Original description",
      state: "running"
    )
  ensure
    release_start << true if starter&.alive?
    starter&.join
    updater&.join
  end

  def mysql?
    ActiveRecord::Base.connection.adapter_name == "Mysql2"
  end
end
