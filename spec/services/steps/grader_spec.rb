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

  context "when the grader command is an rspec invocation" do
    let(:rspec_step) do
      Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 100,
        details: {
          "name" => "rspec",
          "command" => "bin/rspec spec/models/",
          "required" => true,
          "timeout_minutes" => 1
        }
      )
    end
    let(:rspec_run) { rspec_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: rspec_step.iteration) }
    let(:rspec_handler) { described_class.new(rspec_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
      allow(rspec_handler).to receive(:workspace).and_return(fake_ws)
    end

    let(:passing_result) do
      ProcessRunner::Result.new(
        exit_status: 0, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
      )
    end

    let(:failing_result) do
      ProcessRunner::Result.new(
        exit_status: 1, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.5, spawned_process_id: nil
      )
    end

    it "appends --format json and --out flags to the command" do
      captured_command = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_command = kwargs[:command]
        instance_double(ProcessRunner, run: passing_result)
      end

      rspec_handler.call

      expect(captured_command.last).to include("bin/rspec spec/models/")
      expect(captured_command.last).to include("--format json")
      expect(captured_command.last).to match(/--out .+\.json/)
    end

    it "does not double-append flags when command already includes --format json" do
      step_already_formatted = Step.create!(
        workflow: workflow,
        kind: "grader",
        position: 101,
        details: {
          "name" => "rspec-preformatted",
          "command" => "bin/rspec --format json --out /tmp/existing.json",
          "required" => true,
          "timeout_minutes" => 1
        }
      )
      run_already_formatted = step_already_formatted.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind,
        state: "running", iteration: step_already_formatted.iteration
      )
      handler_already_formatted = described_class.new(run_already_formatted)
      fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
      allow(handler_already_formatted).to receive(:workspace).and_return(fake_ws)

      captured_command = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_command = kwargs[:command]
        instance_double(ProcessRunner, run: passing_result)
      end

      handler_already_formatted.call

      expect(captured_command.last.scan("--format json").length).to eq(1)
    end

    it "logs structured failure details from the JSON file when rspec fails" do
      captured_json_path = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_json_path = kwargs[:command].last.match(/--out (\S+)/)&.[](1)
        File.write(captured_json_path, JSON.generate(
          "examples" => [
            {
              "full_description" => "Widget#process raises on invalid input",
              "status" => "failed",
              "exception" => { "message" => "expected RuntimeError but nothing was raised" },
              "location" => "./spec/models/widget_spec.rb:17"
            },
            {
              "full_description" => "Widget#process succeeds normally",
              "status" => "passed"
            }
          ]
        ))
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed)

      log_chunks = rspec_run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
      expect(log_chunks).to include("[rspec failures from JSON output]")
      expect(log_chunks).to include("Widget#process raises on invalid input")
      expect(log_chunks).to include("expected RuntimeError but nothing was raised")
      expect(log_chunks).to include("./spec/models/widget_spec.rb:17")
      expect(log_chunks).not_to include("Widget#process succeeds normally")
    ensure
      File.delete(captured_json_path) if captured_json_path && File.exist?(captured_json_path)
    end

    it "preserves RSpec JSON failure details across workspace, JobLog, and stored fallback output" do
      captured_json_path = nil
      long_stdout = ("setup and migration output\n" * 2_000)
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        kwargs[:on_output_chunk]&.call(long_stdout)
        captured_json_path = kwargs[:command].last.match(/--out (\S+)/)&.[](1)
        File.write(captured_json_path, JSON.generate(
          "examples" => [
            {
              "full_description" => "Current user scopes docs lists new Current.user file",
              "status" => "failed",
              "exception" => { "message" => "expected docs to mention app/models/current.rb" },
              "location" => "./spec/docs/current_user_scopes_spec.rb:12"
            },
            {
              "full_description" => "Bootstrap includes admin_supervisor_chat feature flag",
              "status" => "failed",
              "exception" => { "message" => "expected feature flag admin_supervisor_chat to be present" },
              "location" => "./spec/requests/api/v1/app/bootstrap_spec.rb:87"
            }
          ]
        ))
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed)

      details = rspec_step.reload.details
      workspace_log = @ws_path.join(details["log_path"]).read
      job_log = rspec_run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
      stored_output = details.fetch("output")

      # Regression for JOB-2291: these were the two actionable failures,
      # but repair inspected the workspace log path and saw only setup output.
      expected_fragments = [
        "[rspec failures from JSON output]",
        "Current user scopes docs lists new Current.user file",
        "expected docs to mention app/models/current.rb",
        "./spec/docs/current_user_scopes_spec.rb:12",
        "Bootstrap includes admin_supervisor_chat feature flag",
        "expected feature flag admin_supervisor_chat to be present",
        "./spec/requests/api/v1/app/bootstrap_spec.rb:87",
        "[grader:rspec] failed (exit 1)"
      ]

      expected_fragments.each do |fragment|
        expect(workspace_log).to include(fragment)
        expect(job_log).to include(fragment)
        expect(stored_output).to include(fragment)
      end

      expect(WorkflowWorkspace.grade_log_for(rspec_run, "rspec")).to include("[rspec failures from JSON output]")

      FileUtils.rm_rf(@ws_path)
      rspec_run.job_logs.where(kind: "grade_log").delete_all
      rspec_run.update!(state: "failed")
      fallback_log = WorkflowWorkspace.grade_log_for(rspec_run, "rspec")
      expect(fallback_log).to eq(stored_output)
      expected_fragments.each { |fragment| expect(fallback_log).to include(fragment) }
    ensure
      File.delete(captured_json_path) if captured_json_path && File.exist?(captured_json_path)
    end

    it "cleans up the JSON file after reading failures" do
      captured_json_path = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_json_path = kwargs[:command].last.match(/--out (\S+)/)&.[](1)
        File.write(captured_json_path, '{"examples":[]}')
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed)

      expect(File.exist?(captured_json_path)).to be false
    ensure
      File.delete(captured_json_path) if captured_json_path && File.exist?(captured_json_path)
    end

    it "handles a corrupt or partially-written JSON file without raising" do
      captured_json_path = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_json_path = kwargs[:command].last.match(/--out (\S+)/)&.[](1)
        File.write(captured_json_path, '{"examples": [{"status":')
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed, /grader rspec failed/)
    ensure
      File.delete(captured_json_path) if captured_json_path && File.exist?(captured_json_path)
    end

    it "does not log rspec JSON details when there are no failures in the JSON" do
      captured_json_path = nil
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        captured_json_path = kwargs[:command].last.match(/--out (\S+)/)&.[](1)
        File.write(captured_json_path, '{"examples":[]}')
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed)

      log_chunks = rspec_run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
      expect(log_chunks).not_to include("[rspec failures from JSON output]")
    ensure
      File.delete(captured_json_path) if captured_json_path && File.exist?(captured_json_path)
    end

    it "skips JSON reading when no JSON file exists (e.g. process killed before writing)" do
      allow(ProcessRunner).to receive(:new) do |**kwargs|
        # JSON file is never created — simulate process killed before writing
        instance_double(ProcessRunner, run: failing_result)
      end

      expect { rspec_handler.call }.to raise_error(Steps::Base::StepFailed)

      log_chunks = rspec_run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
      expect(log_chunks).not_to include("[rspec failures from JSON output]")
    end
  end

  it "does not apply rspec JSON augmentation to non-rspec commands" do
    captured_command = nil
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured_command = kwargs[:command]
      instance_double(ProcessRunner, run: ProcessRunner::Result.new(
        exit_status: 0, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
      ))
    end

    handler.call  # default step uses "ruby -e 'puts \"durable output\"'"

    expect(captured_command.last).not_to include("--format json")
  end
end
