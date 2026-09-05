module AgentActivity
  extend Syrus::PluginApi

  FILTER_CHIPS = {
    "repository_id"  => "Filters::Chips::AgentActivity::RepositoryId",
    "job_id"         => "Filters::Chips::AgentActivity::JobId",
    "step_kind"      => "Filters::Chips::AgentActivity::StepKind",
    "agent_provider" => "Filters::Chips::AgentActivity::AgentProvider",
    "status"         => "Filters::Chips::AgentActivity::Status",
    "window"         => "Filters::Chips::AgentActivity::Window"
  }.freeze

  syrus_plugin "agent_activity" do
    display_name "Agent Activity"
    description "Live feed of agent sessions -- one card per agentic Run, headlined by what it actually decided."
    long_description "Agent Activity surfaces every agentic Run (Step#kind in Step::AGENTIC_KINDS) as a session card: role and label come structurally from the Step::Kind registry, never from scanning transcript text, and each card's headline is the one-line outcome the session itself submitted (submit_summary, submit_adversarial_review, submit_visual_review). An operator-scoped page shows sessions across the repositories they can see; an admin-wide page shows every session on the instance. Both are live, sessions-only feeds -- no checks, no triggers -- click a card to open its transcript."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/agent_activity.svg"
    author "Thomas Kadauke"
    category "observability"

    provides sidebar_page: "AgentActivity::SidebarPages"

    route :get, "/api/v1/app/agent_activity/sessions", to: "api/v1/app/agent_activity#sessions"
    route :get, "/api/v1/app/admin/agent_activity/sessions", to: "api/v1/app/admin/agent_activity#sessions"
    route :get, "/api/v1/app/admin/agent_activity/sessions/:run_id/artifacts", to: "api/v1/app/admin/agent_activity#artifacts"
    # /agent_activity (operator page) is registered in config/routes.rb --
    # there's no generic top-level SPA-page wildcard the way /admin/*path
    # exists for admin pages. /admin/agent_activity relies on that wildcard,
    # matched via this declared route (see PluginRouteResolver.spa_route_declared?).
    route :get, "/admin/agent_activity", to: "spa#show"

    frontend routes: {
          "agent_activity/AgentActivity" => "app/frontend/routes/AgentActivity.tsx",
          "agent_activity/AdminAgentActivity" => "app/frontend/routes/AdminAgentActivity.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/agent_activity.json" ]

    while_enabled do |scope|
      scope.effect("agent_activity filter subject") do
        Filters.register_subject(name: :agent_activity, model: Run, chips: FILTER_CHIPS)
      end
    end
  end
end
