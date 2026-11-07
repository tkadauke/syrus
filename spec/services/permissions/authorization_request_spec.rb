require "rails_helper"

RSpec.describe Permissions::AuthorizationRequest do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user:, title: "Authorization") }
  let(:context) { McpToolContext.from_chat_session(chat) }
  let(:arguments) { { "document_id" => 42, "token" => "secret-token" } }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "documents.write@v1", operation: "documents.write/update@v1",
      effects: [ :internal_write ], risk: :medium,
      requestable_roles: [ AgentRole::CHAT_PLANNER ], defaults: { AgentRole::CHAT_PLANNER => :ask },
      maximum_autonomy: :invocation, authority_durations: [ :invocation ],
      resource_scope: { type: :none }, classifier: ->(*) { {} },
      fingerprint_normalizer: ->(value) { value },
      redactor: ->(value) { value.merge("token" => ToolPayloadRedactor::REDACTED) }
    )
  end

  it "preserves the historical empty scope unless the descriptor derives one" do
    request = described_class.new(context:, descriptor:, arguments:).call.request
    item = request.authorization_items.sole

    expect(item.resource_scope).to eq({})
    expect(item.normalized_arguments).to eq(arguments.merge("token" => ToolPayloadRedactor::REDACTED))
  end

  it "uses only a descriptor's explicit scope derivation" do
    scoped = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(
      resource_scope_resolver: ->(value) { { "document_id" => value.fetch("document_id") } }
    ))

    item = described_class.new(context:, descriptor: scoped, arguments:).call.request.authorization_items.sole

    expect(item.resource_scope).to eq("document_id" => 42)
    expect(item.resource_scope).not_to include("token")
  end
end
