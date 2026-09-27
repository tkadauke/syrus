require "fugit"
require "operator_briefing/detector_fact"

require "operator_briefing/detectors/base"
require "operator_briefing/detectors/dependency_changes"
require "operator_briefing/detectors/schema_changes"
require "operator_briefing/detectors/public_api_changes"
require "operator_briefing/detectors/test_coverage_changes"
require "operator_briefing/detectors/convention_deviation"
require "operator_briefing/detectors/overridden_review_findings"
require "operator_briefing/detectors/security_sensitive_paths"

module OperatorBriefing
  extend Syrus::PluginApi

  syrus_plugin "operator_briefing" do
    display_name "Operator Briefing"
    description "Per-repository operator briefings, notable-change detection, and blocked-on-you signals."
    long_description "Operator Briefing collects queryable facts and turns them into per-repository briefings for each operator. It surfaces notable workflow changes, promoted review findings, briefing items, and design-doc threads that appear blocked on the operator."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/operator_briefing.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    depends_on [ "agent_memory", "design_docs" ]

    provides notable_change_detector: [
               "OperatorBriefing::Detectors::DependencyChanges",
               "OperatorBriefing::Detectors::SchemaChanges",
               "OperatorBriefing::Detectors::PublicApiChanges",
               "OperatorBriefing::Detectors::TestCoverageChanges",
               "OperatorBriefing::Detectors::ConventionDeviation",
               "OperatorBriefing::Detectors::OverriddenReviewFindings",
               "OperatorBriefing::Detectors::SecuritySensitivePaths"
             ],
             domain_subscriber: "OperatorBriefing::Subscribers",
             workflow_kinds: "OperatorBriefing::WorkflowKinds",
             sidebar_page: "OperatorBriefing::SidebarPages",
             callbacks: "OperatorBriefing::Callbacks"
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

    events "operator_briefing.notable_changes_detected" => :inline,
           "operator_briefing.review_finding_recorded" => :inline
  end
end
