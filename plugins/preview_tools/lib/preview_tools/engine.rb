module PreviewTools
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) and app/services/preview_tools
    # (autoloaded from this engine's own app/ dir) are resolvable.
    config.after_initialize do
      PreviewTools::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless PreviewTools::ChatToolSet < Syrus::Plugin::ChatMcpToolSet

      Syrus::PluginRegistry.register(
        name:            "preview_tools",
        display_name:    "Preview Tools",
        version:         PreviewTools::VERSION,
        description:     "Scratch-directory-scoped write/edit tools plus show_preview/close_preview " \
                          "so planning-mode chat agents can build and preview an HTML/CSS/JS mockup " \
                          "or interactive widget without ever touching the attached repository checkout.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "mcp_tool_set",
        provides: {
          chat_mcp_tool_set: PreviewTools::ChatToolSet
        }
      )
    end
  end
end
