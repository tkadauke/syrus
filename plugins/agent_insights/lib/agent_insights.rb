require "agent_insights/version"
require "agent_insights/data_cleanup"
require "agent_insights/engine"

module AgentInsights
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "agent_insights",
      display_name:    "Agent Insights",
      version:         AgentInsights::VERSION,
      default_enabled: false,
      disableable:     true,
      # Insight suggestions can propose retiring a memory, and carry a foreign
      # key to the entry they target -- so the store has to be there.
      depends_on:      [ "agent_memory" ],
      category:        "observability",
      description:     "Periodic read-only agent surveys of a repository that propose follow-up work.",
      long_description: "Agent Insights runs an agent over a repository\'s recent workflow activity and has it propose concrete follow-ups: jobs worth filing, facts worth remembering, memories that have gone stale.\n\nRuns are read-only -- no commits, no pull request -- and every suggestion is reviewed by an operator before anything happens. Off by default, since it spends agent budget on its own schedule.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "agent_insights/RepositoryInsights" => "app/frontend/repo_tabs/RepositoryInsights.tsx",
          "agent_insights/AdminInsights" => "app/frontend/routes/AdminInsights.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/agent_insights.json" ]
      },
      routes: [
        { verb: "GET",   path: "/api/v1/app/repositories/:repository_id/insight_suggestions", controller: "api/v1/app/insight_suggestions#index" },
        { verb: "PATCH", path: "/api/v1/app/insight_suggestions/:id", controller: "api/v1/app/insight_suggestions#update" },
        { verb: "POST",  path: "/api/v1/app/insight_suggestions/:id/discuss", controller: "api/v1/app/insight_suggestions#discuss" },
        { verb: "POST",  path: "/api/v1/app/repositories/:id/run_insight_analysis", controller: "api/v1/app/insight_suggestions#run_insight_analysis" },
        { verb: "GET",   path: "/api/v1/app/repositories/:id/insight_schedule_config", controller: "api/v1/app/insight_schedule_configs#show" },
        { verb: "PATCH", path: "/api/v1/app/repositories/:id/insight_schedule_config", controller: "api/v1/app/insight_schedule_configs#update" },
        { verb: "GET",   path: "/api/v1/app/admin/insights", controller: "api/v1/app/admin/insights#index" },
        { verb: "POST",  path: "/api/v1/app/admin/insights/:id/promote_memory", controller: "api/v1/app/admin/insights#promote_memory" },
        { verb: "GET",   path: "/admin/insights", controller: "spa#show" }
      ],
      provides: {
        workflow_kinds:    AgentInsights::WorkflowKinds,
        domain_subscriber: AgentInsights::Subscribers,
        repo_page_tab:     AgentInsights::RepoPageTabs,
        admin_page:        AgentInsights::AdminPages,
        mcp_tool_set:      AgentInsights::McpToolSet,
        chat_mcp_tool_set: AgentInsights::ChatToolSet
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "agent_insights" && manifest.enabled? }
  end
end
