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
    expect(workflow_tool_sets).to include(SyrusBrowser::McpToolSet)
  end

  it "registers SyrusBrowser::ImageDiffRenderer as the :artifact_renderer provider" do
    expect(surface_implementations(:artifact_renderers)).to include(SyrusBrowser::ImageDiffRenderer)
  end

  it "registers SyrusBrowser::ChatToolSet as the :chat_mcp_tool_set provider" do
    expect(chat_tool_sets).to include(SyrusBrowser::ChatToolSet)
  end

  it "registers SyrusBrowser::RuntimeSessionProvider as the :runtime_session_provider provider" do
    expect(Syrus::PluginRegistry.providers_for(:runtime_session_provider)).to include(SyrusBrowser::RuntimeSessionProvider)
  end

  it "registers the scoped permission provider" do
    expect(permission_providers).to include(SyrusBrowser::PermissionProvider)
  end

  it "owns visual review workflow kinds and the judge contribution" do
    expect(Syrus::PluginRegistry.providers_for(:workflow_kinds)).to include(SyrusBrowser::WorkflowKinds)
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:judge"))
      .to include([ "browser", SyrusBrowser::WorkflowJudge ])
    expect(Step::Kind.fetch("visual_review").handler_class).to eq(SyrusBrowser::VisualReviewStep)
  end

  it "owns visual review workflow kinds and the judge contribution" do
    expect(Syrus::PluginRegistry.providers_for(:workflow_kinds)).to include(SyrusBrowser::WorkflowKinds)
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:judge"))
      .to include([ "browser", SyrusBrowser::WorkflowJudge ])
    expect(Step::Kind.fetch("visual_review").handler_class).to eq(SyrusBrowser::VisualReviewStep)
  end

  it "owns visual review workflow kinds and the judge contribution" do
    expect(Syrus::PluginRegistry.providers_for(:workflow_kinds)).to include(SyrusBrowser::WorkflowKinds)
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:judge"))
      .to include([ "browser", SyrusBrowser::WorkflowJudge ])
    expect(Step::Kind.fetch("visual_review").handler_class).to eq(SyrusBrowser::VisualReviewStep)
  end

  it "registers a manifest named 'browser'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "browser" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
    expect(SyrusBrowser.syrus_plugin_definition.frontend[:i18n]).to eq([ "app/frontend/i18n/locales/*/browser.json" ])
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
    expect(workflow_tool_sets).to include(SyrusBrowser::McpToolSet)
    expect(chat_tool_sets).to include(SyrusBrowser::ChatToolSet)
    expect(surface_implementations(:artifact_renderers)).to include(SyrusBrowser::ImageDiffRenderer)
    expect(Syrus::PluginRegistry.providers_for(:runtime_session_provider)).to include(SyrusBrowser::RuntimeSessionProvider)
  end

  it "includes the RuntimeSessionProvider plugin interface module" do
    expect(SyrusBrowser::RuntimeSessionProvider.ancestors).to include(Syrus::Plugin::RuntimeSessionProvider)
  end
end
