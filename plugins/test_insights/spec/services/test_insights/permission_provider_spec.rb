require "rails_helper"

RSpec.describe TestInsights::PermissionProvider do
  it "attaches explicit low-risk evidence descriptors to every tool on both surfaces" do
    definitions = TestInsights::McpToolSet.tool_definitions + TestInsights::ChatToolSet.tool_definitions(tier: :deferred)

    expect(definitions.map { |definition| definition.fetch(:name) }.uniq).to match_array(described_class::OPERATIONS.keys)
    expect(definitions).to all(include(capability_descriptor: be_a(Permissions::CapabilityDescriptor)))
    expect(definitions.map { |definition| definition.fetch(:capability_descriptor).effects }.uniq).to eq([ [ :local_read ] ])
  end
end
