require "codex_agent/version"

module SyrusCodexAgent
  def self.register!
    unless Syrus::PluginRegistry.registered_names.include?("codex_agent")
      # No icon_url: no OpenAI/Codex mark is currently published through
      # Simple Icons (simpleicons.org) under a CC0-style license, so this
      # falls back to the SPQR eagle like any other plugin without a
      # sourced brand mark (see config/syrus_docs/plugins.md).
      Syrus::PluginRegistry.register(
        name:            "codex_agent",
        display_name:    "Codex Agent",
        version:         SyrusCodexAgent::VERSION,
        description:     "Runs workflow and chat turns through Codex.",
        long_description: "Codex Agent connects Syrus workflows and chats to Codex. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.\n\nEnable this plugin when a Syrus instance should offer Codex-backed automation. It is independent from the Claude plugin, so operators can run either provider or both.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/codex_agent.svg",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "agent",
        provides: {
          agent_provider: AgentProviders::Codex,
          chat_provider:  ChatProviders::Codex
        }
      )
    end

    Syrus::Installer.define("codex_agent:core_registries", plugin: "codex_agent") do |scope|
      scope.effect("api key probe") { CredentialProbe.register_probe("codex_api_key", CodexCredentialProbe) }
      scope.effect("auth json probe") { CredentialProbe.register_probe("codex_auth_json", CodexCredentialProbe) }
      scope.effect("secret extractor") { CredentialProbe.register_secret_extractor(CodexCredentialProbe::SECRET_EXTRACTOR) }
      scope.effect("chat session rehydrator") { ChatSessionRehydrator.register("codex", ChatSessionRehydrator::Codex) }
      scope.effect("admin user chips") do
        Filters.register_chips(
          subject: :admin_user,
          chips: { "has_codex_token" => "Filters::Chips::AdminUsers::HasCodexToken" }
        )
      end
    end
  end
end

require "codex_agent/engine"
