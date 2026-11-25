require "test_insights/parser"
require "test_insights/data_cleanup"

module TestInsights
  extend Syrus::Host::PluginApi

  syrus_plugin "test_insights" do
    display_name "Test Insights"
    description "Flaky, failing, and slow test tracking built from grader JUnit output."
    long_description "Test Insights turns the JUnit output graders already produce into durable per-test history: which tests are flaky, which are newly failing, and which have got slower.\n\nIt gives agents structured test data to investigate instead of scraping transcripts, and gives operators a per-repository view of test health. Disabling it stops ingestion; the recorded history is left in place."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/test_insights.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled true
    disableable true
    optionally_depends_on [ "global_search" ]
    hosts [ :parser ]
    lifecycle domain_subscribers: "TestInsights::Subscribers"
    data_policy retention_policies: "TestInsights::RetentionPolicy"
    provides test_evidence: "TestInsights::TestEvidence",
             grader_input_materializer: "TestInsights::GraderRuntimeProfileProvider",
             grader_failure_summarizer: "TestInsights::GraderFailureSummarizer",
             "global_search:source" => "TestInsights::SearchSource",
             repo_page_tabs: "TestInsights::RepoPageTabs",
             ui_slots: "TestInsights::UiSlots"
    toolkit workflow_tools: "TestInsights::McpToolSet", chat_tools: "TestInsights::ChatToolSet", permissions: "TestInsights::PermissionProvider"
    surface filter_subjects: { test_case: { model: "TestInsights::TestIdentity", chips: {
      "repository_id" => "Filters::Chips::RepositoryId",
      "created_at" => "Filters::Chips::CreatedAt",
      "updated_at" => "Filters::Chips::UpdatedAt"
    } } }
    route :get, "/api/v1/app/jobs/:job_id/test_results", to: "api/v1/app/job_test_results#index"
    route :get, "/api/v1/app/repositories/:repository_id/flaky_tests", to: "api/v1/app/repository_flaky_tests#index"
    route :get, "/api/v1/app/repositories/:repository_id/tests", to: "api/v1/app/repository_tests#index"
    route :get, "/api/v1/app/repositories/:repository_id/tests/:id", to: "api/v1/app/repository_tests#show"
    route :get, "/api/v1/admin/jobs/:job_id/test_results", to: "api/v1/admin/job_test_results#index"
    route :get, "/api/v1/admin/repositories/:repository_id/tests", to: "api/v1/admin/repository_tests#index"
    route :get, "/api/v1/admin/repositories/:repository_id/tests/:id", to: "api/v1/admin/repository_tests#show"
    frontend routes: { "test_insights/RepositoryTests" => "app/frontend/repo_tabs/RepositoryTests.tsx" },
        ui_slots: { "test_insights/JobTests" => "app/frontend/ui_slots/JobTests.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/test_insights.json" ]

    # Rows this plugin owns on core records outlive it being disabled, and
    # still have to go when their owner does.
    always do |scope|
      TestInsights::DataCleanup.install_into(scope)
    end
  end
end
