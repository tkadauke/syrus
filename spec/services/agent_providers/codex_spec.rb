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
      ClaudeSession.create!(resumable: source_run,
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

    it "configures agent insight runs to launch the sidecar that advertises workflow evidence tools" do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")
      insight_job = Job.create!(user: user, repository: job.repository, kind: "agent_insight", priority: "low")
      insight_workflow = Workflows::AgentInsight.instantiate(job: insight_job)
      insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
      insight_run = insight_step.runs.first || insight_step.runs.create!(job: insight_job, trigger_kind: insight_workflow.trigger_kind)
      insight_adapter = described_class.new(run: insight_run, workspace: workspace, parent_session_id: nil)
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: "new-thread")
      }

      result = insight_adapter.run(prompt: "inspect recent runs", log_sink: ->(*, **) { })

      expect(result).to be_success
      expect(received[:mcp_server]).to include(
        command: a_string_ending_with("/bin/syrus-mcp-sidecar"),
        args: [ "--run-id", insight_run.id.to_s ]
      )
      context = McpToolContext.from_run(Run.includes(:step, job: :repository).find(insight_run.id))
      tool_names = McpToolPolicy.for(context).map(&:tool_name)
      expect(tool_names).to include("list_recent_workflows", "read_run_transcript")
    end

    it "writes ChatGPT auth.json and invokes Codex without CODEX_API_KEY" do
      user.update!(codex_auth_mode: "chatgpt_login",
                   codex_auth_json: Factories.codex_auth_json(access_token: "access-token"))
      received = nil
      runner_lock_depth = nil
      lock_depth = 0
      allow(CodexAuth).to receive(:with_refresh_lock) do |user:, timeout: CodexAuth::DEFAULT_REFRESH_LOCK_TIMEOUT_SECONDS, &block|
        lock_depth += 1
        block.call
      ensure
        lock_depth -= 1
      end
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        runner_lock_depth = lock_depth
        File.write(File.join(kwargs.fetch(:codex_home), "auth.json"),
                   Factories.codex_auth_json(access_token: "refreshed-token"))
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
                                    final_text: nil, session_id: "new-thread")
      }

      result = adapter(parent_session_id: nil).run(prompt: "do it", log_sink: ->(*, **) { })

      expect(result).to be_success
      expect(received[:api_key]).to be_nil
      expect(runner_lock_depth).to eq(0)
      auth_path = File.join(WorkflowWorkspace.agent_home_for(workflow, "codex"), "auth.json")
      expect(JSON.parse(File.read(auth_path))["tokens"]["access_token"]).to eq("refreshed-token")
      expect(user.reload.codex_auth_json).to include("refreshed-token")
    end
  end

  describe "#run_once" do
    it "invokes Codex in a tmpdir without MCP or resume state" do
      received = nil
      RunJob.agent_runner = ->(**kwargs) {
        received = kwargs
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                    is_error: false, outcome: "success",
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
        api_key: "sk-test",
        timeout: 9,
        mcp_server: nil,
        resume_session_id: nil,
        resume_transcript_jsonl: nil
      )
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
        outcome: "success",
        final_text: nil,
        session_id: "codex-thread",
        transcript_jsonl: "{\"type\":\"session_meta\"}\n"
      )

      adapter.record_result!(result, log: ->(message) { messages << message })

      expect(run.reload.agent_turns).to eq(1)
      expect(run.agent_outcome).to eq("success")
      expect(run.claude_session.provider).to eq("codex")
      expect(run.claude_session.session_id).to eq("codex-thread")
      expect(messages.join("\n")).to include("captured codex codex-thread")
    end
  end
end
