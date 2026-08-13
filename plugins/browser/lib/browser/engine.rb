module SyrusBrowser
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) and app/services/syrus_browser
    # (autoloaded from this engine's own app/ dir) are resolvable.
    config.after_initialize do
      SyrusBrowser::McpToolSet.include(Syrus::Plugin::McpToolSet)

      Syrus::PluginRegistry.register(
        name:            "browser",
        display_name:    "Browser (Playwright)",
        version:         SyrusBrowser::VERSION,
        description:     "Headless Chromium browser control for workflow agents, via a bundled " \
                          "@playwright/mcp stdio subprocess. Navigation is hard-restricted to " \
                          "127.0.0.1/loopback URLs — the browser can only drive a step's own " \
                          "in-step preview, never an arbitrary network destination.",
        homepage:        "https://github.com/tkadauke/syrus",
        default_enabled: true,
        disableable:     true,
        category:        "mcp_tool_set",
        provides: {
          mcp_tool_set: SyrusBrowser::McpToolSet
        }
      )
    end
  end
end
