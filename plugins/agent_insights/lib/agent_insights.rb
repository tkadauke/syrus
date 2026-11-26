require "agent_insights/data_cleanup"

module AgentInsights
  extend Syrus::PluginApi

  syrus_plugin "agent_insights" do
    requires_syrus nil
    experimental true
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

    suggests_enabling "There is enough completed workflow history here for a read-only survey to have something to say." do |signals|
      runs = signals.completed_runs
      runs if runs >= 50
    end

    lifecycle domain_subscribers: "AgentInsights::Subscribers"
    provides repo_page_tabs: "AgentInsights::RepoPageTabs",
             admin_pages: "AgentInsights::AdminPages"
    # Insight sweeps run on their own Job kind: repository-scoped, no GitHub
    # issue behind them, and hidden from the operator's Job lists.
    workflow_kinds(
      trigger_kinds: [
        {
          kind: "agent_insight", template: "AgentInsights::Workflow",
          label: "Agent insight", style: "bg-amber-100 text-amber-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
          owns_job_lifecycle: true
        }
      ],
      step_kinds: [
        {
          kind: "agent_insight_run", handler: "AgentInsights::RunStep",
          label: "Agent insight", style: "bg-amber-100 text-amber-700", agentic: true,
          agent_role: "agent:insight"
        }
      ],
      job_kinds: [ { kind: "agent_insight", infrastructure: true, issueless: true } ],
      work_definitions: [ "AgentInsights::WorkDefinition" ]
    )
    slug_type prefix: "INSIGHT", display_label: "Insight", preview_available: true,
              resolver: "AgentInsights::SlugType"
    toolkit workflow_tools: "AgentInsights::McpToolSet", chat_tools: "AgentInsights::ChatToolSet", permissions: "AgentInsights::PermissionProvider"
    surface filter_subjects: { agent_insight: { model: "AgentInsights::Suggestion", chips: "AgentInsights::SmartFolders::CHIPS" } }
    route :get, "/api/v1/app/repositories/:repository_id/insight_suggestions", to: "api/v1/app/insight_suggestions#index"
    route :get, "/api/v1/app/insight_suggestions/:id/preview", to: "api/v1/app/insight_suggestions#preview"
    route :get, "/api/v1/app/insight_suggestions/:id", to: "api/v1/app/insight_suggestions#show"
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
        slug_preview_cards: {
          "INSIGHT" => "app/frontend/slugPreviewCards/INSIGHT.InsightPreviewCard.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/agent_insights.json" ]

    # Rows this plugin owns on core records outlive it being disabled, and
    # still have to go when their owner does.
    always do |scope|
      AgentInsights::DataCleanup.install_into(scope)
    end

    while_enabled do |scope|
      AgentInsights::SmartFolders.install_into(scope)
    end
  end
end
