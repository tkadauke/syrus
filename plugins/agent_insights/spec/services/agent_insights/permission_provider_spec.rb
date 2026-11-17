require "rails_helper"

RSpec.describe AgentInsights::PermissionProvider do
  it "covers the complete investigation inventory and asks before mutations" do
    definitions = AgentInsights::McpToolSet.tool_definitions + AgentInsights::ChatToolSet.tool_definitions(tier: :deferred)

    expect(definitions.map { |definition| definition.fetch(:name) }.uniq).to match_array(described_class::OPERATIONS.keys)
    expect(definitions).to all(include(capability_descriptor: be_a(Permissions::CapabilityDescriptor)))
    described_class::MUTATIONS.each do |name|
      expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch(name)).defaults.values.uniq).to eq([ :ask ])
    end
  end
end
