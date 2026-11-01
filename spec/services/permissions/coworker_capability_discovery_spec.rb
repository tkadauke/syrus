require "rails_helper"

RSpec.describe Permissions::CoworkerCapabilityDiscovery do
  let(:user) { Factories.user }
  let(:context) do
    McpToolContext.new(
      surface: :chat,
      role: AgentRole::COWORKER_CHAT,
      user: user,
      granted_capabilities: granted_capabilities
    )
  end
  let(:granted_capabilities) { [] }
  let(:tool) { Class.new(MCP::Tool) { tool_name "read_example" } }
  let(:catalog_descriptor) do
    Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_example", capability: "example.records", ungated: false,
      tier: :essential, tool: tool, provider: nil
    )
  end

  def permission_descriptor(roles: [ AgentRole::COWORKER_CHAT ], policy: :ask)
    Permissions::CapabilityDescriptor.new(
      capability: "example.records@v1", operation: "example.records/read@v1",
      effects: [ :confidential_read ], risk: :medium,
      requestable_roles: roles, defaults: roles.index_with { policy },
      maximum_autonomy: :job, authority_durations: [ :invocation, :job ],
      resource_scope: { type: :repository, options: { required: [ :repository_id ] } },
      classifier: ->(*) { {} }, fingerprint_normalizer: ->(value) { value }, redactor: ->(value) { value }
    )
  end

  before do
    allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return([ catalog_descriptor ])
  end

  it "reports an eligible ungranted family as requestable with scope, policy, and lock reason" do
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(double(descriptor: permission_descriptor))

    expect(described_class.new(context).call.map(&:to_h)).to contain_exactly(
      capability: "example.records",
      operations: [ "example.records/read@v1" ],
      required_scope: a_hash_including(type: :repository),
      effective_policy: "ask",
      state: "requestable",
      lock_reason: "capability_not_granted"
    )
  end

  it "does not collapse available and prohibited families into requestable results" do
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(double(descriptor: permission_descriptor(roles: [ AgentRole::CHAT_PLANNER ])))

    expect(described_class.new(context).call).to be_empty
    expect(described_class.new(context).call(include_non_requestable: true).sole.to_h).to include(
      state: "prohibited", lock_reason: "role_not_eligible"
    )
  end

  context "when the family is already granted" do
    let(:granted_capabilities) { [ "example.records" ] }

    it "keeps it out of requestable discovery and labels it available in explicit discovery" do
      allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(double(descriptor: permission_descriptor))

      expect(described_class.new(context).call).to be_empty
      expect(described_class.new(context).call(include_non_requestable: true).sole.state).to eq("available")
    end
  end
end
