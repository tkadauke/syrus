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
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir("syrus-grader") do |dir|
      ENV["SYRUS_DATA_ROOT"] = dir
      @ws_path = WorkflowWorkspace.path_for(workflow)
      example.run
    end
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
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

  it "streams grader output through the shared buffered log sink" do
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
    expect(log_entries.first).to eq("...")
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

  it "records timed-out grader runs explicitly" do
    fake_result = ProcessRunner::Result.new(
      exit_status: nil, timed_out: true, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 60.0, spawned_process_id: nil
    )

    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:on_output_chunk]&.call("still running")
      instance_double(ProcessRunner, run: fake_result)
    end

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /grader tests failed/)

    details = step.reload.details
    expect(details["timed_out"]).to be true
    expect(details["exit_code"]).to eq(Steps::Grader::TIMEOUT_EXIT_CODE)
    expect(@ws_path.join(details["log_path"]).read).to include("[timed out after 1 minutes]")
  end

  it "fails grader runs when ProcessRunner reports a non-exit failure" do
    fake_result = ProcessRunner::Result.new(
      exit_status: nil, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: true, duration_s: 0.1, spawned_process_id: nil
    )

    allow(ProcessRunner).to receive(:new) do |**kwargs|
      kwargs[:on_output_chunk]&.call("parent process disappeared")
      instance_double(ProcessRunner, run: fake_result)
    end

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /grader tests failed/)

    details = step.reload.details
    expect(details["exit_code"]).to be_nil
    expect(@ws_path.join(details["log_path"]).read).to include("[grader:tests] failed")
  end

  it "runs the configured command without formatter-specific mutation" do
    step.update!(details: step.details.merge("command" => "bin/rspec spec/models --format json --out custom.json"))
    captured_command = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured_command = kwargs[:command]
      instance_double(ProcessRunner, run: ProcessRunner::Result.new(
        exit_status: 0, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
      ))
    end

    handler.call

    expect(captured_command).to eq([ "bash", "-c", "bin/rspec spec/models --format json --out custom.json" ])
  end
end
