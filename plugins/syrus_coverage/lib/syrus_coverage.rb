# The plugin is named `syrus_coverage` rather than `coverage` because a plugin's
# `lib/` directory is put on $LOAD_PATH, and `lib/coverage.rb` would shadow
# Ruby's own `coverage` library (which SimpleCov and the test runner require).
module SyrusCoverage
  extend Syrus::PluginApi

  # The id the target graph gives the implicit repository-root project. It is
  # stored on snapshots and compared in artifacts, so it is a literal here and a
  # spec pins it to the core constant.
  ROOT_PROJECT_ID = "repo".freeze

  def self.root_project_id = ROOT_PROJECT_ID

  syrus_plugin "syrus_coverage" do
    display_name "Coverage"
    description "Coverage analysis for workflows: merges grader coverage reports, annotates the diff, " \
      "enforces thresholds, records trend snapshots, and comments the result on the pull request."
    long_description "Coverage reads the coverage reports a repository's graders produce, merges them, and works out what the change did to coverage: overall percentages, per-file figures, which changed lines are covered, and the pull request delta. It enforces the thresholds a repository configures under `coverage:` in `.syrus.yml` (block, warn, or schedule a follow-up Job), keeps daily snapshots for trend charts and risk ranking, and posts or updates a single summary comment on the pull request.\n\nThe analysis runs once after the implementation loops, never inside the grade loop. Disabling Coverage removes the step from new workflows without an error and retires the `coverage:` block; recorded snapshots are left in place. Ecosystem plugins keep supplying coverage analyzers through the ecosystem family, whether or not this plugin is enabled."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/syrus_coverage.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled true
    # Disableable: coverage is advisory. Nothing downstream consumes its step,
    # so omitting it from new workflows is a clean no-op, and the standard
    # plugin guard already refuses a disable while a non-terminal workflow
    # still holds one of its steps. It owns data (snapshots, hit maps) that
    # outlives it, which is why the rows are kept rather than purged.
    disableable true
    # A grace period for hit maps is enforced by the plugin's own tick rather
    # than the host's recurring.yml, so removing the plugin removes the schedule.
    tick_interval 1.day
    home_queue :cleanup
    provides workflow_kinds: "SyrusCoverage::WorkflowKinds",
             "workflow:post_implementation" => "SyrusCoverage::WorkflowPostImplementation",
             "workflow:post_pr" => "SyrusCoverage::WorkflowPostPr",
             repository_configuration: "SyrusCoverage::RepositoryConfiguration",
             mcp_tool_set: "SyrusCoverage::McpToolSet",
             permission_provider: "SyrusCoverage::PermissionProvider",
             domain_subscriber: "SyrusCoverage::Subscribers",
             callbacks: "SyrusCoverage::Callbacks",
             line_coverage_provider: "SyrusCoverage::LineCoverageProvider",
             skill: "SyrusCoverage::SkillProvider",
             ui_slot: "SyrusCoverage::UiSlots"
    frontend ui_slots: { "syrus_coverage/CoverageCard" => "app/frontend/ui_slots/CoverageCard.tsx",
                         "syrus_coverage/CoverageSparkline" => "app/frontend/ui_slots/CoverageSparkline.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/syrus_coverage.json" ]
    route :get, "/api/v1/app/repositories/:repository_id/coverage_trend", to: "api/v1/app/coverage#trend"
    route :get, "/api/v1/app/workflows/:workflow_id/coverage_hit_map", to: "api/v1/app/coverage#hit_map"

    # Snapshots and hit maps belong to a repository and a workflow, and have to
    # go with them whether or not this plugin is enabled.
    always "coverage data cleanup" do |scope|
      SyrusCoverage::DataCleanup.install_into(scope)
    end
  end
end
