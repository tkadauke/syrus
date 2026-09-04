module PreviewTools
  class Engine < ::Rails::Engine
    # to_prepare, not after_initialize: lib/ is autoloaded and therefore
    # reloadable, so Syrus::PluginRegistry is replaced by an empty one on every
    # code reload. after_initialize runs once per boot and would never put the
    # registrations back.  Registration is idempotent by name.
    config.to_prepare do
      PreviewTools::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless PreviewTools::ChatToolSet < Syrus::Plugin::ChatMcpToolSet

      Syrus::PluginRegistry.register(
        name:            "preview_tools",
        display_name:    "Preview Tools",
        version:         PreviewTools::VERSION,
        description:     "Scratch-directory-scoped write/edit tools plus show_preview/close_preview " \
                          "so planning-mode chat agents can build and preview an HTML/CSS/JS mockup " \
                          "or interactive widget without ever touching the attached repository checkout.",
        long_description: "Preview Tools gives planning-mode chat agents a safe scratch area for building lightweight HTML, CSS, and JavaScript previews. The tools are scoped away from repository checkouts, so agents can mock up ideas and show interactive artifacts without modifying project code.\n\nUse this plugin when chat should support exploratory UI sketches before a real job is filed. It is intentionally separate from repository preview providers, which run actual application code from workflow workspaces.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/preview_tools.svg",
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
