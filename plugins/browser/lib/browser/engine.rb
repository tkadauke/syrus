module SyrusBrowser
  class Engine < ::Rails::Engine
    # to_prepare, not after_initialize: lib/ is autoloaded and therefore
    # reloadable, so Syrus::PluginRegistry is replaced by an empty one on every
    # code reload. after_initialize runs once per boot and would never put the
    # registrations back.  Registration is idempotent by name.
    config.to_prepare do
      SyrusBrowser::McpToolSet.include(Syrus::Plugin::McpToolSet)
      SyrusBrowser::ImageDiffRenderer.include(Syrus::Plugin::ArtifactRenderer)

      Syrus::PluginRegistry.register(
        name:            "browser",
        display_name:    "Browser (Playwright)",
        version:         SyrusBrowser::VERSION,
        description:     "Headless Chromium browser control for workflow agents, via a bundled " \
                          "@playwright/mcp stdio subprocess. Navigation is hard-restricted to " \
                          "127.0.0.1/loopback URLs — the browser can only drive a step's own " \
                          "in-step preview, never an arbitrary network destination.",
        long_description: "Browser gives workflow agents a constrained Playwright browser for visual review and preview validation. Agents can navigate, click, fill forms, capture screenshots, and submit visual artifacts while Syrus restricts navigation to the step's own loopback preview.\n\nThe plugin is designed for UI work where code review alone is not enough. It keeps browser automation auditable and local to the workflow so agents can inspect visible behavior without gaining arbitrary network access.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/browser.svg",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "mcp_tool_set",
        provides: {
          mcp_tool_set:      SyrusBrowser::McpToolSet,
          artifact_renderer: SyrusBrowser::ImageDiffRenderer
        }
      )
    end
  end
end
