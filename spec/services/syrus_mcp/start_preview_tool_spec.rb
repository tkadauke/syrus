require "rails_helper"

RSpec.describe SyrusMcp::StartPreviewTool do
  let(:run)            { Factories.job.initial_run }
  let(:workspace_path) { WorkflowWorkspace.path_for(run.step.workflow).to_s }

  let(:preview_config) do
    PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/rails server -p #{port}" },
      seed_command:      nil,
      health_check_path: "/health",
      log_paths:         [ "log/development.log" ]
    )
  end

  def call(port: 3001)
    described_class.call(port: port, server_context: { run: run })
  end

  before do
    SyrusMcp::AgentPreviewRegistry.reset!
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(double(resolve: preview_config))
  end

  after { SyrusMcp::AgentPreviewRegistry.reset! }

  context "when health check passes immediately" do
    before do
      allow(Process).to receive(:spawn).and_return(12345)
      allow(described_class).to receive(:http_ok?).and_return(true)
    end

    it "returns the local URL and PID" do
      response = call
      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to eq("url" => "http://localhost:3001", "pid" => 12345)
    end

    it "registers the process in the registry" do
      call
      expect(SyrusMcp::AgentPreviewRegistry.get(run.id)).to eq(pid: 12345, port: 3001)
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
        { "PORT" => "3001" },
        anything,
        hash_including(chdir: workspace_path, pgroup: true)
      ).and_return(12345)
      call
    end
  end

  context "when a preview is already running for this run" do
    before { SyrusMcp::AgentPreviewRegistry.register(run_id: run.id, pid: 9999, port: 3001) }

    it "returns the existing URL and PID without spawning again" do
      expect(Process).not_to receive(:spawn)
      response = call
      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to eq("url" => "http://localhost:3001", "pid" => 9999)
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
      stub_const("SyrusMcp::StartPreviewTool::HEALTH_CHECK_TIMEOUT_SECONDS", -1)
      allow(Process).to receive(:spawn).and_return(12345)
      allow(described_class).to receive(:http_ok?).and_return(false)
    end

    it "returns an error mentioning the timeout" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("timed out")
    end

    it "removes the process from the registry after timeout" do
      call
      expect(SyrusMcp::AgentPreviewRegistry.get(run.id)).to be_nil
    end

    it "calls AgentPreviewRegistry.kill to stop the orphaned process" do
      expect(SyrusMcp::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      call
    end
  end

  context "when a seed command is configured" do
    let(:preview_config) do
      PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        seed_command:      "bin/rails db:seed",
        health_check_path: "/",
        log_paths:         []
      )
    end

    before do
      allow(Process).to receive(:spawn).and_return(1111)
      allow(described_class).to receive(:http_ok?).and_return(true)
    end

    it "calls run_seed! with the config and workspace path" do
      expect(described_class).to receive(:run_seed!).with(preview_config, workspace_path)
      call
    end

    it "still spawns and returns a URL even when the seed step fails" do
      allow(described_class).to receive(:run_seed!)
      response = call
      expect(response).not_to be_error
    end
  end
end
