require "rails_helper"

RSpec.describe Mcp::Tools::StartPreviewTool do
  let(:run)            { Factories.job.initial_run }
  let(:workspace_path) { WorkflowWorkspace.path_for(run.step.workflow).to_s }
  let(:launcher)       { PreviewProcessLauncher.new(workspace_path) }

  let(:preview_config) do
    PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/rails server -p #{port}" },
      setup_commands:    [],
      seed_command:      nil,
      health_check_path: "/health",
      log_paths:         [ "log/development.log" ],
      env:               {},
      unset_env:         []
    )
  end

  def call(port: 3001)
    described_class.call(port: port, server_context: { run: run })
  end

  before do
    Mcp::Tools::AgentPreviewRegistry.reset!
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(double(resolve: preview_config))
    allow(PreviewProcessLauncher).to receive(:new).with(workspace_path).and_return(launcher)
  end

  after { Mcp::Tools::AgentPreviewRegistry.reset! }

  context "when health check passes immediately" do
    before do
      allow(Process).to receive(:spawn).and_return(12345)
      allow(launcher).to receive(:http_ok?).and_return(true)
    end

    it "returns the local URL and PID" do
      response = call
      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to eq("url" => "http://localhost:3001", "pid" => 12345)
    end

    it "registers the process in the registry" do
      call
      expect(Mcp::Tools::AgentPreviewRegistry.get(run.id)).to eq(pid: 12345, port: 3001)
    end

    it "writes a JobLog audit line" do
      expect { call }.to change { run.job_logs.count }.by(1)
      expect(run.job_logs.last.chunk).to include("[mcp] start_preview", "pid=12345", "port=3001")
    end

    it "accepts a custom port" do
      allow(Process).to receive(:spawn).and_return(9999)
      response = call(port: 4000)
      payload  = JSON.parse(response.content.first[:text])
      expect(payload).to eq("url" => "http://localhost:4000", "pid" => 9999)
    end

    it "builds the start command with the requested port" do
      expect(Process).to receive(:spawn).with(anything, "bin/rails server -p 3001", anything).and_return(12345)
      call
    end

    it "passes PORT env var and pgroup: true to spawn" do
      expect(Process).to receive(:spawn).with(
        hash_including(
          "PORT" => "3001",
          "BUNDLE_PATH" => File.join(workspace_path, ".syrus/deps/bundle"),
          "BUNDLE_APP_CONFIG" => File.join(workspace_path, ".syrus/deps/bundle-config")
        ),
        anything,
        hash_including(chdir: workspace_path, pgroup: true, unsetenv_others: true)
      ).and_return(12345)
      call
    end

    it "passes configured preview env to spawn" do
      preview_config = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        setup_commands:    [],
        seed_command: nil,
        health_check_path: "/health",
        log_paths: [],
        env: { "RAILS_ENV" => "development" },
        unset_env: [ "DATABASE_URL" ]
      )
      allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(double(resolve: preview_config))

      expect(Process).to receive(:spawn).with(
        hash_including("DATABASE_URL" => nil, "RAILS_ENV" => "development", "PORT" => "3001"),
        anything,
        hash_including(chdir: workspace_path, pgroup: true, unsetenv_others: true)
      ).and_return(12345)
      call
    end
  end

  context "when a preview is already running for this run" do
    before { Mcp::Tools::AgentPreviewRegistry.register(key: run.id, pid: 9999, port: 3001) }

    it "returns the existing URL and PID without spawning again" do
      expect(Process).not_to receive(:spawn)
      response = call
      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to eq("url" => "http://localhost:3001", "pid" => 9999)
    end

    it "does not write a JobLog audit line for a reused preview" do
      expect { call }.not_to change { run.job_logs.count }
    end
  end

  context "when no preview config is configured" do
    before { allow(PreviewCommandSource).to receive(:new).and_return(double(resolve: nil)) }

    it "returns an error" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("no preview command configured")
    end
  end

  context "when the run has no step" do
    before { run.update_columns(step_id: nil) }

    it "returns an error" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("no workflow workspace found")
    end
  end

  context "when the health check times out" do
    before do
      stub_const("PreviewProcessLauncher::HEALTH_CHECK_TIMEOUT_SECONDS", -1)
      allow(Process).to receive(:spawn).and_return(12345)
      allow(launcher).to receive(:http_ok?).and_return(false)
    end

    it "returns an error mentioning the timeout" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("timed out")
    end

    it "removes the process from the registry after timeout" do
      call
      expect(Mcp::Tools::AgentPreviewRegistry.get(run.id)).to be_nil
    end

    it "calls AgentPreviewRegistry.kill to stop the orphaned process" do
      expect(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      call
    end
  end

  context "when a seed command is configured" do
    let(:preview_config) do
      PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        setup_commands:    [],
        seed_command:      "bin/rails db:seed",
        health_check_path: "/",
        log_paths:         [],
        env:               {},
        unset_env:         []
      )
    end

    before do
      allow(Process).to receive(:spawn).and_return(1111)
      allow(launcher).to receive(:http_ok?).and_return(true)
    end

    it "runs the configured seed command" do
      expect(launcher).to receive(:system).with(
        hash_including("BUNDLE_PATH" => File.join(workspace_path, ".syrus/deps/bundle")),
        "bash", "-c", "bin/rails db:seed",
        chdir: workspace_path, exception: false, unsetenv_others: true
      ).and_return(true)
      call
    end

    it "passes configured preview env to the seed command" do
      preview_config = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        setup_commands:    [],
        seed_command: "bin/rails db:seed",
        health_check_path: "/",
        log_paths: [],
        env: { "RAILS_ENV" => "development" },
        unset_env: [ "DATABASE_URL" ]
      )
      allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(double(resolve: preview_config))

      expect(launcher).to receive(:system).with(
        hash_including("DATABASE_URL" => nil, "RAILS_ENV" => "development"),
        "bash", "-c", "bin/rails db:seed",
        chdir: workspace_path, exception: false, unsetenv_others: true
      ).and_return(true)
      call
    end

    it "returns an error when the seed step fails" do
      allow(launcher).to receive(:system).and_return(false)
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("preview seed command exited non-zero")
    end
  end

  context "when setup commands are configured" do
    let(:preview_config) do
      PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        setup_commands:    [ "bundle install" ],
        seed_command:      nil,
        health_check_path: "/",
        log_paths:         [],
        env:               { "RAILS_ENV" => "development" },
        unset_env:         []
      )
    end

    before do
      allow(Process).to receive(:spawn).and_return(1111)
      allow(launcher).to receive(:http_ok?).and_return(true)
    end

    it "runs setup before spawning the preview process" do
      expect(launcher).to receive(:system).with(
        hash_including("RAILS_ENV" => "development", "BUNDLE_PATH" => File.join(workspace_path, ".syrus/deps/bundle")),
        "bash",
        "-c",
        "bundle install",
        chdir: workspace_path,
        exception: false,
        unsetenv_others: true
      ).and_return(true)

      call
    end

    it "returns an error when setup fails" do
      allow(launcher).to receive(:system).and_return(false)

      response = call

      expect(response).to be_error
      expect(response.content.first[:text]).to include("preview setup command exited non-zero")
      expect(Process).not_to have_received(:spawn)
    end
  end
end
