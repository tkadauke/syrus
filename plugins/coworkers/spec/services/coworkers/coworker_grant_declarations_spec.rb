require "rails_helper"

RSpec.describe "coworker grant declarations" do
  it "covers every coworker tool with a declared grant or an explicit grantless decision" do
    catalog = Coworkers::GrantCatalog.all.index_by(&:name)
    core_missing = McpToolRegistry.entries(surface: :coworker).reject do |entry|
      catalog[entry.capability.to_s]&.tools&.include?(entry.tool_name)
    end
    plugin_missing = Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).flat_map do |tool_set|
      Array(tool_set.tool_definitions(tier: nil)).select do |definition|
        safe = definition[:coworker_safe] || definition["coworker_safe"]
        grantless = definition[:coworker_grantless] || definition["coworker_grantless"]
        capability = definition[:capability] || definition["capability"]
        safe && !grantless && !catalog[capability.to_s]&.tools&.include?((definition[:name] || definition["name"]).to_s)
      end
    end

    expect(core_missing).to be_empty
    expect(plugin_missing).to be_empty
  end

  it "offers plugin specs a reusable declaration assertion" do
    expect_coworker_grants_declared(Coworkers::ChatToolSet)
  end
end
