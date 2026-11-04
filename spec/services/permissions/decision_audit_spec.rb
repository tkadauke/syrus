require "rails_helper"

RSpec.describe Permissions::DecisionAudit do
  let(:user) { Factories.user }
  let(:descriptor) do
    Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: "read_visible_context", capability: "knowledge.read",
      mutation: false, required_roles: [ AgentRole::CHAT_LOCAL ]
    )
  end

  it "records the enforced policy with actor and invocation identity and no arguments" do
    decision = Permissions::PolicyEvaluator.new(
      descriptor:, role: AgentRole::CHAT_LOCAL, resource_scope: {},
      arguments: { path: "secret.txt" }
    ).call
    allow(OperationalLogging).to receive(:ingest)

    described_class.record(
      decision:, effective_policy: :ask, actor: user,
      context: { role: AgentRole::CHAT_LOCAL, chat_session_id: 12 }, fingerprint: "fingerprint"
    )

    expect(OperationalLogging).to have_received(:ingest).with(hash_including(
      source: described_class::LOG_SOURCE,
      context: hash_including(
        policy: decision.policy, effective_policy: :ask,
        actor_type: "User", actor_id: user.id,
        invocation_fingerprint: "fingerprint", chat_session_id: 12
      )
    ))
    expect(OperationalLogging).not_to have_received(:ingest).with(hash_including(context: hash_including(path: "secret.txt")))
  end

  it "never changes authorization when diagnostics cannot be persisted" do
    decision = Permissions::PolicyEvaluator.new(
      descriptor:, role: AgentRole::CHAT_LOCAL, resource_scope: {}, arguments: {}
    ).call
    allow(OperationalLogging).to receive(:ingest).and_raise("logging unavailable")

    expect { described_class.record(decision:, actor: user) }.not_to raise_error
  end
end
