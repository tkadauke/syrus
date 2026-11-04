require "rails_helper"

RSpec.describe Mcp::Tools::StopPreviewTool do
  let(:run) { Factories.job.initial_run }

  def call
    described_class.call(server_context: { run: run })
  end

  before  { Mcp::Tools::AgentPreviewRegistry.reset! }
  after   { Mcp::Tools::AgentPreviewRegistry.reset! }

  it "exposes the expected tool name" do
    expect(described_class.tool_name).to eq("stop_preview")
  end

  it "returns success" do
    response = call
    expect(response).not_to be_error
    expect(response.content.first[:text]).to eq("Preview stopped.")
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] stop_preview")
  end

  it "waits for an in-flight artifact capture before stopping the preview" do
    Mcp::Tools::AgentPreviewRegistry.register(key: run.id, pid: 12_345, port: 3001)
    capture_started = Queue.new
    release_capture = Queue.new
    capture = Thread.new do
      Mcp::Tools::AgentPreviewRegistry.while_in_use(run.id) do
        capture_started << true
        release_capture.pop
      end
    end
    capture_started.pop
    stopped = Queue.new
    stopper = Thread.new { call.tap { stopped << true } }

    expect { stopped.pop(true) }.to raise_error(ThreadError)
    release_capture << true
    expect(stopped.pop).to be(true)
    capture.join
    stopper.join
  end

  it "waits for an in-flight artifact capture before stopping a runtime-session preview" do
    preview_key = "#{run.id}:runtime-session"
    Mcp::Tools::AgentPreviewRegistry.register(key: preview_key, pid: 12_345, port: 3001)
    capture_started = Queue.new
    release_capture = Queue.new
    capture = Thread.new do
      Mcp::Tools::AgentPreviewRegistry.while_in_use(run.id, prefixes: [ "#{run.id}:" ]) do
        capture_started << true
        release_capture.pop
      end
    end
    capture_started.pop
    stopped = Queue.new
    stopper = Thread.new { call.tap { stopped << true } }

    expect { stopped.pop(true) }.to raise_error(ThreadError)
    expect(Mcp::Tools::AgentPreviewRegistry.get(preview_key)).to be_present
    release_capture << true
    expect(stopped.pop).to be(true)
    expect(Mcp::Tools::AgentPreviewRegistry.get(preview_key)).to be_nil
    capture.join
    stopper.join
  end

  it "waits for an in-flight artifact capture before stopping all previews" do
    preview_key = "#{run.id}:runtime-session"
    Mcp::Tools::AgentPreviewRegistry.register(key: preview_key, pid: 12_345, port: 3001)
    capture_started = Queue.new
    release_capture = Queue.new
    capture = Thread.new do
      Mcp::Tools::AgentPreviewRegistry.while_in_use(run.id, prefixes: [ "#{run.id}:" ]) do
        capture_started << true
        release_capture.pop
      end
    end
    capture_started.pop
    stopped = Queue.new
    stopper = Thread.new { Mcp::Tools::AgentPreviewRegistry.kill_all.tap { stopped << true } }

    expect { stopped.pop(true) }.to raise_error(ThreadError)
    expect(Mcp::Tools::AgentPreviewRegistry.get(preview_key)).to be_present
    release_capture << true
    expect(stopped.pop).to be(true)
    expect(Mcp::Tools::AgentPreviewRegistry.get(preview_key)).to be_nil
    capture.join
    stopper.join
  end

  context "when a preview is registered" do
    let!(:spawned_process) do
      SpawnedProcess.create!(kind: "preview", command: "bin/server", hostname: "worker",
        started_at: Time.current, pid: 9999)
    end
    let(:handle) do
      instance_double(ProcessRunner::BackgroundHandle, finalize: nil).tap do |managed_handle|
        allow(managed_handle).to receive(:cancel!) { spawned_process.request_kill! }
      end
    end

    before do
      allow(ProcessRunner::BackgroundHandle).to receive(:find).with(spawned_process.id).and_return(handle)
      Mcp::Tools::AgentPreviewRegistry.register(
        key: run.id, pid: 9999, port: 3001, spawned_process_id: spawned_process.id
      )
    end

    it "removes the run from the registry" do
      call
      expect(Mcp::Tools::AgentPreviewRegistry.get(run.id)).to be_nil
    end

    it "calls kill on the registry for this run" do
      expect(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      call
    end

    it "runs the registered resource cleanup after stopping the process" do
      cleanup = instance_double(Proc, call: nil)
      Mcp::Tools::AgentPreviewRegistry.register(
        key: run.id, pid: 9999, port: 3001,
        spawned_process_id: spawned_process.id, cleanup: cleanup
      )

      call

      expect(cleanup).to have_received(:call)
    end

    it "requests cancellation through the durable ProcessRunner handle" do
      call

      expect(spawned_process.reload.kill_requested_at).to be_present
    end
  end

  context "when no preview is running" do
    it "is a no-op and still returns success" do
      expect(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(run.id).and_call_original
      response = call
      expect(response).not_to be_error
    end
  end
end
