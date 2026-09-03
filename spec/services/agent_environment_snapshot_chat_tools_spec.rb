require "rails_helper"

RSpec.describe AgentEnvironmentSnapshot, ".chat_tool_groups_for" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def advertised_for(session) = described_class.chat_tool_groups_for(session).values.flatten

  it "advertises only tools the chat can actually call" do
    available = %i[essential deferred].flat_map { |tier| Mcp::Sidecar.chat_tool_names(chat_session, tier: tier) }

    expect(advertised_for(chat_session)).not_to be_empty
    expect(available).to include(*advertised_for(chat_session))
  end

  it "drops a tool from its group when the chat cannot call it" do
    all_names = described_class::CHAT_TOOL_GROUPS.values.flatten
    withheld = all_names.first
    allow(Mcp::Sidecar).to receive(:chat_tool_names).and_return(all_names - [ withheld ])

    expect(advertised_for(chat_session)).not_to include(withheld)
    expect(advertised_for(chat_session)).to include(*(all_names - [ withheld ]))
  end

  # The point of the filter is that an uninstalled or disabled plugin stops
  # being advertised, so this drives it through a real one -- discovered from
  # the registry rather than named, since naming it would make that plugin
  # undeletable.
  it "stops advertising a plugin's tools once the plugin is disabled" do
    group_names = described_class::CHAT_TOOL_GROUPS.values.flatten.to_set
    plugin, tool_names = Syrus::PluginRegistry.all_plugins.filter_map { |manifest|
      next unless manifest.disableable?

      tool_set = manifest.provides[:chat_mcp_tool_set]
      next if tool_set.nil?

      names = %i[essential deferred].flat_map { |tier| tool_set.tool_definitions(tier: tier).map { |defn| defn[:name] } }
                                    .uniq.select { |name| group_names.include?(name) }
      [ manifest.name, names ] if names.any?
    }.first

    skip("no installed plugin contributes a chat tool named in CHAT_TOOL_GROUPS") if plugin.nil?

    PluginRecord.find_or_create_by!(name: plugin).update!(enabled: true, disableable: true)
    expect(advertised_for(chat_session)).to include(*tool_names)

    PluginRecord.find_by!(name: plugin).update!(enabled: false)

    expect(advertised_for(chat_session)).not_to include(*tool_names)
  end

  it "falls back to the full group list when there is no chat session to resolve against" do
    expect(described_class.chat_tool_groups_for(nil)).to eq(described_class::CHAT_TOOL_GROUPS)
  end
end
