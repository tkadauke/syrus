# Re-register bundled plugins before each example so registry-backed model
# validations and settings payloads work correctly in tests.
#
# config/initializers/plugin_registry.rb resets the registry via
# after_initialize in test mode. This before hook restores the bundled
# providers before each example.
#
# Examples tagged :reset_plugin_registry (i.e. plugin_registry_spec) opt out
# so their around block gets a genuinely empty registry. RSpec hook ordering is
# around-pre → before → example, so the before hook would otherwise fire after
# the around reset and repopulate the registry before the example body runs.
RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:reset_plugin_registry]

    registered_names = Syrus::PluginRegistry.registered_names

    unless registered_names.include?("claude_agent")
      Syrus::PluginRegistry.register(
        name:            "claude_agent",
        display_name:    "Claude Agent",
        version:         SyrusClaudeAgent::VERSION,
        description:     "Runs workflow and chat turns through Claude.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "agent",
        provides: {
          agent_provider: AgentProviders::Claude,
          chat_provider:  ChatProviders::Claude
        }
      )
    end

    unless registered_names.include?("codex_agent")
      Syrus::PluginRegistry.register(
        name:            "codex_agent",
        display_name:    "Codex Agent",
        version:         SyrusCodexAgent::VERSION,
        description:     "Runs workflow and chat turns through Codex.",
        homepage:        "https://github.com/tkadauke/syrus",
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

    unless registered_names.include?("github_source")
      Syrus::PluginRegistry.register(
        name:            "github_source",
        display_name:    "GitHub Source",
        version:         SyrusGithubSource::VERSION,
        description:     "Ingests GitHub issues and provides GitHub PR operations.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     false,
        category:        "input_source",
        provides: {
          input_source:            InputSources::Github,
          source_control_provider: SourceControl::GithubOperations
        }
      )
    end

    unless registered_names.include?("linear_source")
      Syrus::PluginRegistry.register(
        name:            "linear_source",
        display_name:    "Linear Source",
        version:         SyrusLinearSource::VERSION,
        description:     "Ingests Linear issues as Syrus jobs and epics.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "input_source",
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/linear/teams",
            controller: "api/v1/app/linear#teams"
          }
        ],
        provides: { input_source: InputSources::Linear }
      )
    end

    unless registered_names.include?("syrus_dev")
      Syrus::PluginRegistry.register(
        name:            "syrus_dev",
        display_name:    "Syrus Dev",
        version:         SyrusDev::VERSION,
        default_enabled: false,
        disableable:     true,
        category:        "tooling",
        description:     "Syrus development diagnostics and internal tooling.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        frontend: {
          routes: {
            "syrus_dev/AdminPerformance" => "app/frontend/routes/AdminPerformance.tsx",
            "syrus_dev/AdminOperationalLogs" => "app/frontend/routes/AdminOperationalLogs.tsx"
          },
          workspace_tabs: {
            "syrus_dev/WorkspaceTabDemo" => "app/frontend/workspaceTabs/WorkspaceTabDemo.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/syrus_dev.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/admin/performance",
            controller: "api/v1/app/admin/performance#show"
          },
          {
            verb: "POST",
            path: "/api/v1/app/admin/performance/explain",
            controller: "api/v1/app/admin/performance#explain"
          },
          {
            verb: "GET",
            path: "/api/v1/app/admin/operational_logs",
            controller: "api/v1/app/admin/operational_logs#index"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/performance",
            controller: "api/v1/admin/performance#show"
          },
          {
            verb: "POST",
            path: "/api/v1/admin/performance/explain",
            controller: "api/v1/admin/performance#explain"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/operational_logs",
            controller: "api/v1/admin/operational_logs#index"
          },
          {
            verb: "GET",
            path: "/admin/performance",
            controller: "spa#show"
          },
          {
            verb: "GET",
            path: "/admin/operational_logs",
            controller: "spa#show"
          }
        ],
        provides: {
          admin_page:    SyrusDev::AdminPages,
          mcp_tool_set:  SyrusDev::WorkflowToolSet,
          workspace_tab: SyrusDev::WorkspaceTabs
        }
      )
    end

    AdminMysql.register! unless registered_names.include?("admin_mysql")

    GitHistory.register! unless registered_names.include?("git_history")

    unless registered_names.include?("tailscale")
      Syrus::PluginRegistry.register(
        name:            "tailscale",
        display_name:    "Tailscale",
        version:         Tailscale::VERSION,
        description:     "Exposes Syrus on your Tailscale network for access from laptops and mobile.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "connectivity",
        home_queue:      :connectivity,
        tick_interval:   30.seconds,
        config_schema: [
          { key: "auth_key", label: "Auth Key", type: :secret_env, env_var: "TS_AUTHKEY",
            required: true, description: "Auth key for headless device registration. Set in .env." },
          { key: "hostname", label: "Device Hostname", type: :string, required: false,
            description: "Override the device name on the tailnet." },
          { key: "exit_node", label: "Advertise as exit node", type: :boolean,
            required: false, default: false }
        ],
        frontend: {
          routes: {
            "tailscale/AdminTailscale" => "app/frontend/routes/AdminTailscale.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/tailscale.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/admin/tailscale/status",
            controller: "api/v1/app/admin/tailscale#status"
          },
          {
            verb: "GET",
            path: "/api/v1/admin/tailscale/status",
            controller: "api/v1/admin/tailscale#status"
          },
          {
            verb: "GET",
            path: "/admin/tailscale",
            controller: "spa#show"
          }
        ],
        provides: { callbacks: Tailscale::Callbacks, admin_page: Tailscale::AdminPages }
      )
    end

    unless registered_names.include?("browser")
      Syrus::PluginRegistry.register(
        name:            "browser",
        display_name:    "Browser (Playwright)",
        version:         SyrusBrowser::VERSION,
        description:     "Headless Chromium browser control for workflow agents, via a bundled " \
                          "@playwright/mcp stdio subprocess. Navigation is hard-restricted to " \
                          "127.0.0.1/loopback URLs — the browser can only drive a step's own " \
                          "in-step preview, never an arbitrary network destination.",
        homepage:        "https://github.com/tkadauke/syrus",
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

    unless registered_names.include?("preview_tools")
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

    unless registered_names.include?("whiteboard_tools")
      WhiteboardTools::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless WhiteboardTools::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
      WhiteboardTools::WorkspaceTabs.include(Syrus::Plugin::WorkspaceTab) unless WhiteboardTools::WorkspaceTabs < Syrus::Plugin::WorkspaceTab

      Syrus::PluginRegistry.register(
        name:            "whiteboard_tools",
        display_name:    "Whiteboard",
        version:         WhiteboardTools::VERSION,
        description:     "Excalidraw-based chat whiteboard: workspace sidebar tab plus draw/move/delete/read/" \
                          "save/clear/load MCP tools so agents and operators can sketch together on a shared " \
                          "per-chat canvas.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "workspace_tab",
        frontend: {
          workspace_tabs: {
            "whiteboard_tools/WhiteboardTab" => "app/frontend/workspaceTabs/WhiteboardTab.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/whiteboard_tools.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/chats/:id/whiteboard",
            controller: "api/v1/app/chat_whiteboards#show"
          },
          {
            verb: "PATCH",
            path: "/api/v1/app/chats/:id/whiteboard",
            controller: "api/v1/app/chat_whiteboards#update"
          },
          {
            verb: "GET",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots",
            controller: "api/v1/app/whiteboard_snapshots#index"
          },
          {
            verb: "POST",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots",
            controller: "api/v1/app/whiteboard_snapshots#create"
          },
          {
            verb: "GET",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots/:id",
            controller: "api/v1/app/whiteboard_snapshots#show"
          }
        ],
        provides: {
          chat_mcp_tool_set: WhiteboardTools::ChatToolSet,
          workspace_tab:     WhiteboardTools::WorkspaceTabs
        }
      )
    end

    unless registered_names.include?("discord")
      Syrus::PluginRegistry.register(
        name:            "discord",
        display_name:    "Discord",
        version:         SyrusDiscord::VERSION,
        description:     "Links Discord accounts and delivers/receives chat messages over a Gateway DM listener.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "platform_delivery",
        provides: { platform_delivery: Discord::PlatformAdapter }
      )
    end

    SpendingInsights.register! unless registered_names.include?("spending_insights")

    Syrus::PluginRegistry.all_plugins
  end
end
