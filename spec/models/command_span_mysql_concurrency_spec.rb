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
    keys = Array.new(4) { |index| "grader:#{index}" }
    ActiveRecord::Base.connection_handler.clear_all_connections!

    children = keys.map do |key|
      ready_reader, ready_writer = IO.pipe
      start_reader, start_writer = IO.pipe
      result_reader, result_writer = IO.pipe
      pid = fork do
        ready_reader.close
        start_writer.close
        result_reader.close

        begin
          ActiveRecord::Base.connection_handler.clear_all_connections!
          ready_writer.write("1")
          ready_writer.close
          start_reader.read(1)

          ActiveRecord::Base.connection_pool.with_connection do
            child_run = Run.find(@run.id)
            child_job = Job.find(@job.id)
            child_workflow = Workflow.find(@workflow.id)
            child_step = Step.find(@step.id)

            2.times do
              CommandSpan.record!(
                run: child_run,
                idempotency_key: key,
                job: child_job,
                workflow: child_workflow,
                step: child_step,
                name: key,
                command_excerpt: "printf ready",
                started_at: Time.current,
                metadata: {}
              )
            end
          end
          result_writer.write("ok")
        rescue StandardError => error
          result_writer.write("#{error.class}: #{error.message}")
        ensure
          result_writer.close
          start_reader.close
        end
        exit! 0
      end

      ready_writer.close
      start_reader.close
      result_writer.close
      { pid: pid, ready: ready_reader, start: start_writer, result: result_reader }
    end

    children.each { |child| expect(child.fetch(:ready).read(1)).to eq("1") }
    children.each { |child| child.fetch(:start).write("1"); child.fetch(:start).close }
    results = children.map { |child| child.fetch(:result).read }
    children.each { |child| Process.wait(child.fetch(:pid)) }
    expect(results).to all(eq("ok"))

    spans = @run.command_spans.order(:sequence)
    expect(spans.pluck(:sequence)).to eq((1..keys.size).to_a)
    expect(spans.pluck(:idempotency_key)).to match_array(keys)
  end
end
