require "rails_helper"

RSpec.describe Permissions::CoworkerCapabilityDiscovery do
  let(:user) { Factories.user }
  let(:context) do
    McpToolContext.new(
      surface: :chat,
      role: AgentRole::COWORKER_CHAT,
      user: user,
      allowed_repository_ids: [ 123 ],
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

  def registry_entry(descriptor)
    double(descriptor: descriptor, feature_flag: nil, feature_flags_by_role: nil)
  end

  before do
    allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return([ catalog_descriptor ])
  end

  it "reports an eligible ungranted family as requestable with scope, policy, and lock reason" do
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor))

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
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor(roles: [ AgentRole::CHAT_PLANNER ])))

    expect(described_class.new(context).call).to be_empty
    expect(described_class.new(context).call(include_non_requestable: true).sole.to_h).to include(
      state: "prohibited", lock_reason: "role_not_eligible"
    )
  end

  it "reports an effective deny separately from role ineligibility" do
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor(policy: :deny)))

    expect(described_class.new(context).call(include_non_requestable: true).sole.to_h).to include(
      state: "prohibited", lock_reason: "effective_policy_denies"
    )
  end

  {
    plugin_disabled: "provider_plugin_disabled",
    resource_unconfigured: "required_resource_unconfigured",
    unavailable: "provider_unavailable"
  }.each do |availability, reason|
    it "preserves the #{availability} state" do
      unavailable_descriptor = catalog_descriptor.with(availability_state: availability)
      allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return([ unavailable_descriptor ])
      allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor))

      expect(described_class.new(context).call(include_non_requestable: true).sole.to_h).to include(
        state: availability.to_s, lock_reason: reason
      )
    end
  end

  it "matches queries against tool names and descriptions" do
    searchable = catalog_descriptor.with(description: "Reads customer ledgers")
    allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return([ searchable ])
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor))

    expect(described_class.new(context).call(query: "read_example")).not_to be_empty
    expect(described_class.new(context).call(query: "customer ledgers")).not_to be_empty
  end

  it "constructs permission management only once for a multi-operation family" do
    other_tool = Class.new(MCP::Tool) { tool_name "list_examples" }
    other_catalog_descriptor = catalog_descriptor.with(tool_name: "list_examples", tool: other_tool)
    allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return([ catalog_descriptor, other_catalog_descriptor ])
    allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor))
    allow(McpToolRegistry).to receive(:entry_for).with(other_tool).and_return(registry_entry(permission_descriptor))
    management = instance_double(Permissions::Management)
    allow(Permissions::Management).to receive(:new).with(user).and_return(management)
    allow(management).to receive(:explain).and_return(double(policy: :ask))

    described_class.new(context).call

    expect(Permissions::Management).to have_received(:new).once
  end

  context "when the family is already granted" do
    let(:granted_capabilities) { [ "example.records" ] }

    it "keeps it out of requestable discovery and labels it available in explicit discovery" do
      allow(McpToolRegistry).to receive(:entry_for).with(tool).and_return(registry_entry(permission_descriptor))

      expect(described_class.new(context).call).to be_empty
      expect(described_class.new(context).call(include_non_requestable: true).sole.state).to eq("available")
    end
  end
end
