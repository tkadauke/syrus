require "rails_helper"

RSpec.describe Permissions::CoworkerAuthorizationDecision do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
  end
  let(:request) do
    chat.pending_actions.create!(
      request_kind: "authorization_request", action: "coworker_tool_call",
      requested_by: "agent", origin: chat, subject: coworker,
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    )
  end
  let(:possession) do
    request.authorization_items.create!(
      kind: "capability_possession", capability: "custom.read", capability_version: 1,
      resource_type: "none", resource_scope: {}, normalized_arguments: {}, effects: [],
      policy_chain: [], decisive_rule: {}, requested_durations: []
    )
  end
  let(:operation) do
    request.authorization_items.create!(
      kind: "operation", capability: "custom.read", capability_version: 1,
      operation: "custom.read/read_custom_data", operation_version: 1,
      resource_type: "none", resource_scope: {}, normalized_arguments: { "query" => "customers" },
      invocation_fingerprint: "sha256:customers", effects: [], policy_chain: [], decisive_rule: {},
      requested_durations: [ "invocation" ]
    ).tap { |item| item.prerequisites << possession }
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    descriptor = instance_double(Coworkers::GrantCatalog::Descriptor, scopeable?: false, valid_scope?: true)
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("custom.read").and_return(descriptor)
    operation
  end

  it "records possession and waits for the exact invocation decision" do
    result = described_class.new(request:, item: possession, user: owner).call(decision: "approved")

    expect(result.execution_enqueued).to be(false)
    expect(possession.reload).to be_approved
    expect(possession.resulting_authority).to eq(coworker.grants.find_by!(capability: "custom.read"))
    expect(request.reload).to be_pending
  end

  it "enqueues execution only after every prerequisite is approved" do
    described_class.new(request:, item: possession, user: owner).call(decision: "approved")

    expect {
      result = described_class.new(request:, item: operation, user: owner).call(decision: "approved")
      expect(result.execution_enqueued).to be(true)
    }.to have_enqueued_job(ChatPendingActionConfirmationJob).with(request.id)
    expect(request.reload).to be_confirming
  end

  it "denies one item and makes the remaining prerequisite non-actionable" do
    described_class.new(request:, item: possession, user: owner).call(decision: "denied")

    expect(possession.reload).to be_denied
    expect(operation.reload).to be_non_actionable
    expect(request.reload).to be_rejected
  end
end
