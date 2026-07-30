module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    tabs = [
      { key: "overview", label: "Overview", path: repository_path(repository) },
      { key: "github_issues", label: "GitHub Issues", path: repository_path(repository, tab: "github_issues") },
      { key: "documents", label: "Documents", path: repository_documents_path(repository) },
      { key: "scheduled_tasks", label: "Scheduled Tasks", path: repository_scheduled_tasks_path(repository) }
    ]
    if Feature.agent_insights_enabled?
      pending_count = repository.insight_suggestions.pending.count
      tabs << { key: "insights", label: "Insights", path: repository_insights_path(repository), badge: pending_count.positive? ? pending_count : nil }
    end
    tabs
  end
end
