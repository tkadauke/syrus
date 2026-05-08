require "rails_helper"
require "tmpdir"

RSpec.describe AgentProviders::Codex do
  let(:user) { Factories.user(codex_api_key: "sk-test") }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: "/tmp/worktree") }

  def adapter(parent_session_id: "codex-thread")
    described_class.new(run: run, workspace: workspace, parent_session_id: parent_session_id)
  end

  around do |ex|
    old_runner = RunJob.agent_runner
    old_data_root = ENV["SYRUS_DATA_ROOT"]
    data_root = Dir.mktmpdir("syrus-codex-provider")
    ENV["SYRUS_DATA_ROOT"] = data_root
    ex.run
  ensure
    RunJob.agent_runner = old_runner
    ENV["SYRUS_DATA_ROOT"] = old_data_root
    FileUtils.rm_rf(data_root) if data_root
  end

  describe "#run" do
    it "raises a configuration error when the Codex API key is missing" do
      user.update!(codex_api_key: nil)

      expect {
        adapter.run(prompt: "do it", log_sink: ->(*, **) { })
      }.to raise_error(AgentProviders::ConfigurationError, /Codex API key/)
    end

    it "invokes CodexInvocation with sidecar config and captured resume transcript" do
      source_run = Run.create!(job: job, step: step, trigger_kind: "initial",
                               state: "failed",
                               started_at: 1.minute.ago,
                               finished_at: Time.current)
      ClaudeSession.create!(run: source_run,
                            provider: "codex",
                            session_id: "codex-thread",
                            transcript_jsonl: "{\"type\":\"session_meta\"}\n")
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: "new-thread")
      }

      result = adapter.run(prompt: "resume", log_sink: ->(*, **) { })

      expect(result).to be_success
      expect(received).to include(
        workspace_path: "/tmp/worktree",
        prompt: "resume",
        api_key: "sk-test",
        codex_home: WorkflowWorkspace.agent_home_for(workflow, "codex").to_s,
        resume_session_id: "codex-thread"
      )
      expect(received[:resume_transcript_jsonl]).to include("session_meta")
      expect(received[:mcp_server]).to include(
        command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
        args: [ "--run-id", run.id.to_s ]
      )
    end

    it "writes ChatGPT auth.json and invokes Codex without CODEX_API_KEY" do
      user.update!(codex_auth_mode: "chatgpt_login",
                   codex_auth_json: Factories.codex_auth_json(access_token: "access-token"))
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        File.write(File.join(kwargs.fetch(:codex_home), "auth.json"),
                   Factories.codex_auth_json(access_token: "refreshed-token"))
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: "new-thread")
      }

      result = adapter(parent_session_id: nil).run(prompt: "do it", log_sink: ->(*, **) { })

      expect(result).to be_success
      expect(received[:api_key]).to be_nil
      auth_path = File.join(WorkflowWorkspace.agent_home_for(workflow, "codex"), "auth.json")
      expect(JSON.parse(File.read(auth_path))["tokens"]["access_token"]).to eq("refreshed-token")
      expect(user.reload.codex_auth_json).to include("refreshed-token")
    end
  end
end
