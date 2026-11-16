require "rails_helper"

RSpec.describe "CommandSpan MySQL sequence allocation", :ci_only do
  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name == "Mysql2"

    @job = Factories.job_record
    @workflow = Workflow.create!(job: @job, trigger_kind: "initial", state: "running")
    @step = Step.create!(workflow: @workflow, kind: "grader", position: 0, state: "running")
    @run = Run.create!(job: @job, step: @step, trigger_kind: "initial", state: "running")
  end

  after do
    @job&.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "persists every concurrent event once with a unique sequence" do
    errors = Queue.new
    ready = Queue.new
    start = Queue.new
    keys = Array.new(8) { |index| "grader:#{index}" }

    threads = keys.map do |key|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          2.times do
            CommandSpan.record!(
              run: @run,
              idempotency_key: key,
              job: @job,
              workflow: @workflow,
              step: @step,
              name: key,
              command_excerpt: "printf ready",
              started_at: Time.current,
              metadata: {}
            )
          end
        rescue StandardError => error
          errors << error
        end
      end
    end

    keys.size.times { ready.pop }
    keys.size.times { start << true }
    threads.each(&:join)
    raise errors.pop unless errors.empty?

    spans = @run.command_spans.order(:sequence)
    expect(spans.pluck(:sequence)).to eq((1..keys.size).to_a)
    expect(spans.pluck(:idempotency_key)).to match_array(keys)
  end
end
