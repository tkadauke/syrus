require "rails_helper"

RSpec.describe DesignDocs::PermissionProvider do
  it "covers the complete read and collaboration inventory with explicit semantics" do
    definitions = DesignDocs::ChatToolSet.tool_definitions(tier: :deferred) + DesignDocs::WorkflowToolSet.tool_definitions

    expect(definitions.map { |definition| definition.fetch(:name) }.uniq).to match_array(described_class::OPERATIONS.keys)
    expect(definitions).to all(include(capability_descriptor: be_a(Permissions::CapabilityDescriptor)))
    definitions.each do |definition|
      descriptor = definition.fetch(:capability_descriptor)

      expect(descriptor.classify({})).to include(
        operation: descriptor.operation,
        effects: descriptor.effects,
        risk: descriptor.risk,
        confidence: :certain
      )
    end
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("read_design_doc")).effects).to eq([ :confidential_read ])
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("delete_design_doc")).effects).to include(:destructive)
  end
end
