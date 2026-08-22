require "rails_helper"

RSpec.describe PersistentMcpDaemon::ChatContextResolver do
  # Created first so `user` below isn't auto-promoted to admin by
  # User#promote_first_user_to_admin (the very first user in a fresh test
  # database becomes an admin).
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }
  let(:message) { chat.messages.create!(role: "user", content: { text: "hi" }) }
  let(:worker_id) { "worker-1" }

  def raw_context(token)
    { identity: { worker_id: worker_id }, _meta: { PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY => token } }
  end

  def token_for(tier: "essential", current_message: nil, evaluator: false)
    McpInvocationContext.issue_for_chat(
      chat, worker_id: worker_id, current_message: current_message, tier: tier, evaluator: evaluator
    )
  end

  describe ".resolve" do
    it "rebuilds the stdio-equivalent server_context and scopes allowed_tools to the essential tier" do
      resolved = described_class.resolve(raw_context(token_for(tier: "essential", current_message: message)))

      expect(resolved.server_context[:chat_session]).to eq(chat)
      expect(resolved.server_context[:current_message]).to eq(message)
      expect(resolved.server_context[:evaluator]).to be_nil
      expect(resolved.allowed_tools).to include(Mcp::Tools::ListJobsTool)
      expect(resolved.allowed_tools).not_to include(Mcp::Tools::ReadWorkflowTool)
    end

    it "falls back to a CurrentMessage wrapper when no current_message_id was issued" do
      resolved = described_class.resolve(raw_context(token_for))

      expect(resolved.server_context[:current_message]).to be_a(Mcp::Tools::CurrentMessage)
    end

    it "scopes allowed_tools to the deferred tier" do
      resolved = described_class.resolve(raw_context(token_for(tier: "deferred")))

      expect(resolved.allowed_tools).to include(Mcp::Tools::ReadWorkflowTool)
      expect(resolved.allowed_tools).not_to include(Mcp::Tools::ListJobsTool)
    end

    it "excludes admin-only tools for a non-admin user" do
      resolved = described_class.resolve(raw_context(token_for))

      expect(resolved.allowed_tools).not_to include(Mcp::Tools::AdminOverviewTool)
    end

    it "includes admin-only tools for an admin user" do
      user.update!(admin: true)

      resolved = described_class.resolve(raw_context(token_for))

      expect(resolved.allowed_tools).to include(Mcp::Tools::AdminOverviewTool)
    end

    it "excludes SUPERVISOR_EXCLUDED_TOOLS for a supervisor chat session" do
      chat.update!(system_kind: "supervisor")

      resolved = described_class.resolve(raw_context(token_for))

      expect(McpToolPolicy::SUPERVISOR_EXCLUDED_TOOLS).to include(Mcp::Tools::ProposeJobTool)
      expect(resolved.allowed_tools).not_to include(Mcp::Tools::ProposeJobTool)
    end

    it "uses McpToolPolicy's evaluator tool set for an evaluator-scoped token" do
      resolved = described_class.resolve(raw_context(token_for(evaluator: true)))

      expect(resolved.server_context[:evaluator]).to be true
      expect(resolved.allowed_tools).to include(Mcp::Tools::ListJobsTool)
    end

    it "raises Malformed for a token minted for the run surface" do
      job = Factories.job(user: user, repository: repository)
      run = job.runs.first
      token = McpInvocationContext.issue_for_run(run, worker_id: worker_id)

      expect { described_class.resolve(raw_context(token)) }.to raise_error(McpInvocationContext::Malformed, /not chat/)
    end

    it "propagates McpInvocationContext rejection reasons (expired, wrong worker, malformed)" do
      expired_token = McpInvocationContext.issue_for_chat(chat, worker_id: worker_id, expires_in: -1.minute)
      expect { described_class.resolve(raw_context(expired_token)) }.to raise_error(McpInvocationContext::Expired)

      expect { described_class.resolve(raw_context(token_for)) }.not_to raise_error
      wrong_worker_context = { identity: { worker_id: "other-worker" }, _meta: { PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY => token_for } }
      expect { described_class.resolve(wrong_worker_context) }.to raise_error(McpInvocationContext::WrongWorker)

      expect { described_class.resolve(raw_context("garbage")) }.to raise_error(McpInvocationContext::Malformed)
    end
  end
end
