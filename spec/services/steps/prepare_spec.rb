require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Prepare do
  # Build a Run wired to a workflow + step so the handler's
  # `workspace`, `log`, `repository`, `job` accessors all work.
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "prepare") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-prepare") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    # Stub the workspace so we don't actually clone anything; the
    # handler's `workspace.path` returns our tmpdir.
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "no-ops cleanly when there are no commands to run" do
    # Empty workspace → auto-detect finds nothing → empty plan
    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no commands to run")
    expect(workflow.reload.artifact("prepare_failure")).to be_nil
    expect(step.reload.details["prepare_failure"]).to be_nil
  end

  it "runs each command from .syrus.yml in order" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - echo first
        - echo second
    YAML

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk)
    # Ordered: announcement of cmd1, output, announcement of cmd2, output
    cmd_announces = chunks.select { |c| c.include?("$ echo") }
    expect(cmd_announces.size).to eq(2)
    expect(cmd_announces.first).to include("(1/2) $ echo first")
    expect(cmd_announces.last).to include("(2/2) $ echo second")
    expect(chunks.join("\n")).to include("first")
    expect(chunks.join("\n")).to include("second")
    expect(chunks.last).to include("all commands completed successfully")
    expect(workflow.reload.artifact("prepare_failure")).to be_nil
    expect(step.reload.details["prepare_failure"]).to be_nil
  end

  it "auto-detects bundle install on a Gemfile-bearing repo" do
    File.write(@ws_path.join("Gemfile"), "")
    # Stub bash so we don't actually run bundle in the test sandbox
    allow(handler).to receive(:run_shell) do |cmd|
      run.job_logs.create!(sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
                           chunk: "[stub-ran] #{cmd}")
    end

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("source: auto-detect (Gemfile)")
    expect(chunks).to include("[stub-ran] bundle install")
  end

  it "runs commands with workspace-local dependency paths" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - bundle install
    YAML
    old_bundle_without = ENV["BUNDLE_WITHOUT"]
    ENV["BUNDLE_WITHOUT"] = "development:test"
    captured_env = nil
    fake_runner = instance_double(ProcessRunner)
    allow(fake_runner).to receive(:run).and_return(
      ProcessRunner::Result.new(
        exit_status: 0,
        timed_out: false,
        stopped: false,
        silent_timed_out: false,
        operator_killed: false,
        aliveness_failed: false,
        duration_s: 0.1,
        spawned_process_id: nil
      )
    )
    allow(ProcessRunner).to receive(:new) do |*_, **kwargs|
      captured_env = kwargs.fetch(:env)
      fake_runner
    end

    handler.call

    deps = @ws_path.join(".syrus", "deps")
    expect(captured_env).to include(
      "BUNDLE_PATH" => deps.join("bundle").to_s,
      "BUNDLE_APP_CONFIG" => deps.join("bundle-config").to_s,
      "BUNDLE_USER_HOME" => deps.join("bundle-home").to_s,
      "BUNDLE_USER_CACHE" => deps.join("bundle-cache").to_s,
      "NPM_CONFIG_CACHE" => deps.join("npm-cache").to_s,
      "YARN_CACHE_FOLDER" => deps.join("yarn-cache").to_s,
      "COREPACK_HOME" => deps.join("corepack").to_s
    )
    expect(captured_env).not_to have_key("BUNDLE_WITHOUT")
  ensure
    ENV["BUNDLE_WITHOUT"] = old_bundle_without
  end

  it "raises StepFailed when a prepare command exits non-zero" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - bash -c 'printf "alpha\\\\nbeta\\\\n"; exit 7'
    YAML
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /exit 7.*Output tail/m)

    failure = workflow.reload.artifact("prepare_failure")
    expect(failure).to include(
      "command" => "bash -c 'printf \"alpha\\\\nbeta\\\\n\"; exit 7'",
      "workdir" => @ws_path.to_s,
      "exit_status" => 7,
      "timed_out" => false,
      "output_tail" => include("alpha", "beta")
    )
    expect(step.reload.details["prepare_failure"]).to eq(failure)

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("[prepare] failure: prepare command failed (exit 7)")
    expect(chunks).to include("alpha")
    expect(chunks).to include("beta")
  end

  describe "#stream_buffered" do
    it "coalesces a 640 KB burst instead of flushing each byte-threshold chunk" do
      data = 40.times.map { |i| i.to_s.rjust(4, "0") + ("x" * (16 * 1024 - 4)) }.join

      stream(data)

      logs = run.job_logs.order(:sequence).pluck(:chunk)
      expect(logs.count).to be <= 2
      expect(logs.join).to eq(data)
    end

    it "forces flushes at LOG_FLUSH_MAX_BUF during sustained high-rate output" do
      data = 3.times.map { |i| i.to_s.rjust(4, "0") + ("x" * (Steps::Base::LOG_FLUSH_MAX_BUF - 4)) }.join

      stream(data)

      logs = run.job_logs.order(:sequence).pluck(:chunk)
      expect(logs.count).to eq(3)
      expect(logs.all? { |chunk| chunk.bytesize >= Steps::Base::LOG_FLUSH_MAX_BUF }).to be(true)
      expect(logs.join).to eq(data)
    end

    def stream(data)
      reader, writer = IO.pipe
      writer_thread = Thread.new do
        writer.write(data)
        writer.close
      end

      handler.send(:stream_buffered, reader)
      writer_thread.join
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end
end
