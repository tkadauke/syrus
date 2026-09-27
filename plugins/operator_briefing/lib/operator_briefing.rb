require "fugit"

module OperatorBriefing
  extend Syrus::PluginApi

  syrus_plugin "operator_briefing" do
    display_name "Operator Briefing"
    description "Per-repository operator briefings and blocked-on-you signals."
    long_description "Operator Briefing generates per-repository briefings for each operator. The generation agent reads repository diffs, workflow history, artifacts, and linked design docs directly, then writes structured briefing blocks for the operator."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/operator_briefing.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    depends_on [ "agent_memory", "design_docs" ]

    provides mcp_tool_set: "OperatorBriefing::McpToolSet",
             workflow_kinds: "OperatorBriefing::WorkflowKinds",
             sidebar_page: "OperatorBriefing::SidebarPages",
             callbacks: "OperatorBriefing::Callbacks",
             mcp_tool_set: "OperatorBriefing::McpToolSet"
    tick_interval 1.minute
    route :get, "/api/v1/app/briefing", to: "api/v1/app/operator_briefing/briefings#show"
    route :post, "/api/v1/app/briefing/repositories/:repository_id/regenerate", to: "api/v1/app/operator_briefing/briefings#regenerate"
    route :patch, "/api/v1/app/briefing/subscriptions/:id", to: "api/v1/app/operator_briefing/subscriptions#update"
    route :patch, "/api/v1/app/briefing/source_preferences/:id", to: "api/v1/app/operator_briefing/source_preferences#update"
    route :post, "/api/v1/app/briefing/source_preferences/:id/confirm", to: "api/v1/app/operator_briefing/source_preferences#confirm"
    route :post, "/api/v1/app/briefing/feedback", to: "api/v1/app/operator_briefing/feedbacks#create"
    frontend routes: {
          "operator_briefing/Briefing" => "app/frontend/routes/Briefing.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/operator_briefing.json" ]
  end
end
