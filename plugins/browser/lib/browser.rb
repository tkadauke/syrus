module SyrusBrowser
  extend Syrus::Host::PluginApi

  syrus_plugin "browser" do
    experimental false
    requires_syrus nil
    display_name "Browser (Playwright)"
    description "Headless Chromium browser control for workflow agents and Coding Mode chats, " \
      "via a bundled @playwright/mcp stdio subprocess or an optional container-backed " \
      "Plugin Runtime service. Navigation is hard-restricted to " \
      "127.0.0.1/loopback URLs — the browser can only drive a step's own " \
      "in-step preview, never an arbitrary network destination."
    long_description "Browser gives workflow agents a constrained Playwright browser for visual review and preview validation, and gives interactive chats the same Playwright-backed interactions through a Runtime Session. Runtime lifecycle and leases use the runtime_* contract; the compatibility runtime_input adapter delegates to semantic click, fill, keyboard, and drag/drop implementations rather than synthesizing DOM events. Agents can navigate, fill forms, capture screenshots, and submit visual artifacts while Syrus restricts navigation to the current session's own loopback preview.\n\nThe plugin is designed for UI work where code review alone is not enough. It keeps browser automation auditable and local to the owning Run or chat so agents can inspect visible behavior without gaining arbitrary network access.\n\nWhen Plugin Runtime is enabled, Browser can offload Chromium into its own container-backed service instead of a per-Run stdio subprocess; it falls back to the bundled subprocess automatically whenever that service is unavailable."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/browser.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
    # Optional, not hard: Browser is on by default and must keep working via
    # its bundled stdio subprocess even when Plugin Runtime is disabled --
    # which it is by default (see plugins/plugin_runtime/lib/plugin_runtime.rb).
    # A hard depends_on would mark Browser :degraded (PluginHealth) and
    # withhold every one of its providers -- not just the service
    # acceleration -- on a stock install where nobody touched Plugin Runtime.
    optionally_depends_on [ "plugin_runtime" ]
    frontend i18n: [ "app/frontend/i18n/locales/*/browser.json" ]
    workflow_kinds(
      step_kinds: [
        {
          kind: "visual_review", handler: "SyrusBrowser::VisualReviewStep",
          label: "Visual review", style: "bg-pink-100 text-pink-700", agentic: true,
          agent_role: "workflow:visual_reviewer",
          required_mcp_tools: %w[submit_visual_review],
          resource_profile_fallback_step_kinds: %w[implement],
          review_gate: {
            artifact_key: "visual_review_iterations",
            exit_verdicts: %w[approved skipped],
            cancellation_reason: "visual_review_approved"
          }
        },
        {
          kind: "visual_diff", handler: "SyrusBrowser::VisualDiffStep",
          label: "Before/after visual comparison", style: "bg-pink-50 text-pink-700", agentic: true,
          required_mcp_tools: %w[submit_visual_artifact]
        }
      ]
    )
    provides artifact_renderers: "SyrusBrowser::ImageDiffRenderer",
             "workflow:judge" => "SyrusBrowser::WorkflowJudge",
             "plugin_runtime:service" => "SyrusBrowser::RuntimeService"
    runtime_session runtime_session_provider: "SyrusBrowser::RuntimeSessionProvider"
    toolkit workflow_tools: "SyrusBrowser::McpToolSet", chat_tools: "SyrusBrowser::ChatToolSet", permissions: "SyrusBrowser::PermissionProvider"
  end
end
