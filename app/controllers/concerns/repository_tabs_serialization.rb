module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    tabs = [
      { key: "overview", label: "Overview", path: repository_path(repository) },
      { key: "documents", label: "Documents", path: repository_documents_path(repository) },
      { key: "members", label: "Members", path: repository_memberships_path(repository) }
    ]
    unless AppSetting.simple?
      tabs.insert(1, { key: "github_issues", label: "GitHub Issues", path: repository_path(repository, tab: "github_issues") })
      tabs.insert(2, { key: "tests", label: "Tests", path: repository_path(repository, tab: "tests") })
      tabs << { key: "scheduled_tasks", label: "Scheduled Tasks", path: repository_scheduled_tasks_path(repository) }
    end
    if Feature.agent_insights_enabled?
      pending_count = repository.insight_suggestions.pending.count
      tabs << { key: "insights", label: "Insights", path: repository_insights_path(repository), badge: pending_count.positive? ? pending_count : nil }
    end
    tabs.concat(
      Repositories::PluginRepoTabsPayload.tabs_for(repository: repository, user: Current.user).map do |tab|
        { key: tab[:id], label: tab[:label], path: tab[:path], badge: tab[:badge] }
      end
    )
    tabs
  end
end
