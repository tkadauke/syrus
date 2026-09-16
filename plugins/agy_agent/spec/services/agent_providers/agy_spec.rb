require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Agy do
  describe "plugin interface" do
    it "includes Syrus::Plugin::AgentProvider" do
      expect(described_class).to include(Syrus::Plugin::AgentProvider)
    end

    it "has provider_key 'agy'" do
      expect(described_class.provider_key).to eq("agy")
    end

    it "has display_name 'Antigravity'" do
      expect(described_class.display_name).to eq("Antigravity")
    end

    it "reports available?" do
      expect(described_class.available?).to eq(true)
    end

    it "provider_key matches provider for backward compat" do
      expect(described_class.provider_key).to eq(described_class.provider)
    end

    it "formats MCP tool labels for Antigravity" do
      expect(described_class.mcp_tool_name("submit_summary", server_name: "syrus-mcp-sidecar"))
        .to eq("mcp(syrus-mcp-sidecar/submit_summary)")
    end
  end

  let(:user) { Factories.user(gemini_api_key: "AIza-test") }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  around do |ex|
    old_runner = RunJob.agent_runner
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-agy-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    RunJob.agent_runner = old_runner
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  it "invokes AgyInvocation with an isolated workflow provider home" do
    received = nil
    RunJob.agent_runner = ->(**kwargs) {
      received = kwargs
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: "agy-session"
      )
    }

    result = described_class.new(run: run, workspace: workspace, parent_session_id: "parent-1")
                            .run(prompt: "do it", log_sink: ->(*, **) { })

    expect(result).to be_success
    expect(received).to include(
      workspace_path: "/tmp/worktree",
      prompt: "do it",
      api_key: "AIza-test",
      mcp_server: hash_including(
        command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
        args: [ "--run-id", run.id.to_s ]
      ),
      required_mcp_tools: [],
      resume_session_id: "parent-1"
    )
    expect(received[:agy_home]).to eq(WorkflowWorkspace.agent_home_for(workflow, "agy").to_s)
  end

  it "raises a configuration error when the Gemini API key is missing" do
    user.update!(gemini_api_key: nil)

    expect {
      described_class.new(run: run, workspace: workspace, parent_session_id: nil)
                     .run(prompt: "do it", log_sink: ->(*, **) { })
    }.to raise_error(AgentProviders::ConfigurationError, /Gemini API key/)
  end

  it "passes captured parent transcript JSONL for workflow resume" do
    source_run = Run.create!(job: job, step: step, trigger_kind: "initial",
                             state: "failed",
                             started_at: 1.minute.ago,
                             finished_at: Time.current)
    ProviderSession.create!(resumable: source_run,
                            provider: "agy",
                            session_id: "parent-1",
                            transcript_jsonl: "{\"event\":\"init\"}\n")
    received = nil
    RunJob.agent_runner = ->(**kwargs) {
      received = kwargs
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: "agy-session"
      )
    }

    result = described_class.new(run: run, workspace: workspace, parent_session_id: "parent-1")
                            .run(prompt: "resume", log_sink: ->(*, **) { })

    expect(result).to be_success
    expect(received[:resume_session_id]).to eq("parent-1")
    expect(received[:resume_transcript_jsonl]).to include("\"event\":\"init\"")
  end

  it "launches the sidecar for non-implement steps too" do
    review_step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 99)
    review_run = review_step.runs.create!(job: job, trigger_kind: run.trigger_kind, agent_provider: "agy")
    received = nil
    RunJob.agent_runner = ->(**kwargs) {
      received = kwargs
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: "agy-session"
      )
    }

    result = described_class.new(run: review_run, workspace: workspace, parent_session_id: nil)
                            .run(prompt: "review", log_sink: ->(*, **) { })

    expect(result).to be_success
    expect(received[:mcp_server]).to include(
      command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
      args: [ "--run-id", review_run.id.to_s ]
    )
  end

  it "persists live_session_id on the Run when the init callback fires" do
    RunJob.agent_runner = ->(**kwargs) {
      kwargs[:on_session_id].call("agy-live-1")
      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: "agy-live-1"
      )
    }

    described_class.new(run: run, workspace: workspace, parent_session_id: nil)
                   .run(prompt: "do it", log_sink: ->(*, **) { })

    expect(run.reload.live_session_id).to eq("agy-live-1")
  end

  describe "#session_capture" do
    it "reads Antigravity's canonical JSONL path when the invocation result omitted transcript data" do
      Dir.mktmpdir do |home|
        allow(WorkflowWorkspace).to receive(:agent_home_for).with(workflow, "agy").and_return(home)
        path = AgyAgent::SessionPaths.canonical_path_for(
          home: home,
          cwd: workspace.path,
          session_id: "S-captured"
        )
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "{\"event\":\"init\"}\n")
        result = AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                             is_error: false, outcome: "success",
                                             final_text: nil, session_id: "S-captured")

        capture = described_class.new(run: run, workspace: workspace, parent_session_id: nil)
                              .session_capture(result)

        expect(capture.provider).to eq("agy")
        expect(capture.session_id).to eq("S-captured")
        expect(capture.transcript_jsonl).to include("init")
        expect(capture.missing_message).to be_nil
      end
    end

    it "returns clear diagnostics when the captured session id is unsafe" do
      result = AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                           is_error: false, outcome: "success",
                                           final_text: nil, session_id: "../outside")

      capture = described_class.new(run: run, workspace: workspace, parent_session_id: nil)
                            .session_capture(result)

      expect(capture.provider).to eq("agy")
      expect(capture.session_id).to eq("../outside")
      expect(capture.transcript_jsonl).to be_nil
      expect(capture.missing_message).to include("invalid Antigravity session id")
    end
  end
end
