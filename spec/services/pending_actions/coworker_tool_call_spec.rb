require "rails_helper"

RSpec.describe PendingActions::CoworkerToolCall do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
  end
  let(:tool) do
    Class.new(MCP::Tool) do
      tool_name "read_custom_data"
      input_schema(properties: { query: { type: "string" } }, required: %w[query])

      class << self
        def call(query:, server_context:)
          Mcp::Tools.success(result: query)
        end
      end
    end
  end
  let(:descriptor) do
    generated = Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: "read_custom_data", capability: "custom.read", mutation: true,
      required_roles: [ AgentRole::COWORKER_CHAT ]
    )
    Permissions::CapabilityDescriptor.new(**generated.to_h.merge(
      defaults: { AgentRole::COWORKER_CHAT => :ask }
    ))
  end
  let(:catalog_descriptor) do
    Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_custom_data", capability: "custom.read", ungated: false,
      tier: :essential, tool:, provider: nil
    )
  end
  let(:context) do
    McpToolContext.new(
      surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
      repository:, chat_session: chat, agent_actor: coworker
    )
  end
  let(:request) do
    Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "customers" },
      action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    ).call.request
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog_descriptor)
    entry = Struct.new(:tool, :descriptor).new(tool, descriptor)
    allow(McpToolRegistry).to receive(:entries).with(surface: :coworker).and_return([ entry ])
  end

  it "refuses execution until every authorization item is approved" do
    expect { described_class.new(request).authorize_execution! }
      .to raise_error(ArgumentError, /prerequisites are not approved/)
  end

  it "accepts only the exact fingerprinted invocation after all items are approved" do
    request.authorization_items.each do |item|
      duration = item.kind == "operation" ? "invocation" : nil
      item.decide!("approved", principal: owner, duration:)
    end

    expect { described_class.new(request).authorize_execution! }.not_to raise_error

    request.update!(payload: request.payload.merge("arguments" => { "query" => "payments" }))
    expect { described_class.new(request).authorize_execution! }
      .to raise_error(ArgumentError, /no longer matches/)
  end

  it "claims an approved invocation once and refuses replay" do
    operation = request.authorization_items.sole
    Permissions::CoworkerAuthorizationDecision.new(
      request:, item: operation, user: owner
    ).call(decision: "approved")
    allow(Mcp::Sidecar).to receive(:chat_tools).and_return([ tool ])
    allow(tool).to receive(:call).and_call_original

    command = described_class.new(request)
    expect { command.execute }.not_to raise_error
    expect(operation.reload.authorized_invocation).to be_succeeded
    expect(tool).to have_received(:call).once

    expect { command.execute }.to raise_error(ArgumentError, /no longer available/)
    expect(tool).to have_received(:call).once
  end

  def approve_request!(req)
    operation = req.authorization_items.sole
    Permissions::CoworkerAuthorizationDecision.new(request: req, item: operation, user: owner)
      .call(decision: "approved")
    allow(Mcp::Sidecar).to receive(:chat_tools).and_return([ tool ])
  end

  it "stores the result and reuses it for an identical retry without a new pending action" do
    approve_request!(request)
    described_class.new(request).execute
    request.update!(state: "confirmed", confirmed_at: Time.current)
    expect(request.reload.payload["tool_result"]).to include("customers")

    retry_result = Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "customers" }, action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    ).call
    expect(retry_result.request).to be_nil
    expect(retry_result.reused_result).to eq(request.payload["tool_result"])
    expect(ChatPendingAction.where(deduplication_key: request.deduplication_key).count).to eq(1)
  end

  it "does not reuse a result for different arguments, after the window, or when rejected" do
    approve_request!(request)
    described_class.new(request).execute
    request.update!(state: "confirmed", confirmed_at: Time.current)

    other = Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "payments" }, action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "payments" } }
    ).call
    expect(other.reused_result).to be_nil
    expect(other.request).to be_present

    request.update_columns(confirmed_at: (Permissions::CoworkerAuthorizationRequest::RESULT_REUSE_WINDOW + 1.minute).ago)
    expired = Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "customers" }, action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    ).call
    expect(expired.reused_result).to be_nil

    request.update_columns(confirmed_at: Time.current, state: "rejected")
    rejected = Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "customers" }, action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    ).call
    expect(rejected.reused_result).to be_nil
  end

  it "fails explicitly instead of succeeding with an empty result" do
    approve_request!(request)
    allow(tool).to receive(:call).and_return(MCP::Tool::Response.new([ { type: "text", text: "" } ]))

    expect { described_class.new(request).execute }.to raise_error(ArgumentError, /no result to deliver/)
    expect(request.authorization_items.sole.authorized_invocation).to be_failed
  end

  it "fails explicitly when the originating conversation is gone" do
    approve_request!(request)
    command = described_class.new(request)
    allow(command).to receive(:chat_session).and_return(nil)

    expect { command.execute }.to raise_error(ArgumentError, /originating conversation/)
  end
end
