require "rails_helper"

RSpec.describe AgentMemory::DataCleanup do
  let(:user) { Factories.user }

  it "removes a user's memories when the user is destroyed" do
    AgentMemory::Entry.create!(user: user, kind: "project_fact", scope: "global", content: "remembered")

    expect { user.destroy! }.to change(AgentMemory::Entry, :count).by(-1)
  end

  it "still cleans up while the plugin is disabled" do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: false, disableable: true)
    AgentMemory::Entry.create!(user: user, kind: "project_fact", scope: "global", content: "remembered")

    expect { user.destroy! }.to change(AgentMemory::Entry, :count).by(-1)
  end

  it "no longer declares an association on User" do
    expect(User.reflect_on_association(:agent_memories)).to be_nil
  end
end
