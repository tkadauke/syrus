require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Format do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "format") } }
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
    Dir.mktmpdir("syrus-format") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:changed_files).and_return(%w[app/models/thing.rb])
  end

  after { Syrus::PluginRegistry.reset! }

  def write_syrus_yml(contents)
    @ws_path.join(".syrus.yml").write(contents)
  end

  def register_autofix_provider(command)
    provider = Class.new { include Syrus::Plugin::AutofixCommand }
    provider.define_singleton_method(:autofix_command) { |workspace_path:| command }
    Syrus::PluginRegistry.register(:autofix_command, provider)
    provider
  end

  describe "no changed files" do
    it "skips without consulting .syrus.yml or plugin providers" do
      allow(handler).to receive(:changed_files).and_return([])
      register_autofix_provider("echo fixed")
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("no changed files this iteration")
    end
  end

  describe "no .syrus.yml formatters: key (fallback to plugin defaults)" do
    it "no-ops cleanly when no autofix commands are registered" do
      expect(handler).not_to receive(:commit_agent_changes)

      expect { handler.call }.not_to raise_error

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("no applicable formatters")
    end

    it "runs every registered plugin command and commits the result" do
      register_autofix_provider("echo fixed")
      expect(handler).to receive(:commit_agent_changes).with("Format: apply deterministic formatting")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("(1/1) $ echo fixed")
      expect(chunks).to include("fixed")
    end

    it "runs commands from multiple plugins" do
      register_autofix_provider("echo first")
      register_autofix_provider("echo second")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("(1/2) $ echo first")
      expect(chunks).to include("(2/2) $ echo second")
    end

    it "soft-fails a failing command instead of raising, and still commits" do
      register_autofix_provider("some-fixer")
      fake_runner = instance_double(ProcessRunner, run: failure_result)
      allow(ProcessRunner).to receive(:new).and_return(fake_runner)
      expect(handler).to receive(:commit_agent_changes)

      expect { handler.call }.not_to raise_error

      failures = workflow.reload.artifact("format_failures")
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
      expect(step.reload.details["format_failures"]).to eq(failures)

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("WARNING (non-fatal): command failed (exit 1): some-fixer")
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

  describe "explicit .syrus.yml formatters:" do
    it "runs only formatters whose files glob matches the diff, skipping the rest" do
      write_syrus_yml(<<~YAML)
        formatters:
          - command: echo ruby-fixed
            files: "**/*.rb"
          - command: echo ts-fixed
            files: "**/*.ts"
      YAML
      register_autofix_provider("echo plugin-default")
      expect(handler).to receive(:commit_agent_changes).with("Format: apply deterministic formatting")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("$ echo ruby-fixed")
      expect(chunks).not_to include("$ echo ts-fixed")
      expect(chunks).to include("skipped \"echo ts-fixed\" (no matching files changed)")
      expect(chunks).not_to include("plugin-default")
    end

    it "does not fall back to plugin providers even when every formatter is skipped" do
      write_syrus_yml(<<~YAML)
        formatters:
          - command: echo ts-fixed
            files: "**/*.ts"
      YAML
      register_autofix_provider("echo plugin-default")
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).not_to include("plugin-default")
      expect(chunks).to include("no applicable formatters")
    end
  end

  describe "formatters: false" do
    it "disables formatting entirely, including plugin defaults" do
      write_syrus_yml("formatters: false\n")
      register_autofix_provider("echo plugin-default")
      expect(handler).not_to receive(:commit_agent_changes)

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("formatters explicitly disabled")
      expect(chunks).not_to include("plugin-default")
    end

    it "also disables via the YAML off spelling" do
      write_syrus_yml("formatters: off\n")
      register_autofix_provider("echo plugin-default")

      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("formatters explicitly disabled")
    end
  end
end
