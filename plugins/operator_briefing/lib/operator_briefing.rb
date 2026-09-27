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
    description "Data-layer groundwork for operator briefings, notable-change detection, and blocked-on-you signals."
    long_description "Operator Briefing collects queryable facts that later briefing-generation jobs can synthesize: notable workflow changes, promoted review findings, briefing items, and design-doc threads that appear blocked on the operator."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/operator_briefing.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true
    optionally_depends_on [ "design_docs" ]

    provides notable_change_detector: [
               "OperatorBriefing::Detectors::DependencyChanges",
               "OperatorBriefing::Detectors::SchemaChanges",
               "OperatorBriefing::Detectors::PublicApiChanges",
               "OperatorBriefing::Detectors::TestCoverageChanges",
               "OperatorBriefing::Detectors::ConventionDeviation",
               "OperatorBriefing::Detectors::OverriddenReviewFindings",
               "OperatorBriefing::Detectors::SecuritySensitivePaths"
             ],
             domain_subscriber: "OperatorBriefing::Subscribers"

    events "operator_briefing.notable_changes_detected" => :inline,
           "operator_briefing.review_finding_recorded" => :inline
  end
end
