require "rails_helper"

RSpec.describe SyrusMcp::ReadPreviewLogTool do
  let(:run)            { Factories.job.initial_run }
  let(:workspace_path) { WorkflowWorkspace.path_for(run.step.workflow).to_s }

  let(:preview_config) do
    PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/rails server -p #{port}" },
      seed_command:      nil,
      health_check_path: "/",
      log_paths:         [ "log/development.log" ]
    )
  end

  def call(**kwargs)
    described_class.call(**kwargs, server_context: { run: run })
  end

  before do
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(double(resolve: preview_config))
  end

  it "exposes the expected tool name" do
    expect(described_class.tool_name).to eq("read_preview_log")
  end

  context "when reading from the default log path" do
    let(:log_path) { File.join(workspace_path, "log/development.log") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(log_path).and_return(true)
      allow(File).to receive(:readlines).with(log_path, chomp: true)
                                        .and_return((1..200).map { |i| "line #{i}" })
    end

    it "returns the last 100 lines by default" do
      response = call
      expect(response).not_to be_error
      text = response.content.first[:text]
      expect(text).to include("last 100 lines")
      expect(text).to include("line 200")
      expect(text).not_to include("line 100\n")
    end

    it "returns the requested number of lines" do
      response = call(lines: 5)
      text = response.content.first[:text]
      expect(text).to include("last 5 lines")
      expect(text).to include("line 196\nline 197\nline 198\nline 199\nline 200")
    end

    it "includes the log file path in the response" do
      response = call
      expect(response.content.first[:text]).to include(log_path)
    end
  end

  context "when a caller-supplied path is given" do
    let(:custom_log_path) { File.join(workspace_path, "log/sidekiq.log") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(custom_log_path).and_return(true)
      allow(File).to receive(:readlines).with(custom_log_path, chomp: true)
                                        .and_return([ "sidekiq started" ])
    end

    it "reads from the specified path" do
      response = call(path: "log/sidekiq.log")
      expect(response).not_to be_error
      expect(response.content.first[:text]).to include("sidekiq started")
    end

    it "also accepts an absolute path within the workspace" do
      response = call(path: custom_log_path)
      expect(response).not_to be_error
      expect(response.content.first[:text]).to include("sidekiq started")
    end
  end

  context "when path traversal is attempted" do
    it "returns an error for a path escaping the workspace" do
      response = call(path: "../../etc/passwd")
      expect(response).to be_error
      expect(response.content.first[:text]).to include("no log path")
    end

    it "returns an error for an absolute path outside the workspace" do
      response = call(path: "/etc/passwd")
      expect(response).to be_error
    end
  end

  context "when no log path is configured and none is supplied" do
    let(:preview_config) do
      PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/rails server -p #{port}" },
        seed_command:      nil,
        health_check_path: "/",
        log_paths:         []
      )
    end

    it "returns an error" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("no log path configured")
    end
  end

  context "when no preview config is registered" do
    before { allow(PreviewCommandSource).to receive(:new).and_return(double(resolve: nil)) }

    it "returns an error when no explicit path is supplied" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("no log path configured")
    end
  end

  context "when the log file does not exist" do
    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(workspace_path, "log/development.log")).and_return(false)
    end

    it "returns an error" do
      response = call
      expect(response).to be_error
      expect(response.content.first[:text]).to include("log file not found")
    end
  end

  context "when lines is above MAX_LINES" do
    let(:log_path) { File.join(workspace_path, "log/development.log") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(log_path).and_return(true)
      allow(File).to receive(:readlines).with(log_path, chomp: true).and_return([])
    end

    it "clamps to MAX_LINES" do
      response = call(lines: 99_999)
      expect(response).not_to be_error
      expect(response.content.first[:text]).to include("last #{SyrusMcp::ReadPreviewLogTool::MAX_LINES} lines")
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
end
