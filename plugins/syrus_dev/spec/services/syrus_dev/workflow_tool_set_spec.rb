require "rails_helper"

RSpec.describe SyrusDev::WorkflowToolSet do
  it "maps every workflow inventory to an explicit permission-provider descriptor" do
    definitions = described_class.tool_definitions

    expect(definitions.to_h { |definition|
      [ definition.fetch(:name), definition.fetch(:capability_descriptor).operation ]
    }).to eq(
      "read_performance_diagnostics" => "syrus_dev.performance/read@v1",
      "read_syrus_logs" => "syrus_dev.logs/search@v1",
      "read_workspace_reuse_outcomes" => "syrus_dev.workspace_reuse/read@v1"
    )
    expect(definitions.map { |definition| definition.fetch(:capability_descriptor) })
      .to all(satisfy { |descriptor| described_class::OPERATIONS.value?(descriptor.operation) })
  end

  it "keeps the agent-insight inventory independently described" do
    context = instance_double(McpToolContext, role: AgentRole::AGENT_INSIGHT)

    expect(described_class.tool_definitions(context:).map { |definition|
      [ definition.fetch(:name), definition.fetch(:capability_descriptor).operation ]
    }).to eq([ [ "read_syrus_logs", "syrus_dev.logs/search@v1" ] ])
  end
end
