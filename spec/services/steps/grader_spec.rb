require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Grader do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 99,
      details: {
        "name" => "tests",
        "command" => "ruby -e 'puts \"durable output\"'",
        "required" => true,
        "timeout_minutes" => 1
      }
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }
  let(:handler) { described_class.new(run) }

  around do |example|
    Dir.mktmpdir("syrus-grader") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "writes grader output to the workspace file and durable JobLog rows" do
    handler.call

    details = step.reload.details
    expect(@ws_path.join(details["log_path"]).read).to include("durable output")
    expect(run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join).to include("durable output")
  end

  it "buffers grade_log entries to line boundaries so individual chunks don't each become a separate row" do
    fake_result = ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )

    allow(ProcessRunner).to receive(:new) do |**kwargs|
      # Simulate RSpec-style output: three dots without newlines, then a newline
      kwargs[:on_output_chunk]&.call(".")
      kwargs[:on_output_chunk]&.call(".")
      kwargs[:on_output_chunk]&.call(".")
      kwargs[:on_output_chunk]&.call("\n")
      instance_double(ProcessRunner, run: fake_result)
    end

    handler.call

    log_entries = run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk)
    expect(log_entries.length).to eq(1)
    expect(log_entries.first).to eq("...\n")
  end

  it "flushes a trailing partial line after the process exits" do
    fake_result = ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )

    allow(ProcessRunner).to receive(:new) do |**kwargs|
      # Simulate output that ends without a trailing newline
      kwargs[:on_output_chunk]&.call("no newline at end")
      instance_double(ProcessRunner, run: fake_result)
    end

    handler.call

    log_entries = run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk)
    expect(log_entries.map(&:strip).join).to include("no newline at end")
  end
end
