require "fugit"

module OperatorBriefing
  extend Syrus::PluginApi

  SEVERITIES = %w[informational fyi decision_required attention_debt].freeze

  syrus_plugin "operator_briefing" do
    requires_syrus nil
    experimental true
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

    lifecycle callback_providers: "OperatorBriefing::Callbacks"
    provides sidebar_pages: "OperatorBriefing::SidebarPages"
    workflow_kinds(
      trigger_kinds: [
        {
          kind: "briefing_generate", template: "OperatorBriefing::Workflow",
          label: "Briefing generation", style: "bg-sky-100 text-sky-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
          owns_job_lifecycle: true
        },
        {
          kind: "briefing_dive", template: "OperatorBriefing::DiveWorkflow",
          label: "Briefing dive", style: "bg-cyan-100 text-cyan-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "child"
        }
      ],
      step_kinds: [
        {
          kind: "briefing_generate_run", handler: "OperatorBriefing::GenerateRunStep",
          label: "Generate briefing", style: "bg-sky-100 text-sky-700", agentic: true,
          agent_role: "workflow:summary_test_plan",
          required_mcp_tools: %w[submit_briefing_block],
          placement_policy: "control_plane"
        },
        {
          kind: "briefing_dive_investigate", handler: "OperatorBriefing::DiveInvestigateStep",
          label: "Investigate dive", style: "bg-cyan-100 text-cyan-700", agentic: true,
          agent_role: "workflow:summary_test_plan",
          required_mcp_tools: %w[read_briefing]
        },
        {
          kind: "submit_dive_report", handler: "OperatorBriefing::SubmitDiveReportStep",
          label: "Submit dive report", style: "bg-cyan-200 text-cyan-800", agentic: true,
          agent_role: "workflow:summary_test_plan",
          required_mcp_tools: %w[read_briefing list_briefing_topics read_briefing_topic submit_dive_report],
          skip_if_artifact: "briefing_dive_report"
        }
      ],
      job_kinds: [ { kind: "briefing_generate", infrastructure: true, issueless: true, investigable: true } ],
      work_definitions: [ "OperatorBriefing::WorkDefinition", "OperatorBriefing::DiveWorkDefinition" ]
    )
    toolkit workflow_tools: "OperatorBriefing::McpToolSet", permissions: "OperatorBriefing::PermissionProvider"
    tick_interval 1.minute
    route :get, "/api/v1/app/briefing", to: "api/v1/app/operator_briefing/briefings#show"
    route :get, "/api/v1/app/briefing/history", to: "api/v1/app/operator_briefing/briefings#history"
    route :get, "/api/v1/app/briefing/topics/:id", to: "api/v1/app/operator_briefing/topics#show"
    route :post, "/api/v1/app/briefing/repositories/:repository_id/regenerate", to: "api/v1/app/operator_briefing/briefings#regenerate"
    route :post, "/api/v1/app/briefing/:id/dive", to: "api/v1/app/operator_briefing/briefings#dive"
    route :post, "/api/v1/app/briefing/:id/discuss", to: "api/v1/app/operator_briefing/briefings#discuss"
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
