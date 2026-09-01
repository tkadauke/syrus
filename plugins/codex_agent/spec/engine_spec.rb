require "rails_helper"

RSpec.describe SyrusCodexAgent::Engine do
  # The after_initialize block already ran during Rails boot and was then
  # reset by config/initializers/plugin_registry.rb in test mode.
  # The bundled_plugins support file re-registers before each example;
  # we only need to verify the result is observable here.

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers Codex providers via after_initialize" do
    # bundled_plugins.rb ensures the registry is populated before this runs
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to include(AgentProviders::Codex)
    expect(Syrus::PluginRegistry.providers_for(:chat_provider)).to include(ChatProviders::Codex)
    expect(ChatSessionRehydrator.for("codex")).to eq(ChatSessionRehydrator::Codex)
  end

  it "registers Codex-owned CredentialProbe and admin user filter extensions" do
    expect(CredentialProbe.probe_handler_for("codex_api_key")).to eq(CodexCredentialProbe)
    expect(CredentialProbe.probe_handler_for("codex_auth_json")).to eq(CodexCredentialProbe)
    expect(Filters::Registry.find("has_codex_token", subject: :admin_user)).to eq(Filters::Chips::AdminUsers::HasCodexToken)
  end

  it "registers a manifest named 'codex_agent'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "codex_agent" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(SyrusCodexAgent::VERSION)
  end
end
