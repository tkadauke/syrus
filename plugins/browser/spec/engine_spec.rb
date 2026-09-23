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

  it "registers SyrusBrowser::ImageDiffRenderer as the :artifact_renderer provider" do
    expect(Syrus::PluginRegistry.providers_for(:artifact_renderer)).to include(SyrusBrowser::ImageDiffRenderer)
  end

  it "registers SyrusBrowser::ChatToolSet as the :chat_mcp_tool_set provider" do
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(SyrusBrowser::ChatToolSet)
  end

  it "registers SyrusBrowser::RuntimeSessionProvider as the :runtime_session_provider provider" do
    expect(Syrus::PluginRegistry.providers_for(:runtime_session_provider)).to include(SyrusBrowser::RuntimeSessionProvider)
  end

  it "registers a manifest named 'browser'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "browser" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
  end

  it "stays healthy, with every provider intact, while plugin_runtime is disabled" do
    # plugin_runtime is default_enabled: false, so this is the state a fresh
    # install boots into. Browser must only optionally_depends_on it -- a hard
    # depends_on here would mark Browser :degraded (PluginHealth) and withhold
    # every provider below, not just the service acceleration, breaking
    # visual_review and Coding Mode browser tools out of the box. See
    # docs/syrus_docs/browser.md's Operations section.
    expect(PluginRecord.find_by(name: "plugin_runtime")&.enabled?).to be_falsy
    expect(Syrus::PluginRegistry.health.healthy?("browser")).to be(true)
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).to include(SyrusBrowser::McpToolSet)
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(SyrusBrowser::ChatToolSet)
    expect(Syrus::PluginRegistry.providers_for(:artifact_renderer)).to include(SyrusBrowser::ImageDiffRenderer)
    expect(Syrus::PluginRegistry.providers_for(:runtime_session_provider)).to include(SyrusBrowser::RuntimeSessionProvider)
  end

  it "includes the McpToolSet plugin interface module" do
    expect(SyrusBrowser::McpToolSet.ancestors).to include(Syrus::Plugin::McpToolSet)
  end

  it "includes the ArtifactRenderer plugin interface module" do
    expect(SyrusBrowser::ImageDiffRenderer.ancestors).to include(Syrus::Plugin::ArtifactRenderer)
  end

  it "includes the ChatMcpToolSet plugin interface module" do
    expect(SyrusBrowser::ChatToolSet.ancestors).to include(Syrus::Plugin::ChatMcpToolSet)
  end

  it "includes the RuntimeSessionProvider plugin interface module" do
    expect(SyrusBrowser::RuntimeSessionProvider.ancestors).to include(Syrus::Plugin::RuntimeSessionProvider)
  end
end
