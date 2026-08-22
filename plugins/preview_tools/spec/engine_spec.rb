require "rails_helper"

RSpec.describe PreviewTools::Engine do
  # The after_initialize block already ran during Rails boot and was then
  # reset by config/initializers/plugin_registry.rb in test mode.
  # spec/support/bundled_plugins.rb re-registers before each example; we
  # only need to verify the result is observable here.

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers PreviewTools::ChatToolSet as the :chat_mcp_tool_set provider" do
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(PreviewTools::ChatToolSet)
  end

  it "registers a manifest named 'preview_tools'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "preview_tools" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(PreviewTools::VERSION)
  end

  it "includes the ChatMcpToolSet plugin interface module" do
    expect(PreviewTools::ChatToolSet.ancestors).to include(Syrus::Plugin::ChatMcpToolSet)
  end
end
