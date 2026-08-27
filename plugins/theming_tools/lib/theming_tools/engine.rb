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
        long_description: "Theming Tools gives the Syrus Chat agent a preview_theme tool: it can draft a " \
                          "candidate color theme and pop it open for the user against the real Style Guide " \
                          "page, so token choices are judged on actual Button/Input/Card components instead " \
                          "of a recreated mockup.\n\nThe underlying Theme model stays in core (same precedent " \
                          "as WhiteboardSnapshot for whiteboard_tools) -- this plugin only owns the tool " \
                          "surface and the broadcast wiring that opens the preview.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/theming_tools.svg",
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
