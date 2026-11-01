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

    it "find_chat_session! can still access the caller's own soft-deleted chat session" do
      deleted_chat = ChatSession.create!(user: user, repository: repository)
      deleted_chat.soft_delete_by!(user)

      expect(with_context { tool.find_chat_session!(deleted_chat.id) }).to eq(deleted_chat)
    end

    it "find_chat_session! still cannot access another user's chat session" do
      other_user = Factories.user
      other_chat = ChatSession.create!(user: other_user, repository: Factories.repository(user: other_user))

      expect { with_context { tool.find_chat_session!(other_chat.id) } }
        .to raise_error(described_class::AuthorizationError, "chat session not found or not accessible")
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

  it "raises AuthorizationError when find_chat_session! sees a soft-deleted chat session, even the current one's own" do
    deleted_chat = ChatSession.create!(user: user, repository: repository)
    deleted_chat.soft_delete_by!(user)

    expect { with_context { tool.find_chat_session!(deleted_chat.id) } }
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

  describe ".pending_coworker_approval" do
    let(:coworker) do
      Coworkers::Coworker.create!(
        owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
      )
    end
    let(:coworker_tool) do
      Class.new(MCP::Tool) do
        tool_name "read_custom_data"
        input_schema(properties: { query: { type: "string" } }, required: %w[query])
      end
    end
    let(:permission_descriptor) do
      generated = Permissions::CapabilityDescriptorAdapter.for_registry_entry(
        tool_name: "read_custom_data", capability: "custom.read", mutation: false,
        required_roles: [ AgentRole::COWORKER_CHAT ]
      )
      Permissions::CapabilityDescriptor.new(**generated.to_h.merge(
        defaults: { AgentRole::COWORKER_CHAT => :ask }
      ))
    end
    let(:catalog_descriptor) do
      Mcp::CoworkerToolCatalog::Descriptor.new(
        tool_name: "read_custom_data", capability: "custom.read", ungated: false,
        tier: :essential, tool: coworker_tool, provider: nil
      )
    end
    let(:registry_entry) { Struct.new(:tool, :descriptor).new(coworker_tool, permission_descriptor) }

    before do
      Coworkers::Chat.create!(coworker:, chat_session:, role: "main")
      assigned_coworker = coworker
      chat_session.define_singleton_method(:coworker) { assigned_coworker }
      allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog_descriptor)
      allow(McpToolRegistry).to receive(:entries).with(surface: :coworker).and_return([ registry_entry ])
      grant_descriptor = instance_double(Coworkers::GrantCatalog::Descriptor, valid_scope?: true)
      allow(Coworkers::GrantCatalog).to receive(:fetch).with("custom.read").and_return(grant_descriptor)
    end

    it "creates and anchors one compound request through the production dispatch helper" do
      current_message = instance_double(Mcp::Tools::CurrentMessage)
      expect(current_message).to receive(:update_columns).with(pending_action_id: kind_of(Integer))

      response = described_class.pending_coworker_approval(
        coworker_tool, { chat_session:, current_message: }, { query: "customers" }
      )
      payload = JSON.parse(response.content.first[:text])
      request = ChatPendingAction.find(payload.fetch("pending_action_id"))

      expect(payload).to include(
        "message" => "Waiting for the owner to decide the required permissions.",
        "approval_policy" => "queue"
      )
      expect(request).to be_authorization_request
      expect(request.authorization_items.pluck(:kind)).to contain_exactly("operation")
    end

    it "does not let a legacy automatic grant bypass unified invocation approval" do
      coworker.grants.create!(capability: "custom.read", approval_policy: "auto")

      response = described_class.pending_coworker_approval(
        coworker_tool, { chat_session: }, { query: "customers" }
      )
      request_id = JSON.parse(response.content.first[:text]).fetch("pending_action_id")

      expect(ChatPendingAction.find(request_id).authorization_items.pluck(:kind)).to eq([ "operation" ])
    end

    it "fails closed when a core registry entry has no permission descriptor" do
      allow(McpToolRegistry).to receive(:entries).with(surface: :coworker)
        .and_return([ Struct.new(:tool, :descriptor).new(coworker_tool, nil) ])

      expect {
        described_class.pending_coworker_approval(coworker_tool, { chat_session: }, { query: "customers" })
      }.to raise_error(described_class::AuthorizationError, "tool has no permission descriptor")
    end

    it "adapts plugin tool definitions into permission descriptors" do
      plugin_descriptor = Mcp::CoworkerToolCatalog::Descriptor.new(
        tool_name: "plugin_read", capability: "plugin.read", ungated: false,
        tier: :essential, tool: nil, provider: Class.new,
        definition: {
          name: "plugin_read", capability: "plugin.read", mutation: true,
          requestable_roles: [ AgentRole::COWORKER_CHAT ]
        }
      )
      allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(plugin_descriptor)

      response = described_class.pending_coworker_approval(
        "plugin_read", { chat_session: }, { query: "customers" }
      )
      request = ChatPendingAction.find(JSON.parse(response.content.first[:text]).fetch("pending_action_id"))

      expect(request.authorization_items.find_by(kind: "operation")).to have_attributes(
        capability: "plugin.read", operation: "plugin.read/plugin_read"
      )
    end
  end
end
