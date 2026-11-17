require "rails_helper"

RSpec.describe OperatorBriefing::PermissionProvider do
  it "covers every briefing evidence and report operation explicitly" do
    definitions = OperatorBriefing::McpToolSet.tool_definitions

    expect(definitions.map { |definition| definition.fetch(:name) }).to match_array(described_class::OPERATIONS.keys)
    expect(definitions).to all(include(capability_descriptor: be_a(Permissions::CapabilityDescriptor)))
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("read_briefing_git_diff")).effects).to eq([ :confidential_read ])
    expect(described_class.capability_descriptor(described_class::OPERATIONS.fetch("submit_dive_report")).defaults.values.uniq).to eq([ :ask ])
  end
end
