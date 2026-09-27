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
  end
end
