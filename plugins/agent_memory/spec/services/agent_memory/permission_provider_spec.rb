require "rails_helper"

RSpec.describe AgentMemory::PermissionProvider do
  it "covers memory reads, sharing, audit, and destructive deletion explicitly" do
    definitions = AgentMemory::McpToolSet.tool_definitions + AgentMemory::ChatToolSet.tool_definitions(tier: nil)

    expect(definitions.map { |definition| definition.fetch(:name) }.uniq).to match_array(described_class::OPERATIONS.keys)
    expect(definitions).to all(include(capability_descriptor: be_a(Permissions::CapabilityDescriptor)))
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("admin_read_memory_audit_history")).effects).to eq([ :confidential_read ])
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("delete_memory")).effects).to include(:destructive)
  end
end
