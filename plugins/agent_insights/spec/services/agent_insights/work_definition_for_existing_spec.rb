require "rails_helper"

# A disabled (or unhealthy) plugin withdraws its kinds from the registry, so new
# insight sweeps cannot launch, but an existing sweep's Workflow must still
# resolve this plugin's definition to be finished or cancelled (NY14).
RSpec.describe AgentInsights::WorkDefinition, "after the plugin is disabled" do
  it "is still the definition WorkDefinitions resolves for existing rows" do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: false, disableable: true)

    expect { WorkDefinitions.for("agent_insight") }.to raise_error(WorkDefinitions::UnknownKind)
    expect(WorkDefinitions.for_existing("agent_insight")).to be_a(described_class)
  end
end
