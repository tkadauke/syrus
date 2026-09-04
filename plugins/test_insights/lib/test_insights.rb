require "test_insights/version"
require "test_insights/parser"
require "test_insights/data_cleanup"
require "test_insights/engine"

module TestInsights
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "test_insights",
      display_name:    "Test Insights",
      version:         TestInsights::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "observability",
      # Hosted for other plugins: "test_insights:parser". Core has no business
      # owning an extension point that exists solely for this ingestion path.
      hosts:           [ :parser ],
      # Contributes a result type to search when search is installed; works
      # perfectly well without it.
      optionally_depends_on: [ "global_search" ],
      description:     "Flaky, failing, and slow test tracking built from grader JUnit output.",
      long_description: "Test Insights turns the JUnit output graders already produce into durable per-test history: which tests are flaky, which are newly failing, and which have got slower.\n\nIt gives agents structured test data to investigate instead of scraping transcripts, and gives operators a per-repository view of test health. Disabling it stops ingestion; the recorded history is left in place.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: { "test_insights/RepositoryTests" => "app/frontend/repo_tabs/RepositoryTests.tsx" },
        ui_slots: { "test_insights/JobTests" => "app/frontend/ui_slots/JobTests.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/test_insights.json" ]
      },
      routes: [
        { verb: "GET", path: "/api/v1/app/jobs/:job_id/test_results", controller: "api/v1/app/job_test_results#index" },
        { verb: "GET", path: "/api/v1/app/repositories/:repository_id/flaky_tests", controller: "api/v1/app/repository_flaky_tests#index" },
        { verb: "GET", path: "/api/v1/app/repositories/:repository_id/tests", controller: "api/v1/app/repository_tests#index" },
        { verb: "GET", path: "/api/v1/app/repositories/:repository_id/tests/:id", controller: "api/v1/app/repository_tests#show" }
      ],
      provides: {
        domain_subscriber: TestInsights::Subscribers,
        test_evidence:     TestInsights::TestEvidence,
        "global_search:source" => TestInsights::SearchSource,
        repo_page_tab:     TestInsights::RepoPageTabs,
        ui_slot:           TestInsights::UiSlots,
        mcp_tool_set:      TestInsights::McpToolSet,
        chat_mcp_tool_set: TestInsights::ChatToolSet
      }
    )

    Syrus::Installer.define("test_insights:filters", plugin: "test_insights") do |scope|
      scope.effect("filter subjects") do
        Filters.register_subject(
          name: :test_case,
          model: TestInsights::TestIdentity,
          chips: {
            "repository_id" => "Filters::Chips::RepositoryId",
            "created_at"    => "Filters::Chips::CreatedAt",
            "updated_at"    => "Filters::Chips::UpdatedAt"
          }
        )
      end
    end
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "test_insights" && manifest.enabled? }
  end
end
