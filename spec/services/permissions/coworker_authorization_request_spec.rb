require "rails_helper"

RSpec.describe Permissions::CoworkerAuthorizationRequest do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:arguments) { { "query" => "select * from customers", "password" => "secret" } }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "database.read@v1", operation: "database.read/query@v2",
      effects: [ :confidential_read ], risk: :medium,
      requestable_roles: [ AgentRole::COWORKER_CHAT ],
      defaults: { AgentRole::COWORKER_CHAT => :ask },
      maximum_autonomy: :job, authority_durations: [ :invocation, :job ],
      resource_scope: { type: :none },
      classifier: ->(*) { { operation: "database.read/query@v2", effects: [ :confidential_read ], confidence: :high } },
      fingerprint_normalizer: ->(value) { value },
      redactor: ->(value) { value.merge("password" => "[REDACTED]") }
    )
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    assigned_coworker = coworker
    chat.define_singleton_method(:coworker) { assigned_coworker }
  end

  def context(granted: [])
    McpToolContext.new(
      surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
      repository:, chat_session: chat, agent_actor: coworker,
      granted_capabilities: granted
    )
  end

  it "creates one compound request for named-agent possession and the exact invocation" do
    result = described_class.new(context: context, descriptor:, arguments:).call
    request = result.request
    possession, operation = request.authorization_items.order(:id).to_a

    expect(request).to have_attributes(
      request_kind: "authorization_request", subject: coworker, origin: chat,
      runtime_role: AgentRole::COWORKER_CHAT
    )
    expect(possession).to have_attributes(
      kind: "capability_possession", capability: "database.read",
      capability_version: 1, requested_durations: [ "job" ]
    )
    expect(operation).to have_attributes(
      kind: "operation", operation: "database.read/query", operation_version: 2,
      requested_durations: [ "invocation" ], effects: [ "confidential_read" ],
      normalized_arguments: arguments.merge("password" => "[REDACTED]")
    )
    expect(operation.invocation_fingerprint).to eq(
      Permissions::InvocationFingerprint.call(descriptor:, arguments:)
    )
    expect(operation.prerequisites).to contain_exactly(possession)
  end

  it "reuses an equivalent active request instead of interrupting twice" do
    first = described_class.new(context: context, descriptor:, arguments:).call.request
    second = described_class.new(context: context, descriptor:, arguments:).call.request

    expect(second).to eq(first)
    expect(ChatPendingAction.where(request_kind: "authorization_request").count).to eq(1)
    expect(first.authorization_items.count).to eq(2)
  end

  it "requests only exact invocation approval when the named agent already possesses the family" do
    request = described_class.new(
      context: context(granted: [ "database.read" ]), descriptor:, arguments:
    ).call.request

    expect(request.authorization_items.sole).to have_attributes(
      kind: "operation", requested_durations: [ "invocation" ]
    )
  end

  it "fails closed without creating a request when effective policy denies the operation" do
    denied = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(
      defaults: { AgentRole::COWORKER_CHAT => :deny }
    ))

    expect {
      described_class.new(context: context, descriptor: denied, arguments:).call
    }.to raise_error(Mcp::Tools::AuthorizationSupport::AuthorizationError, /denies/)
      .and change(ChatPendingAction, :count).by(0)
  end
end
