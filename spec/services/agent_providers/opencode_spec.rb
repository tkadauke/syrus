require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::OpenCode do
  let(:user) do
    Factories.user(
      agent_provider: "opencode",
      opencode_backend: "openai_api",
      opencode_model: "gpt-4.1",
      opencode_api_key: "sk-test"
    )
  end
  let(:job) { Factories.job(user: user, agent_provider: "opencode") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "opencode") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "opencode") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  def adapter(parent_session_id: "ses_old")
    described_class.new(run: run, workspace: workspace, parent_session_id: parent_session_id)
  end

  around do |ex|
    old_runner = RunJob.agent_runner
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-opencode-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    RunJob.agent_runner = old_runner
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  describe "#run" do
    it "raises a configuration error when OpenCode is incomplete" do
      user.update!(opencode_api_key: nil)

      expect {
        adapter.run(prompt: "do it", log_sink: ->(*, **) { })
      }.to raise_error(AgentProviders::ConfigurationError, /OpenCode is not configured/)
    end

    it "invokes OpenCodeInvocation with backend, sidecar config, and captured resume transcript" do
      source_run = Run.create!(job: job, step: step, trigger_kind: "initial",
                               state: "failed",
                               started_at: 1.minute.ago,
                               finished_at: Time.current,
                               agent_provider: "opencode")
      ClaudeSession.create!(resumable: source_run,
                            provider: "opencode",
                            session_id: "ses_old",
                            transcript_jsonl: "{\"type\":\"step_start\"}\n")
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "stop",
                                    final_text: "done", session_id: "ses_new",
                                    transcript_jsonl: "{\"type\":\"text\"}\n")
      }

      result = adapter.run(prompt: "resume", log_sink: ->(*, **) { })

      expect(result).to be_success
      expect(received).to include(
        workspace_path: "/tmp/worktree",
        prompt: "resume",
        opencode_home: WorkflowWorkspace.agent_home_for(workflow, "opencode").to_s,
        resume_session_id: "ses_old"
      )
      expect(received[:backend_config]).to have_attributes(
        backend: "openai_api",
        model: "gpt-4.1",
        api_key: "sk-test",
        endpoint_url: nil
      )
      expect(received[:resume_transcript_jsonl]).to include("step_start")
      expect(received[:mcp_server]).to include(
        command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
        args: [ "--run-id", run.id.to_s ]
      )
    end
  end

  describe "#run_once" do
    it "invokes OpenCode in a tmpdir without MCP or resume state" do
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "stop",
                                    final_text: '{"title":"x","body":"y"}',
                                    session_id: nil)
      }

      result = adapter.run_once(prompt: "summarize",
                                log_sink: ->(*, **) { },
                                timeout: 9,
                                max_turns: 1)

      expect(result).to be_success
      expect(received[:workspace_path]).to start_with(Dir.tmpdir)
      expect(received).to include(
        prompt: "summarize",
        timeout: 9,
        mcp_server: nil,
        resume_session_id: nil,
        resume_transcript_jsonl: nil
      )
      expect(received[:backend_config].backend).to eq("openai_api")
    end
  end

  describe "#record_result!" do
    it "persists generic metadata and delegates transcript capture" do
      messages = []
      result = AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "stop",
        final_text: nil,
        session_id: "ses_new",
        transcript_jsonl: "{\"type\":\"step_start\"}\n"
      )

      adapter.record_result!(result, log: ->(message) { messages << message })

      expect(run.reload.agent_turns).to eq(1)
      expect(run.agent_outcome).to eq("stop")
      expect(run.claude_session.provider).to eq("opencode")
      expect(run.claude_session.session_id).to eq("ses_new")
      expect(messages.join("\n")).to include("captured opencode ses_new")
    end
  end
end
