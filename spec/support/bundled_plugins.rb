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
        default_enabled: true,
        disableable:     true,
        category:        "agent_provider",
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
        default_enabled: true,
        disableable:     true,
        category:        "agent_provider",
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
        category:        "dev",
        frontend: {
          routes: {
            "syrus_dev/AdminPerformance" => "app/frontend/routes/AdminPerformance.tsx",
            "syrus_dev/AdminOperationalLogs" => "app/frontend/routes/AdminOperationalLogs.tsx"
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
          admin_page:   SyrusDev::AdminPages,
          mcp_tool_set: SyrusDev::WorkflowToolSet
        }
      )
    end

    unless registered_names.include?("tailscale")
      Syrus::PluginRegistry.register(
        name:            "tailscale",
        display_name:    "Tailscale",
        version:         Tailscale::VERSION,
        description:     "Exposes Syrus on your Tailscale network for access from laptops and mobile.",
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

    Syrus::PluginRegistry.all_plugins
  end
end
