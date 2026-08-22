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
      example.run
    end
  ensure
    ENV["SYRUS_DATA_ROOT"] = old_data_root
  end

  before do
    # Computed here, not in the `around` block above: `workflow` memoizes
    # `Factories.job`, which validates User#agent_provider against
    # Syrus::PluginRegistry-registered providers. The registry is reset at
    # boot in test env and only repopulated by spec/support/bundled_plugins.rb's
    # global `before` hook, which — like every other `before` hook — only runs
    # once `around` calls `example.run`. Resolving `workflow` before that call
    # (i.e. still inside `around`) raced ahead of that repopulation and made
    # every example in this file fail with "Agent provider is not included in
    # the list" whenever the registry hadn't already been populated by an
    # earlier example in the same process.
    @ws_path = WorkflowWorkspace.path_for(workflow)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "writes grader output to the workspace file and durable JobLog rows" do
    handler.call

    details = step.reload.details
    expect(@ws_path.join(details["log_path"]).read).to include("durable output")
    expect(run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join).to include("durable output")
  end

  describe "sccache stats capture" do
    it "records a workflow artifact entry named after the grader when sccache reports stats" do
      allow(SccacheStatsCapture).to receive(:capture).and_return({ "compile_requests" => 5 })

      handler.call

      entries = workflow.reload.artifact("sccache_stats")
      expect(entries.size).to eq(1)
      expect(entries.first).to include("step_kind" => "grader", "label" => "tests", "stats" => { "compile_requests" => 5 })
    end

    it "does not record an artifact when sccache isn't installed" do
      allow(SccacheStatsCapture).to receive(:capture).and_return(nil)

      handler.call

      expect(workflow.reload.artifact("sccache_stats")).to be_nil
    end
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
    span = run.reload.command_spans.first
    expect(span.outcome).to eq("timed_out")
    expect(span.exit_status).to eq(Steps::Grader::TIMEOUT_EXIT_CODE)
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

  it "records spans for successful composite grader phases without writing markers to grade logs" do
    step.update!(details: step.details.merge("command" => "printf check && printf install && printf spec"))

    handler.call

    spans = run.reload.command_spans.ordered
    expect(spans.map(&:outcome)).to eq(%w[ succeeded succeeded succeeded ])
    expect(spans.map(&:sequence)).to eq([ 1, 2, 3 ])
    expect(spans.map(&:command_excerpt)).to eq([ "printf check", "printf install", "printf spec" ])
    expect(spans.map(&:spawned_process_id)).to all(be_present)
    expect(SpawnedProcess.find(spans.first.spawned_process_id).command).to eq("printf check && printf install && printf spec")
    expect(@ws_path.join(step.reload.details["log_path"]).read).to eq("checkinstallspec")
  end

  it "records the failing composite phase and preserves shell failure semantics" do
    step.update!(details: step.details.merge("command" => "printf ok && ruby -e 'exit 7' && printf skipped"))

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /grader tests failed/)

    spans = run.reload.command_spans.ordered
    expect(spans.map(&:outcome)).to eq(%w[ succeeded failed ])
    expect(spans.last.exit_status).to eq(7)
    expect(spans.map(&:command_excerpt)).not_to include("printf skipped")
  end

  it "calls registered grader augmentors when the grader fails" do
    step.update!(details: step.details.merge("command" => "ruby -e 'exit 1'"))

    augmentor = double("augmentor")
    allow(augmentor).to receive(:augment_grader_failure)
      .with(name: "tests", command: "ruby -e 'exit 1'", workspace_path: @ws_path)
      .and_return(["[rspec failures from JSON output]\n", "MyTest fails\n"])

    allow(SccacheStatsCapture).to receive(:capture).and_return(nil)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_augmentor).and_return([augmentor])
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_result_parser).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:prepare_detector).and_call_original

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    logged = run.reload.job_logs.where(kind: "grade_log").order(:sequence).pluck(:chunk).join
    expect(logged).to include("[rspec failures from JSON output]")
    expect(logged).to include("MyTest fails")
  end

  it "does not call augmentors when the grader passes" do
    augmentor = double("augmentor")
    expect(augmentor).not_to receive(:augment_grader_failure)

    allow(SccacheStatsCapture).to receive(:capture).and_return(nil)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_augmentor).and_return([augmentor])
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_result_parser).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:prepare_detector).and_call_original

    handler.call
  end

  it "records preflight grader spans through the shared grader implementation" do
    preflight_step = Step.create!(
      workflow: workflow,
      kind: "preflight_grader",
      position: 100,
      details: step.details.merge("command" => "printf preflight && printf done")
    )
    preflight_run = preflight_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: preflight_step.iteration)
    preflight_handler = Steps::PreflightGrader.new(preflight_run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(preflight_handler).to receive(:workspace).and_return(fake_ws)

    preflight_handler.call

    expect(preflight_run.reload.command_spans.ordered.map(&:command_excerpt)).to eq([ "printf preflight", "printf done" ])
    expect(@ws_path.join(preflight_step.reload.details["log_path"]).to_s).to include("/preflight/tests.log")
  end

  describe "grader side-effect detection" do
    before do
      FileUtils.mkdir_p(@ws_path)
      git_opts = { chdir: @ws_path.to_s, exception: true }
      system("git", "init", "--quiet", **git_opts)
      system("git", "config", "user.email", "test@example.com", **git_opts)
      system("git", "config", "user.name", "Test", **git_opts)
      File.write(@ws_path.join("README.md"), "hello\n")
      system("git", "add", ".", **git_opts)
      system("git", "commit", "--quiet", "-m", "init", **git_opts)
    end

    it "records a grader_side_effect warning when the command leaves uncommitted changes, without affecting grader pass/fail" do
      step.update!(details: step.details.merge("command" => "touch dirty.txt"))

      expect { handler.call }.not_to raise_error

      warning = WorkflowWarning.last
      expect(warning.kind).to eq("grader_side_effect")
      expect(warning.workflow).to eq(workflow)
      expect(warning.step).to eq(step)
      expect(warning.severity).to eq("medium")
      expect(warning.evidence["grader_name"]).to eq("tests")
      expect(warning.evidence["command"]).to eq("touch dirty.txt")
      expect(warning.evidence["changed_files"]).to include("dirty.txt")
      expect(warning.suggested_prompt).to include("tests")
      expect(warning.suggested_prompt).to include("dirty.txt")
      expect(warning.suggested_prompt).to include("formatters:")
    end

    it "records the warning even when the grader command itself fails" do
      step.update!(details: step.details.merge("command" => "touch dirty.txt && ruby -e 'exit 1'"))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed)

      expect(WorkflowWarning.where(kind: "grader_side_effect").count).to eq(1)
    end

    it "does not record a warning when the grader leaves the workspace clean" do
      expect { handler.call }.not_to change(WorkflowWarning, :count)
    end
  end
end
