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
        description:     "Gives the Syrus Chat agent tools to draft, preview, install, and manage custom color " \
                          "themes: preview_theme shows a candidate theme against the real Style Guide page, " \
                          "install_theme persists one as the user's active theme (with a WCAG AA contrast " \
                          "check), and list_user_themes/update_user_theme/delete_user_theme manage the user's " \
                          "own custom themes. Experimental and off by default.",
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
