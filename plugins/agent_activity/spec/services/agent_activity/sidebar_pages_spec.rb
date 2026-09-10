require "rails_helper"

RSpec.describe AgentActivity::SidebarPages do
  let!(:seed_user) { Factories.user(admin: true) }
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  it "is empty when there is no current user" do
    expect(described_class.sidebar_pages).to eq([])
  end

  it "declares only the operator-scoped page for a non-admin" do
    Current.api_user = member

    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "agent_activity.mine",
        path: "/agent_activity",
        component: "agent_activity/AgentActivity",
        smart_folder_api_path: "/api/v1/app/agent_activity/sessions",
        smart_folder_subject: "agent_session"
      )
    )
  end

  it "declares only the operator-scoped page for an admin" do
    Current.api_user = admin

    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "agent_activity.mine",
        path: "/agent_activity",
        component: "agent_activity/AgentActivity",
        smart_folder_api_path: "/api/v1/app/agent_activity/sessions",
        smart_folder_subject: "agent_session"
      )
    )
  end

  it "is empty when the plugin is disabled" do
    PluginRecord.find_by!(name: "agent_activity").update!(enabled: false)
    Current.api_user = admin

    expect(described_class.sidebar_pages).to eq([])
  ensure
    PluginRecord.find_by!(name: "agent_activity").update!(enabled: true)
  end
end
