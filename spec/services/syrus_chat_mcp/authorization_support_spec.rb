require "rails_helper"

RSpec.describe Mcp::Tools::AuthorizationSupport do
  # Consume the first-user admin-promotion slot so the test user is not auto-promoted.
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  let(:tool) do
    Class.new do
      extend Mcp::Tools::AuthorizationSupport
    end
  end

  def with_context
    described_class.with_server_context({ chat_session: chat_session }) { yield }
  end

  it "finds jobs belonging to the current user" do
    job = Factories.job(repository: repository)

    expect(with_context { tool.find_job!(job.id) }).to eq(job)
  end

  it "raises AuthorizationError when find_job! sees another user's job" do
    other_user = Factories.user
    other_job = Factories.job(repository: Factories.repository(user: other_user))

    expect { with_context { tool.find_job!(other_job.id) } }
      .to raise_error(described_class::AuthorizationError, "job not found or not accessible")
  end

  context "when the user is an admin" do
    let(:user) { Factories.user(admin: true) }

    it "find_job! can access another user's job" do
      other_job = Factories.job(repository: Factories.repository(user: Factories.user))

      expect(with_context { tool.find_job!(other_job.id) }).to eq(other_job)
    end

    it "find_epic! can access another user's epic" do
      other_epic = Factories.epic(user: Factories.user)

      expect(with_context { tool.find_epic!(other_epic.id) }).to eq(other_epic)
    end

    it "find_workflow! can access another user's workflow" do
      other_job = Factories.job(repository: Factories.repository(user: Factories.user))
      other_workflow = other_job.latest_workflow

      expect(with_context { tool.find_workflow!(other_workflow.id) }).to eq(other_workflow)
    end

    it "find_run! can access another user's run" do
      other_job = Factories.job(repository: Factories.repository(user: Factories.user))
      other_run = other_job.initial_run

      expect(with_context { tool.find_run!(other_run.id) }).to eq(other_run)
    end

    it "authorize_resource! passes any resource through" do
      other_job = Factories.job(repository: Factories.repository(user: Factories.user))

      expect(with_context { tool.authorize_resource!(other_job) }).to eq(other_job)
    end
  end

  it "restricts find_job! to allowed_job_ids when the context limits scope" do
    allowed_job = Factories.job(repository: repository)
    blocked_job = Factories.job(repository: repository)

    restricted = McpToolContext.new(
      surface: :chat, role: AgentRole::CHAT_PLANNER, user: user,
      allowed_job_ids: [ allowed_job.id ]
    )
    allow(McpToolContext).to receive(:from_server_context).and_return(restricted)

    with_context do
      expect(tool.find_job!(allowed_job.id)).to eq(allowed_job)
      expect { tool.find_job!(blocked_job.id) }
        .to raise_error(described_class::AuthorizationError, "job not found or not accessible")
    end
  end

  it "finds workflows belonging to the current user" do
    job = Factories.job(repository: repository)
    workflow = job.latest_workflow

    expect(with_context { tool.find_workflow!(workflow.id) }).to eq(workflow)
  end

  it "raises AuthorizationError when find_workflow! sees another user's workflow" do
    other_workflow = Factories.job(repository: Factories.repository(user: Factories.user)).latest_workflow

    expect { with_context { tool.find_workflow!(other_workflow.id) } }
      .to raise_error(described_class::AuthorizationError, "workflow not found or not accessible")
  end

  it "finds runs belonging to the current user" do
    run = Factories.job(repository: repository).initial_run

    expect(with_context { tool.find_run!(run.id) }).to eq(run)
  end

  it "raises AuthorizationError when find_run! sees another user's run" do
    other_run = Factories.job(repository: Factories.repository(user: Factories.user)).initial_run

    expect { with_context { tool.find_run!(other_run.id) } }
      .to raise_error(described_class::AuthorizationError, "run not found or not accessible")
  end

  it "finds chat sessions belonging to the current user" do
    other_chat = ChatSession.create!(user: user, repository: repository)

    expect(with_context { tool.find_chat_session!(other_chat.id) }).to eq(other_chat)
  end

  it "raises AuthorizationError when find_chat_session! sees another user's chat session" do
    other_user = Factories.user
    other_chat = ChatSession.create!(user: other_user, repository: Factories.repository(user: other_user))

    expect { with_context { tool.find_chat_session!(other_chat.id) } }
      .to raise_error(described_class::AuthorizationError, "chat session not found or not accessible")
  end

  it "raises AuthorizationError when find_chat_session! is given a non-existent id" do
    expect { with_context { tool.find_chat_session!(ChatSession.maximum(:id).to_i + 999) } }
      .to raise_error(described_class::AuthorizationError, "chat session not found or not accessible")
  end


  it "returns a not_authorized tool error when registered tools raise AuthorizationError" do
    raising_tool = Class.new(MCP::Tool) do
      tool_name "raising_tool"
      input_schema(properties: {})

      class << self
        def call(server_context:)
          raise Mcp::Tools::AuthorizationSupport::AuthorizationError, "blocked"
        end
      end
    end

    server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ Mcp::Sidecar.authorize_tool(raising_tool) ],
      server_context: { chat_session: chat_session }
    )

    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "raising_tool", arguments: {} }
    }.to_json)
    response = JSON.parse(raw, symbolize_names: true)
    payload = JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)

    expect(response[:result][:isError]).to be(true)
    expect(payload).to eq(error: "not_authorized")
  end
end
