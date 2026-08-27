module ThemingTools
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) and app/services/theming_tools
    # (autoloaded from this engine's own app/ dir) are resolvable.
    config.after_initialize do
      ThemingTools::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless ThemingTools::ChatToolSet < Syrus::Plugin::ChatMcpToolSet

      Syrus::PluginRegistry.register(
        name:            "theming_tools",
        display_name:    "Theming Tools",
        version:         ThemingTools::VERSION,
        description:     "Gives the Syrus Chat agent a preview_theme tool to draft a candidate color theme " \
                          "and show it to the user against the real Style Guide page. Experimental and off " \
                          "by default -- install_theme and full theme CRUD land in a follow-up plugin update.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "mcp_tool_set",
        provides: {
          chat_mcp_tool_set: ThemingTools::ChatToolSet
        }
      )
    end
  end
end
