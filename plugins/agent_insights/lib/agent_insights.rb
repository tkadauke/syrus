require "agent_insights/data_cleanup"

module AgentInsights
  extend Syrus::PluginApi

  syrus_plugin "agent_insights" do
    display_name "Agent Insights"
    description "Periodic read-only agent surveys of a repository that propose follow-up work."
    long_description "Agent Insights runs an agent over a repository\'s recent workflow activity and has it propose concrete follow-ups: jobs worth filing, facts worth remembering, memories that have gone stale.\n\nRuns are read-only -- no commits, no pull request -- and every suggestion is reviewed by an operator before anything happens. Off by default, since it spends agent budget on its own schedule."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/agent_insights.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    depends_on [ "agent_memory" ]
    provides workflow_kinds: "AgentInsights::WorkflowKinds",
             domain_subscriber: "AgentInsights::Subscribers",
             repo_page_tab: "AgentInsights::RepoPageTabs",
             admin_page: "AgentInsights::AdminPages",
             mcp_tool_set: "AgentInsights::McpToolSet",
             chat_mcp_tool_set: "AgentInsights::ChatToolSet"
    route :get, "/api/v1/app/repositories/:repository_id/insight_suggestions", to: "api/v1/app/insight_suggestions#index"
    route :patch, "/api/v1/app/insight_suggestions/:id", to: "api/v1/app/insight_suggestions#update"
    route :post, "/api/v1/app/insight_suggestions/:id/discuss", to: "api/v1/app/insight_suggestions#discuss"
    route :post, "/api/v1/app/repositories/:id/run_insight_analysis", to: "api/v1/app/insight_suggestions#run_insight_analysis"
    route :get, "/api/v1/app/repositories/:id/insight_schedule_config", to: "api/v1/app/insight_schedule_configs#show"
    route :patch, "/api/v1/app/repositories/:id/insight_schedule_config", to: "api/v1/app/insight_schedule_configs#update"
    route :get, "/api/v1/app/admin/insights", to: "api/v1/app/admin/insights#index"
    route :post, "/api/v1/app/admin/insights/:id/promote_memory", to: "api/v1/app/admin/insights#promote_memory"
    route :get, "/admin/insights", to: "spa#show"
    frontend routes: {
          "agent_insights/RepositoryInsights" => "app/frontend/repo_tabs/RepositoryInsights.tsx",
          "agent_insights/AdminInsights" => "app/frontend/routes/AdminInsights.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/agent_insights.json" ]

    # Rows this plugin owns on core records outlive it being disabled, and
    # still have to go when their owner does.
    always do |scope|
      AgentInsights::DataCleanup.install_into(scope)
    end
  end
end
