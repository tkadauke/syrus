require "rails_helper"

RSpec.describe SyrusBrowser::Engine do
  # The after_initialize block already ran during Rails boot and was then
  # reset by config/initializers/plugin_registry.rb in test mode.
  # spec/support/bundled_plugins.rb re-registers before each example; we
  # only need to verify the result is observable here.

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers SyrusBrowser::McpToolSet as the :mcp_tool_set provider" do
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).to include(SyrusBrowser::McpToolSet)
  end

  it "registers a manifest named 'browser'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "browser" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(SyrusBrowser::VERSION)
  end

  it "includes the McpToolSet plugin interface module" do
    expect(SyrusBrowser::McpToolSet.ancestors).to include(Syrus::Plugin::McpToolSet)
  end
end
