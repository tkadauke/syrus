require "rails_helper"

RSpec.describe AgentActivity::Engine do
  it "is registered enabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "agent_activity" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(true)
    expect(manifest.enabled?).to be(true)
    expect(manifest.metadata[:frontend]).to eq(
      routes: {
        "agent_activity/AgentActivity" => "app/frontend/routes/AgentActivity.tsx",
        "agent_activity/AdminAgentActivity" => "app/frontend/routes/AdminAgentActivity.tsx"
      },
      i18n: [ "app/frontend/i18n/locales/*/agent_activity.json" ]
    )
  end

  it "registers the Agent Activity sidebar page provider" do
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).to include(AgentActivity::SidebarPages)
  end

  it "registers the agent_activity filter subject while enabled" do
    subject = Filters.subject(:agent_activity)

    expect(subject.model).to eq(Run)
    expect(subject.chips).to eq(AgentActivity::FILTER_CHIPS)
    expect(subject.chip_class("repository_id")).to eq(Filters::Chips::AgentActivity::RepositoryId)
  end

  it "retires the filter subject when the plugin is disabled" do
    expect(Filters.subjects).to have_key(:agent_activity)

    PluginRecord.find_by!(name: "agent_activity").update!(enabled: false)

    expect(Filters.subjects).not_to have_key(:agent_activity)
  ensure
    PluginRecord.find_by!(name: "agent_activity").update!(enabled: true)
  end
end
