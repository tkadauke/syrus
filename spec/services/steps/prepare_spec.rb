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

    # RepoPrepPlan's Gemfile auto-detect signal now comes entirely from the
    # `ruby` plugin's :prepare_detector (no more RepoPrepPlan::AUTO_DETECT
    # fallback). Register the real bundled plugin, mirroring its engine.rb
    # manifest, so Gemfile-based specs below exercise production wiring.
    unless Syrus::PluginRegistry.registered_names.include?("ruby")
      Syrus::PluginRegistry.register(
        name: "ruby", version: Ruby::VERSION, prepare_priority: 10,
        provides: { prepare_detector: Ruby::PrepareDetector }
      )
    end
  end

  after { Syrus::PluginRegistry.reset! }

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
    allow(handler).to receive(:run_shell) do |cmd, **|
      run.job_logs.create!(sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
                           chunk: "[stub-ran] #{cmd}")
      true
    end

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("source: auto-detect (Ruby::PrepareDetector)")
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
    # Explicit commands are hard failures, never tagged soft.
    expect(workflow.reload.artifact("prepare_failure")).not_to include("soft")
  end

  it "soft-fails a guessed (auto-detected) command instead of aborting the chain" do
    # No .syrus.yml: the Gemfile drives auto-detect → `bundle install`,
    # which Syrus only guessed. A non-zero exit must NOT raise, so the
    # agent still gets to run (and can add a .syrus.yml or fix the repo).
    File.write(@ws_path.join("Gemfile"), "")
    fake_runner = instance_double(ProcessRunner)
    allow(fake_runner).to receive(:run).and_return(
      ProcessRunner::Result.new(
        exit_status: 7,
        timed_out: false,
        stopped: false,
        silent_timed_out: false,
        operator_killed: false,
        aliveness_failed: false,
        duration_s: 0.1,
        spawned_process_id: nil
      )
    )
    allow(ProcessRunner).to receive(:new).and_return(fake_runner)

    expect { handler.call }.not_to raise_error

    failure = workflow.reload.artifact("prepare_failure")
    expect(failure).to include(
      "command" => "bundle install",
      "exit_status" => 7,
      "soft" => true
    )
    expect(step.reload.details["prepare_failure"]).to eq(failure)

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("source: auto-detect (Ruby::PrepareDetector)")
    expect(chunks).to include("WARNING (guessed command, non-fatal)")
    expect(chunks).to include("handing off to the agent without it")
    # The success line must NOT print — setup did not complete.
    expect(chunks).not_to include("all commands completed successfully")
  end

  describe "plugin detection" do
    it "records the detected plugin set as a workflow artifact readable by a later step" do
      File.write(@ws_path.join("Gemfile"), "")
      allow(handler).to receive(:run_shell).and_return(true)

      handler.call

      expect(workflow.reload.artifact("detected_plugins")).to eq([ "ruby" ])
      # Any later Step in the same Run reads through the same Workflow
      # record and reader helper — no re-derivation needed.
      later_step_workflow = Workflow.find(workflow.id)
      expect(later_step_workflow.detected_plugins).to eq([ "ruby" ])

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("[prepare] detected: ruby")
    end

    it "records an empty set and a 'none' log line when nothing matches" do
      handler.call

      expect(workflow.reload.artifact("detected_plugins")).to eq([])
      expect(workflow.reload.detected_plugins).to eq([])

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).to include("[prepare] detected: none")
    end
  end

  describe "mise install" do
    let(:success_result) do
      ProcessRunner::Result.new(
        exit_status: 0, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.5, spawned_process_id: nil
      )
    end

    let(:failure_result) do
      ProcessRunner::Result.new(
        exit_status: 1, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.5, spawned_process_id: nil
      )
    end

    it "skips mise install when no version files are present" do
      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).not_to include("mise install")
      expect(workflow.reload.artifact("mise_install_failure")).to be_nil
    end

    def expect_mise_install_ran
      fake_runner = instance_double(ProcessRunner, run: success_result)
      allow(ProcessRunner).to receive(:new).and_return(fake_runner)

      handler.call

      expect(ProcessRunner).to have_received(:new).with(
        hash_including(command: [ "mise", "install" ], timeout: Steps::Prepare::MISE_INSTALL_TIMEOUT)
      )
      expect(workflow.reload.artifact("mise_install_failure")).to be_nil
    end

    Steps::Prepare::UNIVERSAL_MISE_VERSION_FILES.each do |version_file|
      it "detects the universal #{version_file} and runs mise install" do
        File.write(@ws_path.join(version_file), "ruby 3.4.0\n")
        expect_mise_install_ran
      end
    end

    it "detects a universal version file with zero :prepare_detector plugins registered" do
      Syrus::PluginRegistry.reset!
      File.write(@ws_path.join(".tool-versions"), "ruby 3.4.0\n")
      expect_mise_install_ran
    end

    context "with every bundled language plugin registered" do
      before do
        unless Syrus::PluginRegistry.registered_names.include?("javascript")
          Syrus::PluginRegistry.register(
            name: "javascript", version: JavaScript::VERSION, prepare_priority: 20,
            provides: { prepare_detector: JavaScript::PrepareDetector }
          )
        end

        unless Syrus::PluginRegistry.registered_names.include?("python")
          Syrus::PluginRegistry.register(
            name: "python", version: Python::VERSION, prepare_priority: 30,
            provides: { prepare_detector: Python::PrepareDetector }
          )
        end

        unless Syrus::PluginRegistry.registered_names.include?("go")
          Syrus::PluginRegistry.register(
            name: "go", version: Go::VERSION, prepare_priority: 40,
            provides: { prepare_detector: Go::PrepareDetector }
          )
        end
      end

      {
        ".ruby-version"   => "ruby",
        ".node-version"   => "javascript",
        ".python-version" => "python",
        ".go-version"     => "go"
      }.each do |version_file, plugin_name|
        it "detects #{version_file} declared by the #{plugin_name} plugin and runs mise install" do
          File.write(@ws_path.join(version_file), "3.4.0\n")
          expect_mise_install_ran
        end

        it "does not run mise install for #{version_file} when the #{plugin_name} plugin is disabled" do
          File.write(@ws_path.join(version_file), "3.4.0\n")
          PluginRecord.find_by!(name: plugin_name).update!(enabled: false)

          handler.call

          chunks = run.reload.job_logs.pluck(:chunk).join("\n")
          expect(chunks).not_to include("mise install")
        end
      end
    end

    context "when a version file is present" do
      before { File.write(@ws_path.join(".tool-versions"), "ruby 3.4.0\n") }

      it "runs mise install in the workspace directory with the scrubbed env" do
        captured_kwargs = nil
        fake_runner = instance_double(ProcessRunner, run: success_result)
        allow(ProcessRunner).to receive(:new) do |**kwargs|
          captured_kwargs = kwargs if kwargs[:command] == [ "mise", "install" ]
          fake_runner
        end

        handler.call

        expect(captured_kwargs).to include(
          command: [ "mise", "install" ],
          chdir: @ws_path,
          timeout: Steps::Prepare::MISE_INSTALL_TIMEOUT
        )
        expect(captured_kwargs[:env]).not_to have_key("BUNDLE_WITHOUT")
        expect(captured_kwargs[:env]).not_to have_key("RAILS_ENV")
      end

      it "soft-fails when mise install exits non-zero, records artifact, and continues" do
        fake_runner = instance_double(ProcessRunner, run: failure_result)
        allow(ProcessRunner).to receive(:new).and_return(fake_runner)

        expect { handler.call }.not_to raise_error

        failure = workflow.reload.artifact("mise_install_failure")
        expect(failure).to include(
          "command" => "mise install",
          "exit_status" => 1,
          "soft" => true
        )
        expect(step.reload.details["mise_install_failure"]).to eq(failure)

        chunks = run.reload.job_logs.pluck(:chunk).join("\n")
        expect(chunks).to include("[prepare] WARNING (mise install, non-fatal)")
      end

      it "soft-fails when mise install times out, records artifact, and continues" do
        timed_out_result = ProcessRunner::Result.new(
          exit_status: nil, timed_out: true, stopped: false,
          silent_timed_out: false, operator_killed: false,
          aliveness_failed: false, duration_s: Steps::Prepare::MISE_INSTALL_TIMEOUT.to_f,
          spawned_process_id: nil
        )
        fake_runner = instance_double(ProcessRunner, run: timed_out_result)
        allow(ProcessRunner).to receive(:new).and_return(fake_runner)

        expect { handler.call }.not_to raise_error

        failure = workflow.reload.artifact("mise_install_failure")
        expect(failure).to include("soft" => true, "timed_out" => true)

        chunks = run.reload.job_logs.pluck(:chunk).join("\n")
        expect(chunks).to include("[prepare] WARNING (mise install, non-fatal)")
        expect(chunks).to include("timed out after")
      end
    end
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

      freeze_time do
        stream(data)
      end

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
