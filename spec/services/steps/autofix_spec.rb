require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Autofix do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "autofix") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  let(:success_result) do
    ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  let(:failure_result) do
    ProcessRunner::Result.new(
      exit_status: 1, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  around do |ex|
    Dir.mktmpdir("syrus-autofix") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:commit_agent_changes)
  end

  after { Syrus::PluginRegistry.reset! }

  def register_autofix_provider(command)
    provider = Class.new { include Syrus::Plugin::AutofixCommand }
    provider.define_singleton_method(:autofix_command) { |workspace_path:| command }
    Syrus::PluginRegistry.register(:autofix_command, provider)
    provider
  end

  it "no-ops cleanly and does not commit when no autofix commands are registered" do
    expect(handler).not_to receive(:commit_agent_changes)

    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no autofix commands registered")
  end

  it "runs a registered autofix command and commits the result" do
    register_autofix_provider("echo fixed")
    expect(handler).to receive(:commit_agent_changes).with("Autofix: apply deterministic formatting")

    allow(ProcessRunner).to receive(:new).and_call_original

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("(1/1) $ echo fixed")
    expect(chunks).to include("fixed")
    expect(workflow.reload.artifact("autofix_failures")).to be_nil
  end

  it "runs every registered command from multiple plugins" do
    register_autofix_provider("echo first")
    register_autofix_provider("echo second")

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("(1/2) $ echo first")
    expect(chunks).to include("(2/2) $ echo second")
    expect(chunks).to include("first")
    expect(chunks).to include("second")
  end

  it "skips providers that return nil without running a command" do
    provider = Class.new { include Syrus::Plugin::AutofixCommand }
    provider.define_singleton_method(:autofix_command) { |workspace_path:| nil }
    Syrus::PluginRegistry.register(:autofix_command, provider)
    expect(handler).not_to receive(:commit_agent_changes)

    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no autofix commands registered")
  end

  it "soft-fails a failing autofix command instead of raising, and still commits" do
    register_autofix_provider("some-fixer")
    fake_runner = instance_double(ProcessRunner)
    allow(fake_runner).to receive(:run).and_return(failure_result)
    allow(ProcessRunner).to receive(:new).and_return(fake_runner)
    expect(handler).to receive(:commit_agent_changes)

    expect { handler.call }.not_to raise_error

    failures = workflow.reload.artifact("autofix_failures")
    expect(failures).to eq(
      [
        {
          "command"     => "some-fixer",
          "workdir"     => @ws_path.to_s,
          "exit_status" => 1,
          "timed_out"   => false,
          "duration_s"  => 0.1,
          "output_tail" => "",
          "soft"        => true
        }
      ]
    )
    expect(step.reload.details["autofix_failures"]).to eq(failures)

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("WARNING (non-fatal): command failed (exit 1): some-fixer")
  end

  it "continues running subsequent commands after one fails" do
    register_autofix_provider("bad-fixer")
    register_autofix_provider("echo good")
    call_count = 0
    allow(ProcessRunner).to receive(:new).and_wrap_original do |original_new, **kwargs|
      call_count += 1
      if kwargs[:command] == [ "bash", "-c", "bad-fixer" ]
        instance_double(ProcessRunner, run: failure_result)
      else
        # Let the "echo good" command run for real so we can assert its output.
        original_new.call(**kwargs)
      end
    end

    handler.call

    expect(call_count).to eq(2)
    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("(2/2) $ echo good")
    expect(chunks).to include("good")
    failures = workflow.reload.artifact("autofix_failures")
    expect(failures.size).to eq(1)
    expect(failures.first["command"]).to eq("bad-fixer")
  end

  it "runs commands with workspace-local dependency env, mirroring Prepare" do
    register_autofix_provider("bundle exec rubocop -a")
    captured_env = nil
    fake_runner = instance_double(ProcessRunner, run: success_result)
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured_env = kwargs.fetch(:env)
      fake_runner
    end

    handler.call

    deps = @ws_path.join(".syrus", "deps")
    expect(captured_env).to include(
      "BUNDLE_PATH"       => deps.join("bundle").to_s,
      "BUNDLE_APP_CONFIG" => deps.join("bundle-config").to_s
    )
  end
end
