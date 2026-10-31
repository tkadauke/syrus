require "rails_helper"

RSpec.describe PersistentMcpDaemon::WorkflowContextResolver do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository) }
  let(:run) { job.initial_run }
  let(:worker_id) { "worker-1" }

  def raw_context(token)
    { identity: { worker_id: worker_id }, _meta: { PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY => token } }
  end

  describe ".resolve" do
    it "accepts the run token surface and maps it to workflow tool policy" do
      token = McpInvocationContext.issue_for_run(run, worker_id: worker_id, provider: "claude")

      resolved = described_class.resolve(raw_context(token))

      expect(resolved.server_context).to include(run: run, run_id: run.id)
      expect(resolved.tool_context.surface).to eq(:run)
      expect(resolved.provider).to eq("claude")
      expect(resolved.allowed_tools).to include(Mcp::Tools::ReadLiveStateTool)
      expect(resolved.allowed_tool_names).to include("read_live_state")
    end

    it "rejects chat-surface tokens instead of treating every non-chat token as workflow" do
      chat = ChatSession.create!(user: user, repository: repository)
      token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id)

      expect { described_class.resolve(raw_context(token)) }
        .to raise_error(McpInvocationContext::Malformed, /not run/)
    end

    it "does not authorize plugin workflow tools for a coworker run through direct dispatch" do
      PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
      coworker = Coworkers::Coworker.create!(
        owner_user: user, name: "Maya", handle: "maya-resolver",
        workspace_repo: repository.remote_url
      )
      main_chat = ChatSession.create!(user: user, repository: repository, title: "Maya")
      Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")
      coworker_job = Job.create!(
        user: user, repository: repository, kind: "coworker_task", priority: "low",
        origin: "coworkers", origin_id: coworker.id.to_s, issue_title: "Background task"
      )
      workflow = Coworkers::Workflow.instantiate(job: coworker_job)
      step = workflow.steps.find_by!(kind: "coworker_run")
      coworker_run = Run.create!(
        job: coworker_job, user: user, step: step, trigger_kind: "coworker_run", agent_provider: "codex"
      )
      token = McpInvocationContext.issue_for_run(coworker_run, worker_id: worker_id, provider: "codex")
      plugin_tool = Class.new(MCP::Tool) do
        tool_name "unsafe_plugin_workflow_tool"

        def self.call(server_context:)
          Mcp::Tools.success(called: true)
        end
      end
      allow(Mcp::Sidecar).to receive(:plugin_workflow_tools_for).with(have_attributes(role: AgentRole::COWORKER)).and_return([ plugin_tool ])

      resolved = described_class.resolve(raw_context(token))
      expect(resolved.allowed_tool_names).not_to include("unsafe_plugin_workflow_tool")
      expect(Mcp::Sidecar).not_to have_received(:plugin_workflow_tools_for)

      wrapped = PersistentMcpDaemon::WorkflowToolDispatch.wrap(plugin_tool)
      response = wrapped.call(server_context: raw_context(token).merge(workflow_role: AgentRole::COWORKER))

      expect(response).to be_error
      expect(JSON.parse(response.content.first[:text])).to include("error" => "not_authorized")
    end
  end

  it "returns a useful tool error when persistent workflow dispatch raises" do
    token = McpInvocationContext.issue_for_run(run, worker_id: worker_id, provider: "claude")
    tool = Class.new(MCP::Tool) do
      tool_name "broken_persistent_tool"

      def self.call(server_context:)
        raise KeyError, "missing context"
      end
    end
    resolved = instance_double(
      PersistentMcpDaemon::WorkflowContextResolver::Resolved,
      tool_context: instance_double(McpToolContext, run: run),
      allowed_tool_names: [ "broken_persistent_tool" ],
      server_context: { run: run },
      provider: "claude"
    )
    allow(described_class).to receive(:resolve).and_return(resolved)
    PersistentMcpDaemon::WorkflowToolDispatch.wrap(tool)

    response = tool.call(server_context: raw_context(token).merge(workflow_role: AgentRole::WORKFLOW_IMPLEMENT))

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Tool failed with KeyError", "report it to the operator")
    expect(McpToolUsage.last).to have_attributes(status: "failed", error_class: "KeyError")
  end
end
