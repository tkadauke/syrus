require "rails_helper"

RSpec.describe Permissions::RequestPresentation do
  let(:user) { Factories.user }

  def build_request
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, origin: user, subject: user, deduplication_key: "presentation-spec")
    request.authorization_items.create!(
      kind: "operation", capability: "syrus.communication@v1", capability_version: 1,
      operation: "syrus.communication/send_chat_message@v1", operation_version: 1, resource_type: "none",
      resource_scope: {}, normalized_arguments: {}, invocation_fingerprint: "fp", effects: [ "communication" ],
      policy_chain: [], decisive_rule: { "source" => "role_default" }, requested_durations: %w[invocation chat_session]
    )
    request
  end

  it "resolves the same human labels for the inbox serializer and the chat serializer path" do
    request = build_request
    inbox = Permissions::RequestPresenter.new(request, current_user: user).as_json
    chat = described_class.new(request, current_user: user)

    expect(inbox.dig(:items, 0, :presentation)).to eq(chat.item_json(request.authorization_items.first))
    expect(inbox.fetch(:presentation)).to eq(chat.as_json)
    expect(chat.as_json).to include(statement: "Send a message to another chat", consequences: [ "send a message" ],
      requested_durations: [ "This one time", "This chat" ])
  end

  it "falls back to effect-based wording instead of exposing raw keys, and omits blank context" do
    text = described_class.action_label(capability: "x.unknown@v1", operation: "x.unknown/do_it@v1", effects: [ "destructive" ])

    expect(text).to eq("Take an action that may delete or overwrite data")
    expect(described_class.action_label(capability: "x@v1", operation: nil, effects: [])).to eq("Take an action on your behalf")
    expect(described_class.new(build_request, current_user: user).as_json).not_to have_key(:scope)
  end
end
